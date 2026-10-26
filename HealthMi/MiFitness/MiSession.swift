import Foundation

/// 一次成功登录后的会话凭据（对应 Python `_login_with_token` 得到的字段）。
struct MiSessionState: Sendable {
    let userId: String
    let passToken: String
    /// 解 Base64 后的 ssecurity 原始字节，用于派生 RC4 密钥。
    let ssecurity: [UInt8]
    /// 重定向后收集到的会话 Cookie 串（`name=value; name=value`）。
    let cookies: String
}

enum MiLoginError: LocalizedError {
    case badPayload(String)
    case loginRejected(code: Int?, description: String?)
    case network(Error)

    var errorDescription: String? {
        switch self {
        case .badPayload(let detail):
            return "登录响应格式异常：\(detail)"
        case .loginRejected(let code, let description):
            return "登录被拒绝（code=\(code ?? -1)）：\(description ?? "未知错误")"
        case .network(let error):
            return "网络错误：\(error.localizedDescription)"
        }
    }
}

/// 登录 HTTP 客户端（对应 Python `_login_with_token` + `_read_login_payload`）。
enum MiSessionClient {
    private static let loginPrefix = "&&&START&&&"

    /// 用小米账号 Cookie 换取服务会话。
    /// - Parameters:
    ///   - userId: account.xiaomi.com Cookie 中的 userId
    ///   - passToken: 账号 Cookie 中的 passToken（有效期短，过期后需重新获取）
    static func login(userId: String, passToken: String, metrics: RequestMetrics? = nil) async throws -> MiSessionState {
        try Task.checkCancellation()
        var request = URLRequest(url: URL(string: "https://account.xiaomi.com/pass/serviceLogin?_json=true&sid=miothealth")!)
        request.setValue("userId=\(userId); passToken=\(passToken)", forHTTPHeaderField: "Cookie")

        request.timeoutInterval = 15
        metrics?.request()
        let (data, response) = try await URLSession.shared.data(for: request)
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse else {
            throw MiLoginError.network(URLError(.badServerResponse))
        }
        guard (200..<300).contains(http.statusCode) else {
            throw MiLoginError.loginRejected(code: http.statusCode, description: "HTTP \(http.statusCode)")
        }
        guard let text = String(data: data, encoding: .utf8), text.hasPrefix(loginPrefix) else {
            throw MiLoginError.badPayload("响应缺少 \(loginPrefix) 前缀")
        }

        let json = text.dropFirst(loginPrefix.count).data(using: .utf8) ?? Data()
        guard let obj = MiJSON.object(from: json) else {
            throw MiLoginError.badPayload("无法解析 JSON")
        }

        // 若登录被拒，服务端返回 code 而非 passToken
        if let code = MiJSON.int(obj["code"]), code != 0, obj["passToken"] == nil {
            throw MiLoginError.loginRejected(code: code, description: MiJSON.string(obj["description"]))
        }

        guard let newPassToken = MiJSON.string(obj["passToken"]),
              let ssecurityB64 = MiJSON.string(obj["ssecurity"]),
              let ssecurity = Data(base64Encoded: ssecurityB64),
              let location = MiJSON.string(obj["location"])
        else {
            throw MiLoginError.badPayload("缺少 passToken/ssecurity/location")
        }
        let resolvedUserId = MiJSON.string(obj["userId"]) ?? userId

        // 跟随 location 收集会话 Cookie。
        guard let redirectURL = URL(string: location) else {
            throw MiLoginError.badPayload("location 无法解析为 URL")
        }
        var redirectRequest = URLRequest(url: redirectURL)
        redirectRequest.timeoutInterval = 15
        metrics?.request()
        let (_, redirectResponse) = try await URLSession.shared.data(for: redirectRequest)
        try Task.checkCancellation()
        guard let redirectHTTP = redirectResponse as? HTTPURLResponse else {
            throw MiLoginError.network(URLError(.badServerResponse))
        }

        // 注意：URLSession 会把多个 Set-Cookie 头合并成一个 ", " 连接的字符串，
        // 而 `value(forHTTPHeaderField:)` 只返回第一个。这里必须解析合并串拿到全部 cookie
        // （否则会丢掉关键的 serviceToken，导致后续数据请求被判定未认证）。
        let cookieHeader = (redirectHTTP.allHeaderFields.first {
            ($0.key as? String)?.lowercased() == "set-cookie"
        }?.value as? String) ?? ""

        let cookieParts: [String] = cookieHeader
            .components(separatedBy: ", ")
            .compactMap { chunk in
                let nameValue = chunk.split(separator: ";", maxSplits: 1).first.map(String.init) ?? ""
                return nameValue.contains("=") ? nameValue : nil
            }
        let cookies = cookieParts.joined(separator: "; ")

        return MiSessionState(
            userId: resolvedUserId,
            passToken: newPassToken,
            ssecurity: Array(ssecurity),
            cookies: cookies
        )
    }
}
