import Foundation
import JavaScriptCore
import CryptoKit

class SignatureManager {
    static let shared = SignatureManager()
    private var context: JSContext?

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

    func liveSignature(roomID: String, userUniqueID: String, userAgent: String) -> String {
        let source = "live_id=1,aid=6383,version_code=180800,webcast_sdk_version=1.0.15,room_id=\(roomID),sub_room_id=,sub_channel_id=,did_rule=3,user_unique_id=\(userUniqueID),device_platform=web,device_type=,ac=,identity=audience"
        let digest = Insecure.MD5.hash(data: Data(source.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return sign(value: digest, userAgent: userAgent)
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
