// ==============================================================================
// 健康探测：以最小成本校验密钥是否可用
//
// 反例边界（重要）：
//   1. 探测会产生一次真实网络请求，仅发送到厂商官方域名，不做任何第三方上报；
//   2. 本工具**不会自动后台轮询**，只有用户显式触发（界面按钮或 CLI 命令）才发起；
//   3. 探测结果只代表「此刻鉴权是否通过」，不代表模型可用性或账户余额充足。
// ==============================================================================
import Foundation

public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (status: Int, body: Data)
}

public struct URLSessionTransport: HTTPTransport {
    public let timeout: TimeInterval

    public init(timeout: TimeInterval = 15) {
        self.timeout = timeout
    }

    public func send(_ request: URLRequest) async throws -> (status: Int, body: Data) {
        var req = request
        req.timeoutInterval = timeout
        let (data, response) = try await URLSession.shared.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        return (status, data)
    }
}

public final class HealthChecker {
    private let transport: HTTPTransport

    public init(transport: HTTPTransport = URLSessionTransport()) {
        self.transport = transport
    }

    /// 依据厂商定义构造探测请求
    public func makeRequest(provider: Provider, secret: String) -> URLRequest? {
        guard let base = provider.baseURL, let healthPath = provider.healthPath else { return nil }
        var urlString = base.hasSuffix("/") ? String(base.dropLast()) : base
        urlString += healthPath.hasPrefix("/") ? healthPath : "/" + healthPath

        if provider.authStyle == .queryKey {
            guard var comps = URLComponents(string: urlString) else { return nil }
            comps.queryItems = [URLQueryItem(name: "key", value: secret)]
            guard let url = comps.url else { return nil }
            return URLRequest(url: url)
        }

        guard let url = URL(string: urlString) else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        switch provider.authStyle {
        case .bearer, .bearerAPIKey:
            request.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
        case .headerKey:
            request.setValue(secret, forHTTPHeaderField: "x-api-key")
        case .queryKey:
            break
        }
        for (k, v) in provider.extraHeaders {
            request.setValue(v, forHTTPHeaderField: k)
        }
        request.setValue("KeyInjector/1.0 (macOS)", forHTTPHeaderField: "User-Agent")
        return request
    }

    /// 探测单个密钥
    public func check(provider: Provider, secret: String) async -> CheckSummary {
        guard let request = makeRequest(provider: provider, secret: secret) else {
            return CheckSummary(
                status: .unknown,
                message: "该厂商未配置探测端点（可在 config/providers.json 中补充 baseURL 与 healthPath）"
            )
        }
        let started = Date()
        do {
            let (status, body) = try await transport.send(request)
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            return Self.classify(status: status, body: body, latencyMS: ms)
        } catch {
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            return CheckSummary(status: .unreachable, latencyMS: ms, message: "网络请求失败：\(error.localizedDescription)")
        }
    }

    /// 依据 HTTP 状态码分类（供单元测试直接验证，无需真实网络）
    public static func classify(status: Int, body: Data, latencyMS: Int? = nil) -> CheckSummary {
        let snippet = String(decoding: body.prefix(200), as: UTF8.self)
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces)
        switch status {
        case 200..<300:
            return CheckSummary(status: .valid, httpStatus: status, latencyMS: latencyMS, message: "鉴权通过（HTTP \(status)）")
        case 401, 403:
            return CheckSummary(status: .invalid, httpStatus: status, latencyMS: latencyMS, message: "密钥被拒绝（HTTP \(status)）：\(snippet)")
        case 402, 429:
            return CheckSummary(status: .quota, httpStatus: status, latencyMS: latencyMS, message: "额度不足或触发限流（HTTP \(status)）：\(snippet)")
        case 404:
            return CheckSummary(status: .unknown, httpStatus: status, latencyMS: latencyMS, message: "探测端点不存在（HTTP 404），请核对 healthPath 配置")
        default:
            return CheckSummary(status: .unknown, httpStatus: status, latencyMS: latencyMS, message: "未预期状态码 HTTP \(status)：\(snippet)")
        }
    }

    /// 并发探测多个密钥，保持结果与输入顺序一致
    public func checkAll(_ items: [(record: KeyRecord, provider: Provider, secret: String)]) async -> [String: CheckSummary] {
        await withTaskGroup(of: (String, CheckSummary).self) { group in
            for item in items {
                group.addTask { [transport] in
                    let checker = HealthChecker(transport: transport)
                    let summary = await checker.check(provider: item.provider, secret: item.secret)
                    return (item.record.id, summary)
                }
            }
            var out: [String: CheckSummary] = [:]
            for await (id, summary) in group { out[id] = summary }
            return out
        }
    }
}
