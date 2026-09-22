// ==============================================================================
// 网关单一事实源（Single Source of Truth）
//
// 背景（v1.4.0 之前的维护负担）：
//   网关的模型名单、地址与二进制路径此前被本工具**抄了多份死名单**：
//     · `GatewayCatalog.knownGatewaySlugs` 硬编码两个 slug
//     · `InjectionEngine.syncCodexModelCatalogIfAvailable` 内嵌一段 Python 又写一遍
//     · `Injector.swift` 把 base_url 与网关二进制绝对路径写死在字符串里
//   于是网关一加模型，用户就得在好几处手工同步；换用户名或换机器时路径直接失效。
//
// 事实：网关自己就声明了这一切。`codex-gateway` 把 `base_url`、`models` 路由表
// （deepseek → ark/DeepSeek-V4.1-Flash 这类）与端口写在
// `~/.config/codex-gateway/config.json`（可用 `CODEX_GATEWAY_HOME` 覆盖）。
// 本文件把它读成权威事实源，工具各处一律从这里取，不再保留任何副本。
//
// 反例边界：
//   1) 本文件**只读**网关配置。网关是独立项目，它的配置由它自己与它的管理页负责；
//      本工具改写它会造成两个程序争夺同一份状态。
//   2) 网关不存在或配置缺失时，如实返回 nil / 空数组，让上层降级为
//      「回退到落点登记值」或「跳过同步」，绝不编造模型名。
// ==============================================================================
import Foundation

/// `~/.config/codex-gateway/config.json` 的只读视图
public struct GatewayConfig: Sendable {

    /// 网关配置目录（未展开 `~`）
    public static let directoryHint = "~/.config/codex-gateway"
    public static let configPathHint = "~/.config/codex-gateway/config.json"

    /// 默认配置路径，尊重 `CODEX_GATEWAY_HOME`（与网关自身一致）
    public static var defaultPath: String {
        let env = ProcessInfo.processInfo.environment["CODEX_GATEWAY_HOME"]
        let dir = (env?.isEmpty == false) ? PathKit.expand(env!) : PathKit.expand(directoryHint)
        return (dir as NSString).appendingPathComponent("config.json")
    }

    /// 一个网关声明的模型：内部线路名（deepseek / gemini）→ 上游真实模型名
    public struct ModelRoute: Sendable, Hashable {
        /// 网关内部的线路键（`models` 字典的键），例如 `deepseek`
        public var route: String
        /// 上游真实模型名，即客户端要填的 slug，例如 `ark/DeepSeek-V4.1-Flash`
        public var upstreamModel: String

        public init(route: String, upstreamModel: String) {
            self.route = route
            self.upstreamModel = upstreamModel
        }
    }

    /// 网关上游基址，例如 `http://192.168.1.200:8080/v1`
    public var baseURL: String
    /// 网关本地服务端口
    public var port: Int?
    /// 声明的模型路由（按配置里的键序）
    public var routes: [ModelRoute]
    /// 配置文件的最后修改时间，供界面展示「清单有多新」
    public var updatedAt: Date?
    /// 实际读取的路径（已展开）
    public var sourcePath: String

    /// 声明里的全部上游模型名（去重保序）—— 这就是网关侧的真实模型清单
    public var upstreamModels: [String] {
        var seen = Set<String>()
        return routes.compactMap { seen.insert($0.upstreamModel).inserted ? $0.upstreamModel : nil }
    }

    public var isUsable: Bool { !baseURL.isEmpty && !routes.isEmpty }

    /// 模型在 Codex 菜单里的显示名。
    ///
    /// 刻意不是手写映射表：显示名由 slug 推导（`ark/DeepSeek-V4.1-Flash` → `DeepSeek V4.1 Flash`），
    /// 这样网关新增模型时菜单里自然出现一个可读名字，不需要任何人改代码。
    public static func displayName(forSlug slug: String) -> String {
        var s = slug
        if let slash = s.lastIndex(of: "/") { s = String(s[s.index(after: slash)...]) }
        // 版本号与型号之间的连字符换成空格：V4.1-Flash → V4.1 Flash
        s = s.replacingOccurrences(of: "-", with: " ")
        // 保留小数点与加号，其余非字母数字按空格归并
        s = s.replacingOccurrences(
            of: "[^A-Za-z0-9\u{4e00}-\u{9FFF}.+]+",
            with: " ",
            options: .regularExpression
        )
        s = s.split(separator: " ").joined(separator: " ")
        if s.isEmpty { s = slug }
        return "\(s)（公司网关）"
    }

    // MARK: 读取

    /// 读取网关配置；文件不存在或不可解析时返回 nil（上层据此降级）
    public static func load(path: String = defaultPath) -> GatewayConfig? {
        let expanded = PathKit.expand(path)
        guard let data = FileManager.default.contents(atPath: expanded),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return parse(root, sourcePath: expanded)
    }

    /// 从已解析的 JSON 字典构造（供测试直接注入，不必落盘）
    public static func parse(_ root: [String: Any], sourcePath: String = "") -> GatewayConfig {
        let baseURL = (root["base_url"] as? String) ?? ""
        let port = (root["port"] as? NSNumber)?.intValue
        var routes: [ModelRoute] = []
        if let models = root["models"] as? [String: Any] {
            // 字典本身无序，按键排序保证结果稳定（否则每次读出的顺序可能不同）
            for key in models.keys.sorted() {
                guard let upstream = models[key] as? String, !upstream.isEmpty else { continue }
                routes.append(ModelRoute(route: key, upstreamModel: upstream))
            }
        }
        var updated: Date?
        if let raw = root["updated_at"] as? String {
            updated = ISO8601DateFormatter().date(from: raw)
                ?? {
                    let f = ISO8601DateFormatter()
                    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                    return f.date(from: raw)
                }()
        }
        return GatewayConfig(
            baseURL: baseURL,
            port: port,
            routes: routes,
            updatedAt: updated,
            sourcePath: sourcePath
        )
    }

    /// 便捷读取：不存在时返回空清单而不是抛错
    public static func loadOrEmpty(path: String = defaultPath) -> GatewayConfig {
        load(path: path) ?? GatewayConfig(baseURL: "", port: nil, routes: [], updatedAt: nil, sourcePath: PathKit.expand(path))
    }

    /// 网关声明的模型清单（含去重后的 slug）
    public static func declaredModels(path: String = defaultPath) -> [String] {
        loadOrEmpty(path: path).upstreamModels
    }

    /// 网关二进制路径：优先取 `config.toml` 里 `codex_gateway.auth.command` 已登记的值，
    /// 其次在常见位置探测。**不再硬编码某个用户的家目录**。
    public static func binaryPath(codexConfigText: String? = nil) -> String? {
        // ① 已经写进 Codex 配置里的那条命令最可信：它就是 Codex 实际在用的
        if let text = codexConfigText, let registered = registeredAuthCommand(in: text) {
            if FileManager.default.isExecutableFile(atPath: registered) { return registered }
        }
        // ② 环境变量显式指定
        if let env = ProcessInfo.processInfo.environment["CODEX_GATEWAY_BIN"], !env.isEmpty {
            let expanded = PathKit.expand(env)
            if FileManager.default.isExecutableFile(atPath: expanded) { return expanded }
        }
        // ③ 常见安装位置探测（用户家目录下的项目路径，不写死具体用户名）
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            "\(home)/Documents/ChatGPT/对接gemini/bin/codex-gateway",
            "\(home)/.local/bin/codex-gateway",
            "/usr/local/bin/codex-gateway",
            "/opt/homebrew/bin/codex-gateway"
        ]
        // ④ PATH 查找
        let fromPath = whichCodexGateway()
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) } ?? fromPath
    }

    /// 从 `config.toml` 的 `[model_providers.codex_gateway.auth]` 段取出 `command` 值
    public static func registeredAuthCommand(in configText: String, providerName: String = "codex_gateway") -> String? {
        var inAuth = false
        let header = "[model_providers.\(providerName).auth]"
        for line in configText.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") {
                inAuth = (trimmed == header)
                continue
            }
            guard inAuth else { continue }
            guard let range = trimmed.range(of: "command") else { continue }
            let rest = trimmed[range.upperBound...]
            guard let eq = rest.firstIndex(of: "=") else { continue }
            var value = String(rest[rest.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 { value = String(value.dropFirst().dropLast()) }
            if !value.isEmpty { return value }
        }
        return nil
    }

    /// 在 PATH 中查找 codex-gateway（不依赖硬编码目录）
    static func whichCodexGateway() -> String? {
        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        for dir in path.split(separator: ":") {
            let candidate = "\(dir)/codex-gateway"
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }
}
