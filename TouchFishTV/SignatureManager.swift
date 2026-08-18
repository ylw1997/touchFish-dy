import Foundation
import JavaScriptCore
import CryptoKit

class SignatureManager {
    static let shared = SignatureManager()
    private var context: JSContext?
    private var liveCounter: UInt16 = 0

    private init() {
        setupJSContext()
    }

    private func setupJSContext() {
        guard let context = JSContext() else {
            print("[SignatureManager] Failed to create JSContext")
            return
        }
        // 设置虚假的 module 和 window，以兼容 CommonJS 打包格式
        context.evaluateScript("var module = { exports: {} }; var window = null;")
        
        // 加载 xbogus.js
        guard let path = Bundle.main.path(forResource: "xbogus", ofType: "js") else {
            print("[SignatureManager] Failed to find xbogus.js in Bundle")
            return
        }
        
        do {
            let jsContent = try String(contentsOfFile: path, encoding: .utf8)
            context.evaluateScript(jsContent)
            self.context = context
            print("[SignatureManager] JSContext loaded successfully with xbogus.js")
        } catch {
            print("[SignatureManager] Failed to load xbogus.js contents: \(error)")
        }
    }

    func sign(url: String, userAgent: String) -> String {
        guard context != nil else {
            print("[SignatureManager] JSContext is nil, returning unsigned URL")
            return url
        }
        
        // Bundle 内是 xbogus 的算法本体；npm 入口会先截取 query，再调用这个函数。
        // 因此这里必须保持相同契约，只传入问号后的查询参数。
        let query = url.range(of: "?").map { String(url[$0.upperBound...]) } ?? ""
        let signedValue = sign(value: query, userAgent: userAgent)
        if signedValue.isEmpty {
            return url
        }
        
        let separator = url.contains("?") ? "&" : "?"
        return "\(url)\(separator)X-Bogus=\(signedValue)"
    }

    func liveSignature(roomID: String, userUniqueID: String) -> String {
        let source = "live_id=1,aid=6383,version_code=180800,webcast_sdk_version=1.0.15,room_id=\(roomID),sub_room_id=,sub_channel_id=,did_rule=3,user_unique_id=\(userUniqueID),device_platform=web,device_type=,ac=,identity=audience"
        let stub = Data(Insecure.MD5.hash(data: Data(source.utf8)))
        let emptyDigest = Data(Insecure.MD5.hash(data: Data()))
        let payloadDigest = Array(Insecure.MD5.hash(data: emptyDigest))
        let stubDigest = Array(Insecure.MD5.hash(data: stub))

        liveCounter &+= 1
        var plain: [UInt8] = [
            UInt8(liveCounter & 0x3f),
            UInt8(truncatingIfNeeded: liveCounter >> 8),
            0x09,
            0x0c,
            payloadDigest[14], payloadDigest[15],
            stubDigest[14], stubDigest[15],
            UInt8.random(in: 0...254)
        ]
        plain.append(plain.reduce(0, ^))
        let key = UInt8.random(in: 0...254)
        let encrypted = Self.rc4(plain, key: key)
        let prefix: UInt8 = Bool.random() ? 0x50 : 0x40
        return Self.liveBase64([prefix, key] + encrypted)
    }

    private static func rc4(_ input: [UInt8], key: UInt8) -> [UInt8] {
        var box = Array(UInt8.min...UInt8.max)
        var j = 0
        for i in box.indices {
            j = (j + Int(box[i]) + Int(key)) & 0xff
            box.swapAt(i, j)
        }
        var i = 0
        j = 0
        return input.map { byte in
            i = (i + 1) & 0xff
            j = (j + Int(box[i])) & 0xff
            box.swapAt(i, j)
            return byte ^ box[(Int(box[i]) + Int(box[j])) & 0xff]
        }
    }

    private static func liveBase64(_ input: [UInt8]) -> String {
        let alphabet = Array("Dkdpgh4ZKsQB80/Mfvw36XI1R25+WUAlEi7NLboqYTOPuzmFjJnryx9HVGcaStCe")
        var result = ""
        for start in stride(from: 0, to: input.count, by: 3) {
            let count = min(3, input.count - start)
            let first = Int(input[start])
            let second = count > 1 ? Int(input[start + 1]) : 0
            let third = count > 2 ? Int(input[start + 2]) : 0
            let value = (first << 16) | (second << 8) | third
            result.append(alphabet[(value >> 18) & 63])
            result.append(alphabet[(value >> 12) & 63])
            result.append(count > 1 ? alphabet[(value >> 6) & 63] : "=")
            result.append(count > 2 ? alphabet[value & 63] : "=")
        }
        return result
    }

    private func sign(value: String, userAgent: String) -> String {
        guard !value.isEmpty,
              let context,
              let signFunction = context.objectForKeyedSubscript("module")?
                .objectForKeyedSubscript("exports"),
              !signFunction.isUndefined,
              let result = signFunction.call(withArguments: [value, userAgent]) else {
            print("[SignatureManager] Calling sign function failed")
            return ""
        }
        return result.toString() ?? ""
    }
}
