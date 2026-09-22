// ==============================================================================
// 模型发现（Model Discovery）：回答「这把 key 到底能提供哪些模型」
//
// 背景（用户 2026-09-22 反馈）：
//   密钥库此前只能通过宿主配置反推「这个 Key 供给了哪些宿主菜单里的模型」，
//   于是公司AI综合 Key 只显示 6 个模型 —— 那是**宿主声明**的数量，
//   而不是这把 Key 在它自己端点上真实可用的模型数量。用户要求
//   「密钥库这边可以识别出 key 有什么模型可以提供」，即从 key 自身取证。
//
// 取证顺序（多级兜底，每一级都如实标注来源与置信度）：
//   T1 端点探测          GET {baseURL}/models（优先用户自填的 baseURL）
//   T2 端点变体          {baseURL}/models、{baseURL}/v1/models、厂商 healthPath
//   T3 响应解析          兼容 OpenAI / Gemini / Ollama / 裸数组四种形态
//   T4 宿主配置映射      探测全失败时回退到 HostModelInventory.bindings
//   T5 名称推断          仅作候选提示，置信度标「推断」，绝不当作事实
//
// 反例边界（务必知悉）：
//   1) 本文件**不写任何宿主配置文件**：发现结果只用于展示与本工具缓存；
//   2) 探测只在用户显式触发时发生（界面按钮 / CLI），不做后台轮询（NOT-003）；
//   3) 探测请求只发往该 Key 自己的端点，不经任何第三方（NOT-002）；
//   4) 缓存与日志只存掩码、指纹与模型名；上游响应正文最多保留 200 字符用于报错；
//   5) 推断结果永远不写成「事实」：界面必须以「推断」降权展示，避免误信（NOT-010）。
// ==============================================================================
import Foundation

// MARK: - 发现来源与置信度

/// 一条模型记录的取证来源
public enum DiscoverySource: String, Codable, Sendable, CaseIterable {
    /// T1/T2/T3：从该 Key 自己的端点拉取并成功解析
    case probe
    /// T4：宿主配置映射（凭据键名 / 端点同源）
    case hostMapped
    /// T5：按模型名归一化后的相似匹配推断
    case inferred
    /// 无法确定
    case unknown

    public var label: String {
        switch self {
        case .probe: return "端点探测"
        case .hostMapped: return "宿主映射"
        case .inferred: return "推断"
        case .unknown: return "未知"
        }
    }

    /// 展示用的置信度分级：事实 > 声明 > 推断
    public var confidence: String {
        switch self {
        case .probe: return "已验证"
        case .hostMapped: return "宿主声明"
        case .inferred: return "推断"
        case .unknown: return "未知"
        }
    }
}

/// 请求超时（秒）：单个候选端点，避免逐个变体串行等待过久
public let discoveryRequestTimeout: TimeInterval = 8

// MARK: - 规范化模型标识

/// 模型标识归一：剥离 `models/` 前缀、命名空间前缀（`ark/`、`openai/` 等）
/// 与首尾空白，保留上游真实大小写。用于**去重与比对**，不用于展示。
public enum ModelIdentifier {
    public static func canonical(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let range = s.range(of: "models/", options: [.anchored, .caseInsensitive]) {
            s = String(s[range.upperBound...])
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 比对键：小写 + 去掉非字母数字，跨宿主/跨网关的同一模型应得到相同结果
    public static func comparisonKey(_ raw: String) -> String {
        ModelIdentity.normalize(canonical(raw))
    }
}

// MARK: - 一条「这把 Key 可提供」的模型

public struct AvailableModel: Codable, Hashable, Sendable {
    /// 上游真实模型 id（如 `gemini-3.8-flash-high`）
    public var modelID: String
    /// 宿主/网关侧显示名；探测来源时等于 id
    public var displayName: String
    /// 取证来源
    public var source: DiscoverySource
    /// 取证依据说明（如「凭据键名 MIDPRO_API_KEY」「端点 http://…/v1/models」）
    public var evidence: String
    public var host: HostKind?
    public var owner: String
    public var inMenu: Bool
    public var credentialKey: String
    public var endpoint: String
    /// 协议级元数据（模型发布时间 / 版本 / 下线公告）。
    ///
    /// 为什么是可选：REQ-024 只对**协议真正提供了这些字段**的厂商填充值，
    /// 其余厂商既不能留空显示，也不能拿本机观测时间冒充——界面必须能区分
    /// 「拿到了」与「该协议不提供」两种状态，故用 nil 表示后者。
    public var metadata: ModelMetadata?

    /// 旧缓存（v1.6.0 之前的 `model-cache.json`）里没有 `metadata` 键，
    /// 解码时必须允许缺失，否则整个缓存反序列化会失败、历史结果全部作废。
    enum CodingKeys: String, CodingKey {
        case modelID, displayName, source, evidence, host, owner, inMenu, credentialKey, endpoint, metadata
    }

    public init(
        modelID: String,
        displayName: String = "",
        source: DiscoverySource,
        evidence: String = "",
        host: HostKind? = nil,
        owner: String = "",
        inMenu: Bool = true,
        credentialKey: String = "",
        endpoint: String = "",
        metadata: ModelMetadata? = nil
    ) {
        self.modelID = modelID
        self.displayName = displayName.isEmpty ? modelID : displayName
        self.source = source
        self.evidence = evidence
        self.host = host
        self.owner = owner
        self.inMenu = inMenu
        self.credentialKey = credentialKey
        self.endpoint = endpoint
        self.metadata = metadata
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        modelID = try c.decode(String.self, forKey: .modelID)
        displayName = try c.decodeIfPresent(String.self, forKey: .displayName) ?? modelID
        source = try c.decodeIfPresent(DiscoverySource.self, forKey: .source) ?? .unknown
        evidence = try c.decodeIfPresent(String.self, forKey: .evidence) ?? ""
        host = try c.decodeIfPresent(HostKind.self, forKey: .host)
        owner = try c.decodeIfPresent(String.self, forKey: .owner) ?? ""
        inMenu = try c.decodeIfPresent(Bool.self, forKey: .inMenu) ?? true
        credentialKey = try c.decodeIfPresent(String.self, forKey: .credentialKey) ?? ""
        endpoint = try c.decodeIfPresent(String.self, forKey: .endpoint) ?? ""
        metadata = try c.decodeIfPresent(ModelMetadata.self, forKey: .metadata)
    }

    /// 排序权重：探测 > 宿主映射 > 推断，同级按模型名
    public var sortKey: (Int, String) {
        let rank: Int
        switch self.source {
        case .probe: rank = 0
        case .hostMapped: rank = 1
        case .inferred: rank = 2
        case .unknown: rank = 3
        }
        return (rank, modelID.lowercased())
    }
}

// MARK: - 协议级模型元数据（REQ-024）

/// 模型的三类协议级事实：**发布时间**、**版本标签**、**下线公告**。
///
/// 官方协议调研结论（见 `docs/knowledge-account-protocols.md`）：
/// - OpenAI `Model.created` 是**发布时间**（Unix 秒），另有 `shutdown_date` 下线公告；
/// - DeepSeek `/models` 只给 `id` / `object` / `owned_by`，**没有任何时间字段**；
/// - Gemini 原生 `Model.version`（如 `001`）是**版本序号不是时间**，只能标成「版本」。
///
/// 因此本类型刻意把「版本标签」与「发布时间」分成两个独立字段：
/// 一旦混用，界面就会把版本号当更新时间展示，属于事实性错误。
public struct ModelMetadata: Codable, Hashable, Sendable {
    /// 模型发布时间（仅当协议真的给了时间字段）
    public var publishedAt: Date?
    /// 发布时间的数据来源标签（如「协议 · created」）；nil 表示该协议不提供
    public var publishedSource: String?
    /// 版本标签（Gemini `version`），**不是时间**
    public var versionTag: String?
    /// 下线公告日期（OpenAI `shutdown_date`，字符串原样，不做日期解析）
    public var shutdownDate: String?

    public init(publishedAt: Date? = nil, publishedSource: String? = nil, versionTag: String? = nil, shutdownDate: String? = nil) {
        self.publishedAt = publishedAt
        self.publishedSource = publishedSource
        self.versionTag = versionTag
        self.shutdownDate = shutdownDate
    }

    /// 是否含任何可用信息（全空时调用方应存 nil，避免缓存里堆无意义对象）
    public var isEmpty: Bool { publishedAt == nil && versionTag == nil && shutdownDate == nil }
}

// MARK: - 端点返回的模型条目（含元数据）

/// `/models` 响应里的一条模型记录：id + 该协议附带的时间 / 版本字段
public struct ModelEntry: Sendable, Hashable {
    public var id: String
    public var metadata: ModelMetadata?

    public init(id: String, metadata: ModelMetadata? = nil) {
        self.id = id
        self.metadata = metadata
    }
}

// MARK: - 账号级额度（DeepSeek 专属，REQ-024 / REQ-026）

/// 单条余额：金额**一律以字符串原样保留**。
///
/// 官方 Schema 里 `total_balance` 等字段都是 string；转成 Double 再显示会引入
/// 浮点误差（`110.00` 可能显示成 `110.0`），对账场景不可接受，故不解析。
public struct BalanceEntry: Codable, Hashable, Sendable {
    public var currency: String
    public var total: String
    public var granted: String
    public var toppedUp: String

    public init(currency: String, total: String = "", granted: String = "", toppedUp: String = "") {
        self.currency = currency
        self.total = total
        self.granted = granted
        self.toppedUp = toppedUp
    }
}

/// 一次额度取证的完整结果。
///
/// 关键设计：额度是**账号级**事实（挂在 Key 上），不是模型级事实。
/// 之所以仍放进 `ModelDiscoveryResult`，是因为它与模型识别同属「点一次识别」
/// 的一次取证动作，界面需要同帧展示，分开两次调用会造成状态不一致。
public struct BalanceInfo: Codable, Hashable, Sendable {
    /// 是否还能调用（DeepSeek `is_available`）。nil 表示未取到，不猜
    public var isAvailable: Bool?
    /// 分币种余额（可能同时有 CNY 与 USD，**不可相加**）
    public var entries: [BalanceEntry]
    public var endpoint: String
    /// 0 表示未发起或网络层失败
    public var httpStatus: Int
    /// 取证依据或失败原因，供界面如实展示
    public var note: String
    /// 「该协议不提供」时为 false：这是**如实标注**，不是失败
    public var supported: Bool
    public var fetchedAt: Date

    public init(
        isAvailable: Bool? = nil,
        entries: [BalanceEntry] = [],
        endpoint: String = "",
        httpStatus: Int = 0,
        note: String = "",
        supported: Bool = true,
        fetchedAt: Date = Date()
    ) {
        self.isAvailable = isAvailable
        self.entries = entries
        self.endpoint = endpoint
        self.httpStatus = httpStatus
        self.note = note
        self.supported = supported
        self.fetchedAt = fetchedAt
    }

    /// 供界面直接使用的一句话摘要
    public var summary: String {
        guard supported else { return "该协议不提供余额接口" }
        if let available = isAvailable {
            let amount = entries.isEmpty
                ? "无余额明细"
                : entries.map { "\($0.total) \($0.currency)" }.joined(separator: " / ")
            return available ? "可调用 · \(amount)" : "余额不足 · \(amount)"
        }
        return note.isEmpty ? "未取到余额" : note
    }
}

// MARK: - 一次发现的结果

/// 单次发现的结果（可整体落盘进缓存）
public struct ModelDiscoveryResult: Codable, Sendable {
    /// 是否成功从端点取证（false 表示已降级到宿主映射 / 推断）
    public var probed: Bool
    /// 实际命中的端点（探测成功时）或尝试过的第一个端点（失败时）
    public var endpoint: String
    /// 探测依据 / 失败原因，供界面如实展示
    public var note: String
    /// 最后一次 HTTP 状态码（0 表示未发起或网络层失败）
    public var httpStatus: Int
    public var models: [AvailableModel]
    /// 账号级额度（仅 DeepSeek 协议可取；其余厂商为 supported=false 的如实标注）
    public var balance: BalanceInfo?
    public var fetchedAt: Date
    /// 取证时该 Key 的指纹：指纹变化即缓存作废，避免旧结果张冠李戴
    public var fingerprint: String

    public init(
        probed: Bool,
        endpoint: String,
        note: String,
        httpStatus: Int = 0,
        models: [AvailableModel],
        balance: BalanceInfo? = nil,
        fetchedAt: Date = Date(),
        fingerprint: String
    ) {
        self.probed = probed
        self.endpoint = endpoint
        self.note = note
        self.httpStatus = httpStatus
        self.models = models
        self.balance = balance
        self.fetchedAt = fetchedAt
        self.fingerprint = fingerprint
    }

    public var sourceLabel: String {
        probed ? DiscoverySource.probe.label : (models.first?.source.label ?? DiscoverySource.unknown.label)
    }

    /// 手动解码：v1.6.0 的 `model-cache.json` 没有 `balance` 键，
    /// 若依赖自动合成会在读取旧缓存时抛错，导致历史识别结果全部丢失重探。
    /// 这里对可选字段一律 `decodeIfPresent`，旧文件照常可读。
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        probed = try c.decodeIfPresent(Bool.self, forKey: .probed) ?? false
        endpoint = try c.decodeIfPresent(String.self, forKey: .endpoint) ?? ""
        note = try c.decodeIfPresent(String.self, forKey: .note) ?? ""
        httpStatus = try c.decodeIfPresent(Int.self, forKey: .httpStatus) ?? 0
        models = try c.decodeIfPresent([AvailableModel].self, forKey: .models) ?? []
        balance = try c.decodeIfPresent(BalanceInfo.self, forKey: .balance)
        fetchedAt = try c.decodeIfPresent(Date.self, forKey: .fetchedAt) ?? Date()
        fingerprint = try c.decodeIfPresent(String.self, forKey: .fingerprint) ?? ""
    }

    /// 面向用户与脚本的模型数：**去重后**的数量。
    ///
    /// 为什么必须只有这一个口径：端点可能把同一模型以多个别名同时返回
    /// （实测公司网关返回 20 条原始条目，其中 `ark/DeepSeek-V4.1-Flash` 与
    /// `DS/DeepSeek V4.1 Flash` 是同一模型的两个名字）。若界面卡片去重、
    /// 分区标题不去重，就会出现「标题 20 个、卡片里 19 个」这种自相矛盾。
    public var modelCount: Int { normalizedModels.count }

    /// 去重排序后的模型列表（同一上游模型只留置信度最高的一条）
    public var normalizedModels: [AvailableModel] {
        var best: [String: AvailableModel] = [:]
        for model in models {
            let key = ModelIdentifier.comparisonKey(model.modelID)
            guard !key.isEmpty else { continue }
            if let existing = best[key], existing.sortKey <= model.sortKey { continue }
            best[key] = model
        }
        return best.values.sorted { $0.sortKey < $1.sortKey }
    }
}

// MARK: - 端点探测请求构造

/// 构造「拉取可用模型」的请求。抽成纯函数以便单元测试与真实网络解耦。
public enum ModelEndpointProbe {

    /// 单个候选端点
    public struct Candidate: Sendable, Hashable {
        public var url: String
        /// 该变体的用途说明，进注释供界面展示
        public var kind: String

        public init(url: String, kind: String) {
            self.url = url
            self.kind = kind
        }
    }

    /// 候选端点顺序：主端点 → 不重复的变体
    ///
    /// - Parameters:
    ///   - baseURL: 该 Key 的自定义 Base URL（优先）；为空则用厂商预设
    ///   - providerBaseURL: 厂商预设 baseURL
    ///   - healthPath: 厂商预设探测路径（通常为 `/models`）
    public static func candidates(
        baseURL: String?,
        providerBaseURL: String?,
        healthPath: String?
    ) -> [Candidate] {
        let custom = (baseURL ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let primary = custom.isEmpty ? (providerBaseURL ?? "").trimmingCharacters(in: .whitespacesAndNewlines) : custom
        guard !primary.isEmpty else { return [] }

        var out: [Candidate] = []
        func add(_ url: String, _ kind: String) {
            let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !out.contains(where: { $0.url == trimmed }) else { return }
            out.append(Candidate(url: trimmed, kind: kind))
        }

        // T1：主端点 + /models
        let primaryKind = custom.isEmpty ? "厂商预设端点" : "自定义端点"
        add(join(primary, "/models"), primaryKind + " /models")

        // T2：变体 —— 有的网关把 /models 挂在根上，有的强制 /v1。
        // 注意：这里必须**无条件尝试**去 /v1 的形态；曾经写成
        // `if !primary.hasSuffix("/v1")` 导致「端点已带 /v1」时不再尝试根路径变体，
        // 而自定义中转端点恰恰最常是 `…/v1` 形态（实测踩坑）。
        add(join(stripTrailingV1(primary), "/models"), "去 /v1 变体 /models")

        // T2：厂商预设的 healthPath（与自定义端点不同源时也值得一试）
        if !custom.isEmpty, let providerBaseURL, !providerBaseURL.isEmpty {
            let path = (healthPath?.isEmpty == false) ? healthPath! : "/models"
            add(join(providerBaseURL, path), "厂商预设 healthPath")
        }
        return out
    }

    private static func join(_ base: String, _ path: String) -> String {
        let b = base.hasSuffix("/") ? String(base.dropLast()) : base
        let p = path.hasPrefix("/") ? path : "/" + path
        return b + p
    }

    private static func stripTrailingV1(_ url: String) -> String {
        let lower = url.lowercased()
        // 必须在路径段边界上判断：`http://h/v1` 可以剥，`http://h/v11` 不行
        if lower.hasSuffix("/v1"), let last = url.lastIndex(of: "/"), url.index(after: last) < url.endIndex {
            return String(url[url.startIndex..<last])
        }
        return url
    }

    /// 构造 GET 请求，鉴权风格与健康探测保持一致（Bearer / x-api-key / ?key=）
    public static func request(
        candidate: Candidate,
        provider: Provider?,
        secret: String,
        timeout: TimeInterval = discoveryRequestTimeout
    ) -> URLRequest? {
        let authStyle = provider?.authStyle ?? .bearer
        let usesCustomEndpoint = !(provider?.baseURL.map { candidate.url.hasPrefix($0) } ?? false)
        var urlString = candidate.url

        if authStyle == .queryKey {
            guard var comps = URLComponents(string: urlString) else { return nil }
            var items = comps.queryItems ?? []
            items.append(URLQueryItem(name: "key", value: secret))
            comps.queryItems = items
            urlString = comps.string ?? urlString
        }

        guard let url = URL(string: urlString) else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        switch authStyle {
        case .headerKey:
            request.setValue(secret, forHTTPHeaderField: "x-api-key")
        case .queryKey:
            // 云凭证（AQ.）与自定义端点走 Bearer，与健康探测口径一致
            if usesCustomEndpoint || secret.hasPrefix("AQ.") {
                request.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
            }
        case .bearer, .bearerAPIKey:
            request.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
        }
        for (k, v) in provider?.extraHeaders ?? [:] {
            request.setValue(v, forHTTPHeaderField: k)
        }
        request.setValue("KeyInjector/1.0 (macOS)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = timeout
        return request
    }

    /// 解析 `/models` 响应体，兼容四种形态：
    ///
    ///   1. OpenAI  ：`{"data":[{"id":"gpt-4o"},…]}`
    ///   2. Gemini  ：`{"models":[{"name":"models/gemini-x"},…]}`
    ///   3. Ollama  ：`{"models":[{"name":"llama3",…}]}`
    ///   4. 裸数组  ：`["a","b"]` 或 `[{"id":"a"},{"model":"b"}]`
    ///
    /// 任何畸形输入一律返回空数组而不是抛错（调用方据此降级到 T4/T5）。
    public static func parseModels(body: Data) -> [String] {
        guard let object = try? JSONSerialization.jsonObject(with: body) else { return [] }

        func idFrom(_ dict: [String: Any]) -> String? {
            for key in ["id", "name", "model", "slug"] {
                if let value = dict[key] as? String, !value.isEmpty {
                    return ModelIdentifier.canonical(value)
                }
            }
            return nil
        }

        var ids: [String] = []
        func collect(_ value: Any) {
            if let array = value as? [Any] {
                for item in array {
                    if let s = item as? String, !s.isEmpty {
                        ids.append(ModelIdentifier.canonical(s))
                    } else if let dict = item as? [String: Any], let id = idFrom(dict) {
                        ids.append(id)
                    }
                }
            } else if let dict = value as? [String: Any], let id = idFrom(dict) {
                ids.append(id)
            }
        }

        if let dict = object as? [String: Any] {
            // 逐个候选键尝试，命中即用（不合并，避免把元数据键当模型列表）
            for key in ["data", "models", "modelList", "items", "result"] {
                if let value = dict[key] {
                    collect(value)
                    if !ids.isEmpty { break }
                }
            }
            if ids.isEmpty {
                // 少数网关直接返回 `{"gpt-4o": {...}}` 这样的映射表；
                // 只有值是**非空对象**时才认，字符串/数字/空对象一律忽略
                // （否则 `{"data":{}}`、`{"error":{}}` 会被当成模型名）。
                // 注意：空 NSDictionary 在 Swift 里满足 `is [String: Any]`，
                // 因此这里用显式 cast + isEmpty 判断，而不是 `is` 检查。
                for (key, value) in dict {
                    guard let nested = value as? [String: Any], !nested.isEmpty else { continue }
                    ids.append(ModelIdentifier.canonical(key))
                }
            }
        } else if object is [Any] {
            collect(object)
        }

        var seen = Set<String>()
        return ids.filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    /// 响应正文摘要：只留 200 字符，用于报错说明（绝不落盘整段响应）
    public static func snippet(_ body: Data) -> String {
        String(decoding: body.prefix(200), as: UTF8.self)
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces)
    }

    // MARK: 带元数据的模型解析（REQ-024）

    /// 解析 `/models` 响应，同时取出协议附带的**发布时间 / 版本 / 下线公告**。
    ///
    /// 与 `parseModels` 的关系：后者保持原签名不变（既有测试与调用点依赖
    /// `[String]` 返回值），本方法是它的超集——`parseModels` 仍可视为
    /// 「只取 id」的简化视图，避免为了新维度破坏既有接口。
    public static func parseModelEntries(body: Data) -> [ModelEntry] {
        guard let object = try? JSONSerialization.jsonObject(with: body) else { return [] }

        func collect(_ value: Any, into out: inout [ModelEntry]) {
            if let array = value as? [Any] {
                for item in array {
                    if let s = item as? String, !s.isEmpty {
                        out.append(ModelEntry(id: ModelIdentifier.canonical(s)))
                    } else if let dict = item as? [String: Any], let id = idFrom(dict) {
                        out.append(ModelEntry(id: id, metadata: metadata(from: dict)))
                    }
                }
            } else if let dict = value as? [String: Any], let id = idFrom(dict) {
                out.append(ModelEntry(id: id, metadata: metadata(from: dict)))
            }
        }

        var entries: [ModelEntry] = []
        if let dict = object as? [String: Any] {
            for key in ["data", "models", "modelList", "items", "result"] {
                if let value = dict[key] {
                    collect(value, into: &entries)
                    if !entries.isEmpty { break }
                }
            }
            if entries.isEmpty {
                for (key, value) in dict {
                    guard let nested = value as? [String: Any], !nested.isEmpty else { continue }
                    entries.append(ModelEntry(id: ModelIdentifier.canonical(key), metadata: metadata(from: nested)))
                }
            }
        } else if object is [Any] {
            collect(object, into: &entries)
        }

        // 归一化 id 后去重，保留首条（与 parseModels 同口径）
        var seen = Set<String>()
        return entries.filter { !$0.id.isEmpty && seen.insert($0.id).inserted }
    }

    /// 从模型字典里抽出 id（沿用 `parseModels` 的键优先级，保证两者口径一致）
    private static func idFrom(_ dict: [String: Any]) -> String? {
        for key in ["id", "name", "model", "slug"] {
            if let value = dict[key] as? String, !value.isEmpty, value != "list" {
                return ModelIdentifier.canonical(value)
            }
        }
        return nil
    }

    /// 解析协议附带的元数据；**只认协议真实提供的字段**，绝不推断时间
    ///
    /// - OpenAI：`created`（Unix 秒，另有部分兼容网关给毫秒）→ 发布时间；`shutdown_date` → 下线公告
    /// - Gemini：`version`（如 `001`）→ **版本标签，不是时间**
    /// - DeepSeek / Ollama：两者都不给 → 返回 nil，界面据此显示「该协议不提供」
    private static func metadata(from dict: [String: Any]) -> ModelMetadata? {
        var meta = ModelMetadata()
        if let v = string(dict, keys: ["version"]) {
            meta.versionTag = v
        }
        if let n = number(dict, keys: ["created", "created_at", "createdAt"]) {
            // 启发式区分秒与毫秒：秒级时间戳到 2026 年约为 1.7e9
            let seconds = n > 100_000_000_000 ? n / 1000 : n
            meta.publishedAt = Date(timeIntervalSince1970: seconds)
            meta.publishedSource = "协议 · created"
        } else if let s = string(dict, keys: ["created", "created_at", "createdAt", "published_at"]),
                  let d = parseISO8601(s) {
            meta.publishedAt = d
            meta.publishedSource = "协议 · created"
        }
        if let v = string(dict, keys: ["shutdown_date", "shutdownDate", "下线时间", "下线日期"]) {
            meta.shutdownDate = v
        }
        return meta.isEmpty ? nil : meta
    }

    /// 从字典里取第一个非空字符串（缺键返回 nil）
    private static func string(_ dict: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = dict[key] as? String, !value.isEmpty { return value }
        }
        return nil
    }

    private static func number(_ dict: [String: Any], keys: [String]) -> Double? {
        for key in keys {
            if let n = dict[key] as? NSNumber { return n.doubleValue }
        }
        return nil
    }

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static func parseISO8601(_ raw: String) -> Date? {
        isoFormatter.date(from: raw)
            ?? ISO8601DateFormatter().date(from: raw)
            ?? {
                let f = DateFormatter()
                f.dateFormat = "yyyy-MM-dd"
                f.timeZone = TimeZone(identifier: "UTC")
                return f.date(from: raw)
            }()
    }

    // MARK: 额度解析与请求（仅 DeepSeek 协议可取，REQ-024 / REQ-026）

    /// 解析 DeepSeek `GET /user/balance` 响应
    ///
    /// 官方 Schema：`{ "is_available": bool, "balance_infos": [ { currency, total_balance, granted_balance, topped_up_balance } ] }`
    /// 金额一律按**字符串原样**保留；同时也兼容扁平结构（部分中转网关会简化）。
    public static func parseBalance(body: Data, endpoint: String, httpStatus: Int) -> BalanceInfo? {
        guard let dict = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else { return nil }

        var entries: [BalanceEntry] = []
        if let infos = dict["balance_infos"] as? [[String: Any]] {
            for info in infos {
                entries.append(BalanceEntry(
                    currency: stringValue(info["currency"]) ?? "—",
                    total: stringValue(info["total_balance"]) ?? "",
                    granted: stringValue(info["granted_balance"]) ?? "",
                    toppedUp: stringValue(info["topped_up_balance"]) ?? ""
                ))
            }
        } else if dict["total_balance"] != nil || dict["currency"] != nil {
            entries.append(BalanceEntry(
                currency: stringValue(dict["currency"]) ?? "—",
                total: stringValue(dict["total_balance"]) ?? "",
                granted: stringValue(dict["granted_balance"]) ?? "",
                toppedUp: stringValue(dict["topped_up_balance"]) ?? ""
            ))
        }

        let available = (dict["is_available"] as? NSNumber)?.boolValue
        guard available != nil || !entries.isEmpty else { return nil }

        return BalanceInfo(
            isAvailable: available,
            entries: entries,
            endpoint: endpoint,
            httpStatus: httpStatus,
            note: available == false ? "账号余额不足或不满足最低调用条件" : "取自余额接口",
            supported: true,
            fetchedAt: Date()
        )
    }

    private static func stringValue(_ raw: Any?) -> String? {
        if let s = raw as? String, !s.isEmpty { return s }
        // 少数网关把金额返回成数字：转字符串但保留两位小数写法，避免对账看不出单位
        if let n = raw as? NSNumber { return String(format: "%.2f", n.doubleValue) }
        return nil
    }

    /// 余额端点候选：主端点探 `/user/balance`，并兼容根路径与厂商预设端点
    ///
    /// 官方路径是 `https://api.deepseek.com/user/balance`（**不带 `/v1`**），
    /// 而本工具的 BaseURL 习惯写法可能带 `/v1` 或自定义中转前缀，
    /// 因此这里与模型端点一样给多候选、逐个尝试，而不是写死一个路径。
    public static func balanceCandidates(baseURL: String?, providerBaseURL: String?, balancePath: String) -> [Candidate] {
        let custom = (baseURL ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let primary = custom.isEmpty ? (providerBaseURL ?? "").trimmingCharacters(in: .whitespacesAndNewlines) : custom
        guard !primary.isEmpty else { return [] }

        var out: [Candidate] = []
        func add(_ url: String, _ kind: String) {
            let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !out.contains(where: { $0.url == trimmed }) else { return }
            out.append(Candidate(url: trimmed, kind: kind))
        }

        add(join(primary, balancePath), "余额端点")
        // 去 `/v1` 变体：DeepSeek 官方路径不带 /v1
        let stripped = stripTrailingV1(primary)
        if stripped != primary { add(join(stripped, balancePath), "去 /v1 变体\(balancePath)") }
        if !custom.isEmpty, let providerBaseURL, !providerBaseURL.isEmpty {
            add(join(providerBaseURL, balancePath), "厂商预设余额端点")
        }
        return out
    }

    /// 构造余额请求：鉴权口径与模型探测完全一致（Bearer / x-api-key / ?key=）
    public static func balanceRequest(
        candidate: Candidate,
        provider: Provider?,
        secret: String,
        timeout: TimeInterval = discoveryRequestTimeout,
        authOverride: AuthStyle? = nil
    ) -> URLRequest? {
        request(urlString: candidate.url, provider: provider, secret: secret, timeout: timeout, authOverride: authOverride)
    }

    /// 构造 GET 请求，鉴权风格与健康探测保持一致（Bearer / x-api-key / ?key=）
    ///
    /// - Parameter authOverride: 覆盖厂商预设的鉴权风格。用于「同一家厂商、
    ///   不同协议端点」的情形——例如 Gemini 的 OpenAI 兼容端点必须用 Bearer，
    ///   而原生端点用 `?key=`（详见 `docs/knowledge-account-protocols.md` 第六之二节实测）。
    public static func request(
        candidate: Candidate,
        provider: Provider?,
        secret: String,
        timeout: TimeInterval = discoveryRequestTimeout,
        authOverride: AuthStyle? = nil
    ) -> URLRequest? {
        request(urlString: candidate.url, provider: provider, secret: secret, timeout: timeout, authOverride: authOverride)
    }

    private static func request(
        urlString rawURL: String,
        provider: Provider?,
        secret: String,
        timeout: TimeInterval,
        authOverride: AuthStyle? = nil
    ) -> URLRequest? {
        let authStyle = authOverride ?? provider?.authStyle ?? .bearer
        let providerBase = provider?.baseURL ?? ""
        let usesCustomEndpoint = providerBase.isEmpty || !rawURL.hasPrefix(providerBase)
        var urlString = rawURL

        if authStyle == .queryKey && !usesCustomEndpoint {
            guard var comps = URLComponents(string: urlString) else { return nil }
            var items = comps.queryItems ?? []
            items.append(URLQueryItem(name: "key", value: secret))
            comps.queryItems = items
            urlString = comps.string ?? urlString
        }

        guard let url = URL(string: urlString) else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        switch authStyle {
        case .headerKey:
            request.setValue(secret, forHTTPHeaderField: "x-api-key")
        case .queryKey:
            // 云凭证（AQ.）与自定义端点走 Bearer，与健康探测口径一致
            if usesCustomEndpoint || secret.hasPrefix("AQ.") {
                request.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
            }
        case .bearer, .bearerAPIKey:
            request.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
        }
        for (k, v) in provider?.extraHeaders ?? [:] {
            request.setValue(v, forHTTPHeaderField: k)
        }
        request.setValue("KeyInjector/1.0 (macOS)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = timeout
        return request
    }
}

// MARK: - 发现引擎

public final class ModelDiscovery {

    public init() {}

    /// 按 T1→T5 顺序取证。任何一级失败都不会抛错，只会逐级降级并在 `note` 里说明原因。
    ///
    /// - Parameters:
    ///   - secret: 该 Key 的明文（只在内存中使用，绝不落盘、绝不进日志）
    ///   - candidates: T1/T2 候选端点
    ///   - hostMapped: T4 兜底（调用方注入，通常来自 `HostModelInventory.bindings`）
    ///   - inferable: T5 推断清单（宿主里有、但本 Key 未声明的模型记录）
    public func discover(
        secret: String,
        provider: Provider?,
        candidates: [ModelEndpointProbe.Candidate],
        transport: HTTPTransport,
        hostMapped: [AvailableModel],
        inferable: [HostModelRecord] = [],
        balancePath: String? = nil,
        baseURL: String? = nil,
        balanceTimeout: TimeInterval = discoveryRequestTimeout,
        authOverride: AuthStyle? = nil,
        now: Date = Date(),
        fingerprint: String = ""
    ) async -> ModelDiscoveryResult {
        var failures: [String] = []

        // 额度段与模型段**并行独立**取证：即便模型清单没探到（或该厂商没有
        // 模型端点），只要协议提供余额接口，用户仍应看到余额（REQ-026）。
        let balance = await ModelDiscovery.probeBalance(
            secret: secret,
            provider: provider,
            balancePath: balancePath,
            baseURL: baseURL,
            transport: transport,
            timeout: balanceTimeout,
            authOverride: authOverride
        )

        // ---- T1/T2/T3：端点探测 ----
        for candidate in candidates {
            guard let request = ModelEndpointProbe.request(
                candidate: candidate,
                provider: provider,
                secret: secret,
                authOverride: authOverride
            ) else {
                failures.append("\(candidate.kind)：URL 不合法")
                continue
            }
            do {
                let (status, body) = try await transport.send(request)
                let snippet = ModelEndpointProbe.snippet(body)
                guard (200..<300).contains(status) else {
                    failures.append("\(candidate.kind) → HTTP \(status)\(snippet.isEmpty ? "" : "：\(snippet)")")
                    continue
                }
                let entries = ModelEndpointProbe.parseModelEntries(body: body)
                guard !entries.isEmpty else {
                    failures.append("\(candidate.kind) → HTTP \(status) 但响应里没有可识别的模型列表")
                    continue
                }
                // REQ-024：按协议真实提供的字段填充发布时间 / 版本 / 下线公告；
                // 该协议没有的维度保持 nil，界面据此显示「该协议不提供」，不做推断。
                let models = entries.map { entry in
                    AvailableModel(
                        modelID: entry.id,
                        source: .probe,
                        evidence: "该 Key 端点 \(candidate.url) 实测返回",
                        endpoint: candidate.url,
                        metadata: entry.metadata
                    )
                }
                let balance = await ModelDiscovery.probeBalance(
                    secret: secret,
                    provider: provider,
                    balancePath: balancePath,
                    baseURL: baseURL,
                    transport: transport,
                    timeout: balanceTimeout
                )
                return ModelDiscoveryResult(
                    probed: true,
                    endpoint: candidate.url,
                    note: "端点探测成功（\(candidate.kind)，HTTP \(status)，\(models.count) 个模型）",
                    httpStatus: status,
                    models: models,
                    balance: balance,
                    fetchedAt: now,
                    fingerprint: fingerprint
                )
            } catch {
                failures.append("\(candidate.kind) → 网络失败：\(error.localizedDescription)")
            }
        }

        // ---- T4：宿主配置映射兜底 ----
        var models = hostMapped
        // ---- T5：名称推断兜底（只补 T4 未覆盖的模型，置信度标「推断」） ----
        //
        // 取舍说明：T5 的价值是「宿主菜单里明明有、但这把 Key 没被声明绑定」的模型
        // 仍能被用户看见，代价是可能猜错。因此统一标注「推断 / 候选」，
        // 绝不在界面上与实测结果混为一谈（NOT-010）。
        if !inferable.isEmpty {
            let known = Set(models.map { ModelIdentifier.comparisonKey($0.modelID) })
            let providerID = (provider?.id ?? "").lowercased()
            let providerName = provider?.name ?? ""
            let keyDomain = HostModelInventory.domain(of: provider?.baseURL ?? "")
            for record in inferable where !known.contains(ModelIdentifier.comparisonKey(record.id)) {
                // 只在**有信号**时推断，避免制造噪声（NOT-010 的延伸）：
                //   ① 供应商名与该 Key 厂商相符；
                //   ② 宿主声明的端点与该 Key 的端点同域；
                //   ③ 宿主既没标凭据键名、也没标端点，且当前一条实测/声明记录都没有。
                let owner = record.owner.lowercased()
                let ownerMatchesProvider = !providerID.isEmpty
                    && (owner.contains(providerID) || (!providerName.isEmpty && record.owner.contains(providerName)))
                let domainMatches = !keyDomain.isEmpty && !record.endpoint.isEmpty
                    && HostModelInventory.domain(of: record.endpoint) == keyDomain
                let undeclaredAndNothingKnown = record.credentialKey.isEmpty && record.endpoint.isEmpty && models.isEmpty
                guard ownerMatchesProvider || domainMatches || undeclaredAndNothingKnown else { continue }

                let evidence: String
                if ownerMatchesProvider {
                    evidence = "供应商（\(record.owner)）与 \(providerName) 相符，按模型名推断"
                } else if domainMatches {
                    evidence = "端点同域（\(HostModelInventory.domain(of: record.endpoint))），按模型名推断"
                } else {
                    evidence = "宿主既未声明凭据键名也未声明端点，按模型名推断"
                }
                models.append(AvailableModel(
                    modelID: record.id,
                    displayName: record.displayName,
                    source: .inferred,
                    evidence: evidence,
                    host: record.host,
                    owner: record.owner,
                    inMenu: record.inMenu,
                    credentialKey: record.credentialKey,
                    endpoint: record.endpoint
                ))
            }
        }

        let attempted = candidates.first?.url ?? ""
        let reason = failures.isEmpty
            ? "未配置可探测端点（该厂商预设无 baseURL/healthPath，且这把 Key 未填写自定义端点）"
            : failures.joined(separator: "；")
        let note: String
        if models.isEmpty {
            note = "探测失败且无宿主映射：\(reason)"
        } else {
            note = "端点探测未成功，已降级为\(models.first?.source.label ?? "宿主映射")：\(reason)"
        }
        return ModelDiscoveryResult(
            probed: false,
            endpoint: attempted,
            note: note,
            httpStatus: 0,
            models: models,
            balance: balance,
            fetchedAt: now,
            fingerprint: fingerprint
        )
    }

    /// 额度段取证（REQ-024 / REQ-026）：**独立于模型段**，失败不影响模型清单
    ///
    /// 设计要点：
    /// 1. 只有协议真的提供余额接口（当前仅 DeepSeek）才发起请求，其余厂商直接
    ///    返回 `supported = false` 的如实标注，而不是发一个必然 404 的请求；
    /// 2. 额度失败**不**写进 `failureReasons`，避免污染模型段的说明文字——
    ///    用户需要分清「模型没探到」和「额度没探到」两件事；
    /// 3. 结果里带上端点与 HTTP 状态，界面可以像模型行一样标注取证依据。
    public static func probeBalance(
        secret: String,
        provider: Provider?,
        balancePath: String?,
        baseURL: String?,
        transport: HTTPTransport,
        timeout: TimeInterval = discoveryRequestTimeout,
        authOverride: AuthStyle? = nil
    ) async -> BalanceInfo? {
        guard let balancePath, !balancePath.isEmpty else { return nil }
        let candidates = ModelEndpointProbe.balanceCandidates(
            baseURL: baseURL,
            providerBaseURL: provider?.baseURL,
            balancePath: balancePath
        )
        guard !candidates.isEmpty else {
            return BalanceInfo(note: "该厂商未配置余额端点", supported: false)
        }

        var reasons: [String] = []
        for candidate in candidates {
            guard let request = ModelEndpointProbe.balanceRequest(
                candidate: candidate,
                provider: provider,
                secret: secret,
                timeout: timeout,
                authOverride: authOverride
            ) else {
                reasons.append("\(candidate.kind)：URL 不合法")
                continue
            }
            do {
                let (status, body) = try await transport.send(request)
                guard (200..<300).contains(status) else {
                    reasons.append("\(candidate.kind) → HTTP \(status)")
                    continue
                }
                if let info = ModelEndpointProbe.parseBalance(body: body, endpoint: candidate.url, httpStatus: status) {
                    return info
                }
                reasons.append("\(candidate.kind) → HTTP \(status) 但余额响应无法识别")
            } catch {
                reasons.append("\(candidate.kind) → 网络失败：\(error.localizedDescription)")
            }
        }
        return BalanceInfo(
            entries: [],
            endpoint: candidates.first?.url ?? "",
            httpStatus: 0,
            note: reasons.isEmpty ? "余额端点全部未尝试成功" : reasons.joined(separator: "；"),
            supported: true,
            fetchedAt: Date()
        )
    }

    /// 把宿主映射的绑定数组转成统一模型条目（T4）
    public static func hostMappedModels(_ bindings: [HostModelInventory.Binding]) -> [AvailableModel] {        bindings.map { binding in
            AvailableModel(
                modelID: binding.modelID,
                displayName: binding.displayName,
                source: .hostMapped,
                evidence: binding.matchedBy,
                host: binding.host,
                owner: binding.owner,
                inMenu: binding.inMenu,
                credentialKey: binding.credentialKey,
                endpoint: binding.endpoint
            )
        }
    }
}

// MARK: - 发现结果缓存（只存掩码、指纹与模型名）

/// 发现结果落盘缓存。
///
/// 缓存键 = Key 的 id；每条记录带 `fingerprint`。指纹与当前 Key 不一致时
/// 视为过期并丢弃 —— 这样「换了明文但复用同一条记录」不会让界面显示旧模型。
/// 文件内**不含任何密钥明文**，只有模型名、来源与时间。
public final class DiscoveryCache {
    private let url: URL
    private var entries: [String: ModelDiscoveryResult] = [:]
    private var loaded = false

    public init(root: URL) {
        self.url = root.appendingPathComponent("model-cache.json")
    }

    public var path: String { url.path }

    private static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    private static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        e.dateEncodingStrategy = .iso8601
        return e
    }

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        guard let data = try? Data(contentsOf: url) else { return }
        entries = (try? Self.decoder().decode([String: ModelDiscoveryResult].self, from: data)) ?? [:]
    }

    /// 读取某 Key 的缓存结果；指纹不符或不存在时返回 nil
    public func result(for keyID: String, fingerprint: String) -> ModelDiscoveryResult? {
        loadIfNeeded()
        guard let entry = entries[keyID] else { return nil }
        guard fingerprint.isEmpty || entry.fingerprint == fingerprint else { return nil }
        return entry
    }

    /// 写入结果并落盘（落盘失败不影响主流程，只是下次读不到缓存）
    public func store(_ result: ModelDiscoveryResult, for keyID: String) {
        loadIfNeeded()
        entries[keyID] = result
        let snapshot = entries
        guard let data = try? Self.encoder().encode(snapshot) else { return }
        try? AtomicWriter.write(String(decoding: data, as: UTF8.self), to: url)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    /// 清掉某 Key 的缓存（删除密钥时调用）
    public func remove(keyID: String) {
        loadIfNeeded()
        guard entries.removeValue(forKey: keyID) != nil else { return }
        let snapshot = entries
        guard let data = try? Self.encoder().encode(snapshot) else { return }
        try? AtomicWriter.write(String(decoding: data, as: UTF8.self), to: url)
    }
}
