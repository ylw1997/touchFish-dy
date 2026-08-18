import Compression
import Foundation

struct LiveDanmakuItem: Identifiable {
    let id: String
    let nickname: String
    let text: String
}

@MainActor
final class LiveDanmakuService {
    var onDanmaku: ((LiveDanmakuItem) -> Void)?

    private static let userAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/150.0.0.0 Safari/537.36"
    private let session: URLSession
    private var webSocket: URLSessionWebSocketTask?
    private var connectTask: Task<Void, Never>?
    private var receiveTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var generation: UInt = 0
    private var reconnectAttempt = 0
    private var seenMessageIDs: Set<String> = []
    private var recentMessageIDs: [String] = []

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: configuration)
    }

    func start(roomID: String, webRID: String, cookie: String) {
        stop()
        generation &+= 1
        let requestedGeneration = generation
        reconnectAttempt = 0
        seenMessageIDs.removeAll(keepingCapacity: true)
        recentMessageIDs.removeAll(keepingCapacity: true)
        connectTask = Task { [weak self] in
            await self?.connect(
                roomID: roomID,
                webRID: webRID,
                cookie: cookie,
                generation: requestedGeneration
            )
        }
    }

    func stop() {
        generation &+= 1
        connectTask?.cancel()
        connectTask = nil
        receiveTask?.cancel()
        receiveTask = nil
        heartbeatTask?.cancel()
        heartbeatTask = nil
        reconnectTask?.cancel()
        reconnectTask = nil
        webSocket?.cancel(with: .goingAway, reason: nil)
        webSocket = nil
    }

    private func connect(roomID: String, webRID: String, cookie: String, generation: UInt) async {
        do {
            let bootstrap = try await makeBootstrap(roomID: roomID, webRID: webRID, cookie: cookie)
            try Task.checkCancellation()
            guard generation == self.generation else { return }
            if let response = bootstrap.initialResponse { emitMessages(from: response) }

            let socketURL = try makeWebSocketURL(
                roomID: roomID,
                userUniqueID: bootstrap.userUniqueID,
                cursor: bootstrap.cursor,
                internalExt: bootstrap.internalExt
            )
            var request = URLRequest(url: socketURL)
            request.timeoutInterval = 15
            request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
            request.setValue("https://live.douyin.com", forHTTPHeaderField: "Origin")
            if !bootstrap.cookie.isEmpty { request.setValue(bootstrap.cookie, forHTTPHeaderField: "Cookie") }

            let task = session.webSocketTask(with: request)
            webSocket = task
            task.resume()
            startHeartbeat(for: task, generation: generation)
            startReceiving(
                from: task,
                roomID: roomID,
                webRID: webRID,
                cookie: cookie,
                generation: generation
            )
            PlaybackDiagnostics.shared.event(
                "connected",
                category: "live-danmaku",
                fields: ["room": roomID]
            )
        } catch is CancellationError {
            return
        } catch {
            scheduleReconnect(
                roomID: roomID,
                webRID: webRID,
                cookie: cookie,
                generation: generation,
                error: error
            )
        }
    }

    private func startReceiving(
        from task: URLSessionWebSocketTask,
        roomID: String,
        webRID: String,
        cookie: String,
        generation: UInt
    ) {
        receiveTask?.cancel()
        receiveTask = Task { [weak self] in
            do {
                while !Task.isCancelled {
                    let message = try await task.receive()
                    guard let self, generation == self.generation, self.webSocket === task else { return }
                    let data: Data
                    switch message {
                    case .data(let value): data = value
                    case .string(let value): data = Data(value.utf8)
                    @unknown default: continue
                    }
                    try await self.consume(data, socket: task)
                    self.reconnectAttempt = 0
                }
            } catch is CancellationError {
                return
            } catch {
                guard let self else { return }
                self.scheduleReconnect(
                    roomID: roomID,
                    webRID: webRID,
                    cookie: cookie,
                    generation: generation,
                    error: error
                )
            }
        }
    }

    private func startHeartbeat(for task: URLSessionWebSocketTask, generation: UInt) {
        heartbeatTask?.cancel()
        heartbeatTask = Task { [weak self] in
            do {
                while !Task.isCancelled {
                    try await Task.sleep(for: .seconds(5))
                    guard let self, generation == self.generation, self.webSocket === task else { return }
                    try await task.send(.data(LiveProtobuf.pushFrame(payloadType: "hb")))
                }
            } catch {
                // 接收循环统一管理重连，避免心跳和接收同时建立两条连接。
            }
        }
    }

    private func consume(_ data: Data, socket: URLSessionWebSocketTask) async throws {
        let frame = try LiveProtobuf.decodePushFrame(data)
        let responseData = frame.payload.isGzip ? try Gzip.decompress(frame.payload) : frame.payload
        let response = try LiveProtobuf.decodeResponse(responseData)
        if response.needAck {
            let ack = LiveProtobuf.pushFrame(
                logID: frame.logID,
                payloadType: "ack",
                payload: Data(response.internalExt.utf8)
            )
            try await socket.send(.data(ack))
        }
        emitMessages(from: response)
    }

    private func emitMessages(from response: LivePushResponse) {
        for message in response.messages where message.method == "WebcastChatMessage" {
            guard let chat = try? LiveProtobuf.decodeChatMessage(message.payload) else { continue }
            let text = chat.content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let id = message.messageID == 0
                ? "\(chat.nickname)|\(text)|\(Date().timeIntervalSince1970)"
                : String(message.messageID)
            guard seenMessageIDs.insert(id).inserted else { continue }
            recentMessageIDs.append(id)
            if recentMessageIDs.count > 1_000 {
                let expired = Array(recentMessageIDs.prefix(200))
                recentMessageIDs.removeFirst(expired.count)
                expired.forEach { seenMessageIDs.remove($0) }
            }
            onDanmaku?(LiveDanmakuItem(id: id, nickname: chat.nickname, text: text))
        }
    }

    private func scheduleReconnect(
        roomID: String,
        webRID: String,
        cookie: String,
        generation: UInt,
        error: Error
    ) {
        guard generation == self.generation, reconnectTask == nil else { return }
        webSocket?.cancel(with: .goingAway, reason: nil)
        webSocket = nil
        heartbeatTask?.cancel()
        heartbeatTask = nil
        receiveTask = nil
        reconnectAttempt += 1
        let delay = min(30.0, pow(2.0, Double(min(reconnectAttempt - 1, 4))))
        PlaybackDiagnostics.shared.event(
            "reconnect-scheduled",
            category: "live-danmaku",
            fields: [
                "room": roomID,
                "attempt": reconnectAttempt,
                "delay": delay,
                "errorType": String(describing: type(of: error))
            ]
        )
        reconnectTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(delay))
                guard let self, generation == self.generation else { return }
                self.reconnectTask = nil
                await self.connect(
                    roomID: roomID,
                    webRID: webRID,
                    cookie: cookie,
                    generation: generation
                )
            } catch {
                self?.reconnectTask = nil
            }
        }
    }

    private func makeBootstrap(roomID: String, webRID: String, cookie: String) async throws -> LiveBootstrap {
        var pageRequest = URLRequest(url: URL(string: "https://live.douyin.com/\(webRID)")!)
        pageRequest.timeoutInterval = 15
        pageRequest.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        pageRequest.setValue("https://live.douyin.com/", forHTTPHeaderField: "Referer")
        if !cookie.isEmpty { pageRequest.setValue(cookie, forHTTPHeaderField: "Cookie") }

        let (pageData, pageResponse) = try await session.data(for: pageRequest)
        guard let http = pageResponse as? HTTPURLResponse,
              (200...299).contains(http.statusCode) else { throw APIError.badResponse }
        let html = String(data: pageData, encoding: .utf8) ?? ""
        let userUniqueID = Self.firstMatch(
            in: html,
            patterns: [#"\\\"user_unique_id\\\":\\\"(\d+)\\\""#, #""user_unique_id"\s*:\s*"(\d+)""#]
        ) ?? Self.persistentAnonymousID()
        let requestCookie = Self.mergingTTWID(
            into: cookie,
            setCookie: http.value(forHTTPHeaderField: "Set-Cookie")
        )
        let fallback = Self.fallbackBootstrap(
            roomID: roomID,
            userUniqueID: userUniqueID,
            cookie: requestCookie
        )

        do {
            var components = URLComponents(string: "https://live.douyin.com/webcast/im/fetch/")!
            components.queryItems = Self.fetchQueryItems(
                roomID: roomID,
                userUniqueID: userUniqueID,
                msToken: Self.cookieValue(named: "msToken", in: requestCookie) ?? ""
            )
            guard let unsignedURL = components.url?.absoluteString else { return fallback }
            let signedURL = SignatureManager.shared.sign(url: unsignedURL, userAgent: Self.userAgent)
            guard let url = URL(string: signedURL) else { return fallback }
            var request = URLRequest(url: url)
            request.timeoutInterval = 15
            request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
            request.setValue("https://live.douyin.com/\(webRID)", forHTTPHeaderField: "Referer")
            request.setValue("https://live.douyin.com", forHTTPHeaderField: "Origin")
            request.setValue("application/x-protobuf", forHTTPHeaderField: "Accept")
            if !requestCookie.isEmpty { request.setValue(requestCookie, forHTTPHeaderField: "Cookie") }
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200...299).contains(http.statusCode), !data.isEmpty else { return fallback }
            let initial = try LiveProtobuf.decodeResponse(data)
            guard !initial.cursor.isEmpty else { return fallback }
            return LiveBootstrap(
                userUniqueID: userUniqueID,
                cookie: requestCookie,
                cursor: initial.cursor,
                internalExt: initial.internalExt,
                initialResponse: initial
            )
        } catch {
            // fetch 的签名变化不能阻断直播播放，继续使用网页协议的首帧游标。
            return fallback
        }
    }

    private func makeWebSocketURL(
        roomID: String,
        userUniqueID: String,
        cursor: String,
        internalExt: String
    ) throws -> URL {
        var components = URLComponents(
            string: "wss://webcast100-ws-web-hl.douyin.com/webcast/im/push/v2/"
        )!
        components.queryItems = [
            URLQueryItem(name: "app_name", value: "douyin_web"),
            URLQueryItem(name: "version_code", value: "180800"),
            URLQueryItem(name: "webcast_sdk_version", value: "1.0.15"),
            URLQueryItem(name: "update_version_code", value: "1.0.15"),
            URLQueryItem(name: "compress", value: "gzip"),
            URLQueryItem(name: "device_platform", value: "web"),
            URLQueryItem(name: "cookie_enabled", value: "true"),
            URLQueryItem(name: "browser_language", value: "zh-CN"),
            URLQueryItem(name: "browser_platform", value: "Win32"),
            URLQueryItem(name: "browser_name", value: "Mozilla"),
            URLQueryItem(name: "browser_version", value: Self.userAgent),
            URLQueryItem(name: "browser_online", value: "true"),
            URLQueryItem(name: "tz_name", value: "Asia/Shanghai"),
            URLQueryItem(name: "cursor", value: cursor),
            URLQueryItem(name: "internal_ext", value: internalExt),
            URLQueryItem(name: "host", value: "https://live.douyin.com"),
            URLQueryItem(name: "aid", value: "6383"),
            URLQueryItem(name: "live_id", value: "1"),
            URLQueryItem(name: "did_rule", value: "3"),
            URLQueryItem(name: "endpoint", value: "live_pc"),
            URLQueryItem(name: "support_wrds", value: "1"),
            URLQueryItem(name: "user_unique_id", value: userUniqueID),
            URLQueryItem(name: "im_path", value: "/webcast/im/fetch/"),
            URLQueryItem(name: "identity", value: "audience"),
            URLQueryItem(name: "need_persist_msg_count", value: "15"),
            URLQueryItem(name: "insert_task_id", value: ""),
            URLQueryItem(name: "live_reason", value: ""),
            URLQueryItem(name: "room_id", value: roomID),
            URLQueryItem(name: "heartbeatDuration", value: "0"),
            URLQueryItem(
                name: "signature",
                value: SignatureManager.shared.liveSignature(
                    roomID: roomID,
                    userUniqueID: userUniqueID,
                    userAgent: Self.userAgent
                )
            )
        ]
        guard let url = components.url else { throw APIError.invalidURL }
        return url
    }

    private static func fetchQueryItems(roomID: String, userUniqueID: String, msToken: String) -> [URLQueryItem] {
        [
            URLQueryItem(name: "resp_content_type", value: "protobuf"),
            URLQueryItem(name: "did_rule", value: "3"),
            URLQueryItem(name: "device_id", value: ""),
            URLQueryItem(name: "app_name", value: "douyin_web"),
            URLQueryItem(name: "endpoint", value: "live_pc"),
            URLQueryItem(name: "support_wrds", value: "1"),
            URLQueryItem(name: "user_unique_id", value: userUniqueID),
            URLQueryItem(name: "identity", value: "audience"),
            URLQueryItem(name: "need_persist_msg_count", value: "15"),
            URLQueryItem(name: "room_id", value: roomID),
            URLQueryItem(name: "version_code", value: "180800"),
            URLQueryItem(name: "live_id", value: "1"),
            URLQueryItem(name: "aid", value: "6383"),
            URLQueryItem(name: "fetch_rule", value: "1"),
            URLQueryItem(name: "cursor", value: ""),
            URLQueryItem(name: "internal_ext", value: ""),
            URLQueryItem(name: "device_platform", value: "web"),
            URLQueryItem(name: "cookie_enabled", value: "true"),
            URLQueryItem(name: "browser_language", value: "zh-CN"),
            URLQueryItem(name: "browser_platform", value: "Win32"),
            URLQueryItem(name: "browser_name", value: "Mozilla"),
            URLQueryItem(name: "browser_version", value: Self.userAgent),
            URLQueryItem(name: "browser_online", value: "true"),
            URLQueryItem(name: "tz_name", value: "Asia/Shanghai"),
            URLQueryItem(name: "msToken", value: msToken)
        ]
    }

    private static func fallbackBootstrap(roomID: String, userUniqueID: String, cookie: String) -> LiveBootstrap {
        let milliseconds = Int64(Date().timeIntervalSince1970 * 1_000)
        return LiveBootstrap(
            userUniqueID: userUniqueID,
            cookie: cookie,
            cursor: "t-\(milliseconds)_r-1_d-1_u-1_h-1",
            internalExt: "internal_src:dim|wss_push_room_id:\(roomID)|wss_push_did:\(userUniqueID)|first_req_ms:\(milliseconds)|fetch_time:\(milliseconds)|seq:1|wss_info:0-\(milliseconds)-0-0",
            initialResponse: nil
        )
    }

    private static func persistentAnonymousID() -> String {
        let key = "douyin_live_user_unique_id"
        if let value = UserDefaults.standard.string(forKey: key), value.count >= 18 { return value }
        let value = String(Int64.random(in: 1_000_000_000_000_000_000...8_999_999_999_999_999_999))
        UserDefaults.standard.set(value, forKey: key)
        return value
    }

    private static func firstMatch(in text: String, patterns: [String]) -> String? {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: text, range: range),
                  match.numberOfRanges > 1,
                  let valueRange = Range(match.range(at: 1), in: text) else { continue }
            return String(text[valueRange])
        }
        return nil
    }

    private static func mergingTTWID(into cookie: String, setCookie: String?) -> String {
        guard cookieValue(named: "ttwid", in: cookie) == nil,
              let setCookie,
              let value = firstMatch(in: setCookie, patterns: [#"(?:^|[,;]\s*)ttwid=([^;,\s]+)"#]) else {
            return cookie
        }
        return cookie.isEmpty ? "ttwid=\(value)" : "\(cookie); ttwid=\(value)"
    }

    private static func cookieValue(named name: String, in cookie: String) -> String? {
        cookie.split(separator: ";").lazy.compactMap { field -> String? in
            let pieces = field.split(separator: "=", maxSplits: 1).map(String.init)
            guard pieces.count == 2,
                  pieces[0].trimmingCharacters(in: .whitespaces) == name else { return nil }
            return pieces[1]
        }.first
    }
}

private struct LiveBootstrap {
    let userUniqueID: String
    let cookie: String
    let cursor: String
    let internalExt: String
    let initialResponse: LivePushResponse?
}

private struct LivePushFrame { let logID: UInt64; let payload: Data }
private struct LivePushMessage { let method: String; let payload: Data; let messageID: UInt64 }
private struct LivePushResponse {
    let messages: [LivePushMessage]
    let cursor: String
    let internalExt: String
    let needAck: Bool
}

private enum LiveProtobuf {
    static func decodePushFrame(_ data: Data) throws -> LivePushFrame {
        var reader = ProtoReader(data)
        var logID: UInt64 = 0
        var payload = Data()
        while let field = try reader.nextField() {
            switch (field.number, field.wireType) {
            case (2, 0): logID = try reader.readVarint()
            case (8, 2): payload = try reader.readBytes()
            default: try reader.skip(wireType: field.wireType)
            }
        }
        return LivePushFrame(logID: logID, payload: payload)
    }

    static func decodeResponse(_ data: Data) throws -> LivePushResponse {
        var reader = ProtoReader(data)
        var messages: [LivePushMessage] = []
        var cursor = ""
        var internalExt = ""
        var needAck = false
        while let field = try reader.nextField() {
            switch (field.number, field.wireType) {
            case (1, 2): messages.append(try decodeMessage(reader.readBytes()))
            case (2, 2): cursor = try reader.readString()
            case (5, 2): internalExt = try reader.readString()
            case (9, 0): needAck = try reader.readVarint() != 0
            default: try reader.skip(wireType: field.wireType)
            }
        }
        return LivePushResponse(messages: messages, cursor: cursor, internalExt: internalExt, needAck: needAck)
    }

    static func decodeChatMessage(_ data: Data) throws -> (nickname: String, content: String) {
        var reader = ProtoReader(data)
        var nickname = ""
        var content = ""
        while let field = try reader.nextField() {
            switch (field.number, field.wireType) {
            case (2, 2): nickname = try decodeUserNickname(reader.readBytes())
            case (3, 2): content = try reader.readString()
            default: try reader.skip(wireType: field.wireType)
            }
        }
        return (nickname, content)
    }

    static func pushFrame(logID: UInt64 = 0, payloadType: String, payload: Data = Data()) -> Data {
        var data = Data()
        if logID != 0 { data.appendVarintField(2, value: logID) }
        data.appendStringField(7, value: payloadType)
        if !payload.isEmpty { data.appendBytesField(8, value: payload) }
        return data
    }

    private static func decodeMessage(_ data: Data) throws -> LivePushMessage {
        var reader = ProtoReader(data)
        var method = ""
        var payload = Data()
        var messageID: UInt64 = 0
        while let field = try reader.nextField() {
            switch (field.number, field.wireType) {
            case (1, 2): method = try reader.readString()
            case (2, 2): payload = try reader.readBytes()
            case (3, 0): messageID = try reader.readVarint()
            default: try reader.skip(wireType: field.wireType)
            }
        }
        return LivePushMessage(method: method, payload: payload, messageID: messageID)
    }

    private static func decodeUserNickname(_ data: Data) throws -> String {
        var reader = ProtoReader(data)
        var nickname = ""
        while let field = try reader.nextField() {
            if field.number == 3, field.wireType == 2 {
                nickname = try reader.readString()
            } else {
                try reader.skip(wireType: field.wireType)
            }
        }
        return nickname
    }
}

private struct ProtoReader {
    enum DecodeError: Error { case malformed }
    private let data: Data
    private var index: Data.Index

    init(_ data: Data) { self.data = data; index = data.startIndex }

    mutating func nextField() throws -> (number: Int, wireType: Int)? {
        guard index < data.endIndex else { return nil }
        let key = try readVarint()
        let number = Int(key >> 3)
        guard number > 0 else { throw DecodeError.malformed }
        return (number, Int(key & 0x7))
    }

    mutating func readVarint() throws -> UInt64 {
        var value: UInt64 = 0
        for shift in stride(from: 0, through: 63, by: 7) {
            guard index < data.endIndex else { throw DecodeError.malformed }
            let byte = data[index]
            index = data.index(after: index)
            value |= UInt64(byte & 0x7f) << UInt64(shift)
            if byte & 0x80 == 0 { return value }
        }
        throw DecodeError.malformed
    }

    mutating func readBytes() throws -> Data {
        let length = try readVarint()
        guard length <= UInt64(Int.max),
              let end = data.index(index, offsetBy: Int(length), limitedBy: data.endIndex) else {
            throw DecodeError.malformed
        }
        let value = data[index..<end]
        index = end
        return Data(value)
    }

    mutating func readString() throws -> String {
        guard let value = String(data: try readBytes(), encoding: .utf8) else {
            throw DecodeError.malformed
        }
        return value
    }

    mutating func skip(wireType: Int) throws {
        switch wireType {
        case 0: _ = try readVarint()
        case 1: try advance(8)
        case 2: try advance(Int(try readVarint()))
        case 5: try advance(4)
        default: throw DecodeError.malformed
        }
    }

    private mutating func advance(_ count: Int) throws {
        guard count >= 0,
              let end = data.index(index, offsetBy: count, limitedBy: data.endIndex) else {
            throw DecodeError.malformed
        }
        index = end
    }
}

private extension Data {
    var isGzip: Bool {
        count >= 2 && self[startIndex] == 0x1f && self[index(after: startIndex)] == 0x8b
    }

    mutating func appendVarintField(_ number: UInt64, value: UInt64) {
        appendVarint(number << 3)
        appendVarint(value)
    }

    mutating func appendStringField(_ number: UInt64, value: String) {
        appendBytesField(number, value: Data(value.utf8))
    }

    mutating func appendBytesField(_ number: UInt64, value: Data) {
        appendVarint((number << 3) | 2)
        appendVarint(UInt64(value.count))
        append(value)
    }

    mutating func appendVarint(_ source: UInt64) {
        var value = source
        while value >= 0x80 {
            append(UInt8(value & 0x7f) | 0x80)
            value >>= 7
        }
        append(UInt8(value))
    }
}

private enum Gzip {
    enum DecodeError: Error { case malformed, failed }

    static func decompress(_ data: Data) throws -> Data {
        let payload = try deflatePayload(in: data)
        var capacity = max(64 * 1_024, payload.count * 6)
        while capacity <= 16 * 1_024 * 1_024 {
            var output = Data(count: capacity)
            let decoded = output.withUnsafeMutableBytes { outputBuffer in
                payload.withUnsafeBytes { inputBuffer in
                    compression_decode_buffer(
                        outputBuffer.bindMemory(to: UInt8.self).baseAddress!,
                        capacity,
                        inputBuffer.bindMemory(to: UInt8.self).baseAddress!,
                        payload.count,
                        nil,
                        COMPRESSION_ZLIB
                    )
                }
            }
            if decoded > 0 {
                output.count = decoded
                return output
            }
            capacity *= 2
        }
        throw DecodeError.failed
    }

    private static func deflatePayload(in data: Data) throws -> Data {
        guard data.isGzip, data.count > 18 else { throw DecodeError.malformed }
        var index = 10
        let flags = data[data.startIndex + 3]
        if flags & 0x04 != 0 {
            guard index + 2 <= data.count else { throw DecodeError.malformed }
            let length = Int(data[data.startIndex + index]) | (Int(data[data.startIndex + index + 1]) << 8)
            index += 2 + length
        }
        for flag: UInt8 in [0x08, 0x10] where flags & flag != 0 {
            while index < data.count, data[data.startIndex + index] != 0 { index += 1 }
            index += 1
        }
        if flags & 0x02 != 0 { index += 2 }
        guard index < data.count - 8 else { throw DecodeError.malformed }
        return data.subdata(in: index..<(data.count - 8))
    }
}
