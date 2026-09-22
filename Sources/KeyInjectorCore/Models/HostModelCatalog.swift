// ==============================================================================
// 宿主模型清单：把「哪些模型能出现在宿主菜单里」与「哪个密钥在供给它」接上
//
// 背景（v1.4.0 之前的口径缺口）：
//   · 应用侧「模型清单」页此前只读 `~/.codex/codex-gateway-models.json`，
//     于是 DSH 桌面端顶部菜单里的模型（写在 `harness/settings.yaml` 的
//     `llm-pi-ai.providers.*.models`）在注入器里完全不可见 —— 用户会以为
//     「模型是凭空冒出来的，跟我的密钥库没关系」。
//   · 事实上两个宿主的模型都由**密钥**供给：DSH 通过 `apiKeyEnv` 指向
//     `.credentials.yaml` 的 refs 键名，Codex 通过 `codex_gateway` 的 base_url
//     指向同一台中间商网关。本文件把这个供给关系显式建模，
//     让「密钥 → 宿主 → 模型」三者可被界面一次性看清。
//
// 设计边界（反例）：
//   1) 本文件**只读**宿主的模型清单，绝不改写 `settings.yaml` ——
//      该文件里有 onboarding、权限、默认模型等大量非本工具所有的字段，
//      任何「顺手规范化 YAML」的做法都会破坏用户的既有配置。
//   2) YAML 解析刻意保持缩进敏感的保守实现：只认 `键: 值` 与 `- id:` 两种行，
//      无法识别的行原样跳过而不是猜测。deepseek 供应商的名称/URL 等字段
//      允许缺失（此时凭据绑定退化为「未绑定」，界面如实标注而不是编造）。
// ==============================================================================
import Foundation

// MARK: - 宿主枚举

/// 一个可被注入的宿主（桌面端）对模型清单的所有权标识
public enum HostKind: String, Codable, Sendable, CaseIterable, Hashable {
    case dsh
    case codex

    /// 界面与总结里使用的中文宿主名
    public var label: String {
        switch self {
        case .dsh: return "DSH 桌面端"
        case .codex: return "Codex 桌面端"
        }
    }

    /// 该宿主的模型清单数据源路径（未展开 `~`）
    public var catalogPathHint: String {
        switch self {
        case .dsh: return DshModelCatalog.settingsPathHint
        case .codex: return "~/.codex/codex-gateway-models.json"
        }
    }
}

// MARK: - 统一模型条目（跨宿主）

/// 一条「宿主菜单里的模型」记录，已归一到跨宿主可比的口径。
public struct HostModelRecord: Sendable {
    /// 宿主侧真实模型名（DSH 即 `models[].id`，Codex 即 `slug`）
    public var id: String
    /// 归一化模型身份：跨宿主同一模型（如 DSH 的 `DS/DeepSeek V4.1 Flash`
    /// 与 Codex 的 `ark/DeepSeek-V4.1-Flash`）归一到同一个 key
    public var normalizedID: String
    /// 宿主显示的模型名（Codex 的 `display_name`；DSH 无独立显示名时等于 id）
    public var displayName: String
    public var host: HostKind
    /// 该模型所属宿主内的配置主体（DSH 供应商 id / Codex provider 名）
    public var owner: String
    /// 宿主声明的凭据键名（DSH 的 `apiKeyEnv`，如 `MIDPRO_API_KEY`）；空表示宿主未声明
    public var credentialKey: String
    /// 宿主声明的上游端点（DSH 的 `baseURL` / Codex 的 `model_providers.*.base_url`）
    public var endpoint: String
    /// 附加说明（Codex 用目录里的 description；DSH 留空）
    public var note: String
    /// 是否出现在宿主菜单里（Codex `visibility == "list"`；DSH 声明即出现）
    public var inMenu: Bool
    /// 是否为中间商/公司网关模型
    public var isGateway: Bool
    /// 数据源文件路径（已展开）
    public var sourcePath: String

    public init(
        id: String,
        displayName: String = "",
        host: HostKind,
        owner: String = "",
        credentialKey: String = "",
        endpoint: String = "",
        note: String = "",
        inMenu: Bool = true,
        isGateway: Bool = true,
        sourcePath: String = "",
        normalizedID: String? = nil
    ) {
        self.id = id
        self.normalizedID = normalizedID ?? ModelIdentity.normalize(id)
        self.displayName = displayName.isEmpty ? id : displayName
        self.host = host
        self.owner = owner
        self.credentialKey = credentialKey
        self.endpoint = endpoint
        self.note = note
        self.inMenu = inMenu
        self.isGateway = isGateway
        self.sourcePath = sourcePath
    }

    /// 界面标签：宿主 + 所属配置主体
    public var hostLabel: String {
        owner.isEmpty ? host.label : "\(host.label) · \(owner)"
    }
}

// MARK: - 模型身份归一

/// 跨宿主的模型身份归一。
///
/// 现状痛点：DSH 侧写 `DS/DeepSeek V4.1 Flash`，Codex 侧写
/// `ark/DeepSeek-V4.1-Flash`，字面量不同却是同一个上游模型。
/// 归一化后两者得到同一个 `normalizedID`，界面才能把它们识别为同一供给关系。
public enum ModelIdentity {
    /// 归一去重时需要剥掉的命名空间前缀（厂商/网关命名空间，而非模型身份）
    public static let namespacePrefixes = ["ark/", "ds/", "openai/", "google/", "anthropic/"]

    /// 归一化：去掉命名空间前缀与所有非字母数字字符，统一小写
    public static func normalize(_ id: String) -> String {
        var s = id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var changed = true
        while changed {
            changed = false
            for prefix in namespacePrefixes where s.hasPrefix(prefix) {
                s = String(s.dropFirst(prefix.count))
                changed = true
            }
        }
        return String(s.filter { $0.isLetter || $0.isNumber })
    }
}

// MARK: - DSH 宿主模型清单

/// DSH 桌面端模型清单读取器（`harness/settings.yaml` 的 `llm-pi-ai` 段）
public enum DshModelCatalog {

    /// 供应商默认设置文件路径（未展开 `~`）
    public static let settingsPathHint = "~/Library/Application Support/com.yeagoo.dsh-desktop/harness/settings.yaml"

    /// 供应商凭据文件路径（未展开 `~`）；`apiKeyEnv` 指向其中 refs 区块的键名
    public static let credentialsPathHint = "~/Library/Application Support/com.yeagoo.dsh-desktop/harness/.credentials.yaml"

    public static var defaultSettingsPath: String { PathKit.expand(settingsPathHint) }
    public static var defaultCredentialsPath: String { PathKit.expand(credentialsPathHint) }

    /// 一个 DSH 宿主供应商（`llm-pi-ai.providers.<id>`）
    public struct Provider: Sendable {
        public var id: String
        public var displayName: String
        /// 真实解析策略名，如 `openai-completions`
        public var api: String
        public var baseURL: String
        /// 凭据**引用**（环境变量名形态），指向 `.credentials.yaml` 的 refs 键名
        public var apiKeyEnv: String
        /// 该供应商声明的模型 id 列表（声明即出现在宿主模型菜单里）
        public var modelIDs: [String]
        /// 供应商级开关；`false` 时宿主不加载它，清单里如实标注但不计入供给
        public var enabled: Bool
    }

    /// 读取并解析宿主供应商清单；文件缺失或不可读时返回空数组
    public static func providers(path: String = defaultSettingsPath) -> [Provider] {
        guard let text = try? String(contentsOfFile: PathKit.expand(path), encoding: .utf8) else { return [] }
        return parseProviders(text)
    }

    /// 构造统一模型记录（宿主 = DSH）
    public static func records(path: String = defaultSettingsPath) -> [HostModelRecord] {
        let expanded = PathKit.expand(path)
        return providers(path: expanded).flatMap { provider in
            provider.modelIDs.map { modelID in
                HostModelRecord(
                    id: modelID,
                    host: .dsh,
                    owner: provider.displayName.isEmpty ? provider.id : provider.displayName,
                    credentialKey: provider.apiKeyEnv,
                    endpoint: provider.baseURL,
                    note: provider.enabled ? "" : "该供应商在 DSH 设置中已停用（enabled: false）",
                    inMenu: provider.enabled,
                    isGateway: true,
                    sourcePath: expanded
                )
            }
        }
    }

    // MARK: 解析

    /// 两空格一级缩进解析 `llm-pi-ai.providers.<id>` 区块。
    ///
    /// 只识别两类行：`键: 值` 与 `- id: 值`。无法识别的行直接跳过（保守优先），
    /// 且**不**尝试处理多行字符串 / 锚点 / 流式集合 —— 本项目对 settings.yaml 只读，
    /// 遇到不支持的写法时宁可少列也不要猜错。
    public static func parseProviders(_ text: String) -> [Provider] {
        var result: [Provider] = []
        var inRoot = false
        var inProviders = false
        var current: Provider?
        var rootIndent = 0
        var providersIndent = 0
        var providerIndent = 0
        var inModels = false
        var modelsIndent = 0
        var modelsIsOverride = false

        func indent(of line: String) -> Int { line.prefix { $0 == " " }.count }
        func scalar(_ raw: String) -> String {
            var s = raw.trimmingCharacters(in: .whitespaces)
            if s.hasPrefix("\""), s.hasSuffix("\""), s.count >= 2 {
                s = String(s.dropFirst().dropLast())
            } else if s.hasPrefix("'"), s.hasSuffix("'"), s.count >= 2 {
                s = String(s.dropFirst().dropLast())
            }
            return s.trimmingCharacters(in: .whitespaces)
        }
        func flush() {
            if let provider = current { result.append(provider) }
            current = nil
        }

        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            let level = indent(of: line)

            if !inRoot {
                guard trimmed.hasPrefix("llm-pi-ai:"), !trimmed.hasPrefix("-") else { continue }
                inRoot = true
                rootIndent = level
                continue
            }
            if level <= rootIndent {
                flush()
                inRoot = false
                inProviders = false
                inModels = false
                continue
            }
            if !inProviders {
                guard trimmed.hasPrefix("providers:"), !trimmed.hasPrefix("-") else { continue }
                inProviders = true
                providersIndent = level
                continue
            }
            if level <= providersIndent {
                flush()
                inProviders = false
                inModels = false
                continue
            }

            // 供应商键：`  midpro:` —— 恰好比 providers 深一级且不是列表项
            if level == providersIndent + 2, !trimmed.hasPrefix("-"), trimmed.hasSuffix(":") {
                flush()
                current = Provider(
                    id: String(trimmed.dropLast()).trimmingCharacters(in: .whitespaces),
                    displayName: "",
                    api: "",
                    baseURL: "",
                    apiKeyEnv: "",
                    modelIDs: [],
                    enabled: true
                )
                providerIndent = level
                inModels = false
                continue
            }
            guard current != nil else { continue }

            // `- id: xxx`（模型条目）；只在 models 列表作用域内才生效
            if inModels, level >= modelsIndent, trimmed.hasPrefix("- ") {
                let body = String(trimmed.dropFirst(2))
                if body.hasPrefix("id:") {
                    let value = scalar(String(body.dropFirst(3)))
                    if !value.isEmpty { current?.modelIDs.append(value) }
                }
                continue
            }

            // 网关路由表写法：`models:` 直接是 `线路名: 上游模型名` 的映射。
            // 真实例子（DSH settings.yaml）：
            //     models:
            //       deepseek: ark/DeepSeek-V4.1-Flash
            //       gemini: gemini-3.8-flash-high
            // 上游模型名才是客户端要填的 slug，线路名（deepseek/gemini）只是网关内部别名，
            // 因此这里只取冒号右侧的值，避免把内部别名当成模型名污染清单。
            if inModels, !modelsIsOverride, level > modelsIndent, !trimmed.hasPrefix("-") {
                if let colon = trimmed.firstIndex(of: ":") {
                    let value = scalar(String(trimmed[trimmed.index(after: colon)...]))
                    if !value.isEmpty, !value.contains(":") { current?.modelIDs.append(value) }
                }
                continue
            }

            // 供应商级字段
            guard level == providerIndent + 2 else { continue }
            if trimmed.hasPrefix("models:") || trimmed.hasPrefix("modelOverrides:") {
                inModels = true
                modelsIsOverride = trimmed.hasPrefix("modelOverrides:")
                modelsIndent = level
                continue
            }
            inModels = false
            modelsIsOverride = false
            guard let colon = trimmed.firstIndex(of: ":") else { continue }
            let key = String(trimmed[trimmed.startIndex..<colon]).trimmingCharacters(in: .whitespaces)
            let value = scalar(String(trimmed[trimmed.index(after: colon)...]))
            switch key {
            case "displayName": current?.displayName = value
            case "api": current?.api = value
            case "baseURL", "baseUrl", "base_url": current?.baseURL = value
            case "apiKeyEnv": current?.apiKeyEnv = value
            case "enabled": current?.enabled = !(value == "false" || value == "no" || value == "0")
            default: break
            }
        }
        flush()
        return result
    }

    // MARK: 凭据占用情况

    /// 读取 `.credentials.yaml` 的 `refs` 区块，返回键名 → 已配置与否。
    ///
    /// 只读键名与「是否有值」，**永不读取或回传明文**：
    /// 这是判断「宿主声明的 apiKeyEnv 到底有没有被注入过」的唯一依据。
    public static func credentialStatus(path: String = defaultCredentialsPath) -> [String: Bool] {
        guard let text = try? String(contentsOfFile: PathKit.expand(path), encoding: .utf8) else { return [:] }
        return parseCredentialRefs(text)
    }

    /// 解析 refs 区块：`  KEY: value`。空值视为「未配置」。
    public static func parseCredentialRefs(_ text: String) -> [String: Bool] {
        var result: [String: Bool] = [:]
        var inRefs = false
        var refsIndent = 0
        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            let level = line.prefix { $0 == " " }.count
            if !inRefs {
                guard trimmed.hasPrefix("refs:"), !trimmed.hasPrefix("-") else { continue }
                inRefs = true
                refsIndent = level
                continue
            }
            if level <= refsIndent { break }
            guard let colon = trimmed.firstIndex(of: ":") else { continue }
            let key = String(trimmed[trimmed.startIndex..<colon]).trimmingCharacters(in: .whitespaces)
            var value = String(trimmed[trimmed.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 { value = String(value.dropFirst().dropLast()) }
            result[key] = !value.isEmpty
        }
        return result
    }
}

// MARK: - 跨宿主模型清单与凭据绑定

/// 跨宿主模型清单 + 「密钥 → 模型」供给关系。
///
/// 这是需求「应该从注入器的密钥库中就能获取模型清单」的落点：
/// 模型清单不再是宿主配置的孤岛副本，而是与密钥库里的记录显式挂钩。
public enum HostModelInventory {

    /// 一次 Codex 清单读取的全部派生信息
    public struct CodexSnapshot: Sendable {
        public var gatewayRecords: [HostModelRecord]
        public var officialCount: Int
        public var endpoint: String
        public var configPath: String
        public var catalogPath: String
        /// config.toml 当前写着的 model / model_provider
        public var configModel: String
        public var configProvider: String
        public var routingHealthy: Bool
    }

    /// 读取 Codex 模型目录（只取网关条目，官方条目仅计数）
    public static func codexSnapshot(
        catalogPath: String = CodexCatalogStore.defaultPath,
        configPath: String? = nil
    ) -> CodexSnapshot {
        let catalog = PathKit.expand(catalogPath)
        let config = KeyInjectorService.defaultCodexConfigPath(explicit: configPath)
        let configText = (try? String(contentsOfFile: config, encoding: .utf8)) ?? ""
        let endpoint = codexGatewayBaseURL(in: configText)
        let entries = CodexCatalogStore.load(path: catalog)
        let gateway = entries.filter { $0.isGateway }
        let records = gateway.map { entry in
            HostModelRecord(
                id: entry.slug,
                displayName: entry.displayName,
                host: .codex,
                owner: "codex_gateway",
                credentialKey: "",
                endpoint: endpoint,
                note: entry.description,
                inMenu: entry.inPicker,
                isGateway: true,
                sourcePath: catalog
            )
        }
        return CodexSnapshot(
            gatewayRecords: records,
            officialCount: entries.count - gateway.count,
            endpoint: endpoint,
            configPath: config,
            catalogPath: catalog,
            configModel: InjectionEngine.firstModelSlug(in: configText) ?? "",
            configProvider: InjectionEngine.firstAssignmentValue("model_provider", in: configText) ?? "",
            routingHealthy: InjectionEngine.codexGatewayRoutingOK(configText, catalogPath: catalog)
        )
    }

    /// 从 `config.toml` 中取出 `[model_providers.codex_gateway]` 的 `base_url`。
    /// 用于把 Codex 侧的网关模型挂到「baseURL 指向同一台网关」的密钥上。
    public static func codexGatewayBaseURL(in configText: String, providerName: String = "codex_gateway") -> String {
        var inSection = false
        let header = "[model_providers.\(providerName)]"
        for line in configText.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") {
                inSection = trimmed == header
                continue
            }
            guard inSection else { continue }
            guard let range = trimmed.range(of: "base_url") else { continue }
            let rest = trimmed[range.upperBound...]
            guard let eq = rest.firstIndex(of: "=") else { continue }
            var value = String(rest[rest.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 { value = String(value.dropFirst().dropLast()) }
            if !value.isEmpty { return value }
        }
        return ""
    }

    /// 全部宿主的模型记录（DSH + Codex 网关条目）
    public static func all(
        dshSettingsPath: String = DshModelCatalog.defaultSettingsPath,
        codexCatalogPath: String = CodexCatalogStore.defaultPath,
        codexConfigPath: String? = nil
    ) -> [HostModelRecord] {
        DshModelCatalog.records(path: dshSettingsPath) + codexSnapshot(catalogPath: codexCatalogPath, configPath: codexConfigPath).gatewayRecords
    }

    /// 按归一化身份把同一模型在两个宿主侧的多条记录聚合起来
    public struct Group: Sendable {
        public var normalizedID: String
        public var records: [HostModelRecord]

        /// 展示名：优先带网关后缀的 Codex 显示名，其次 DSH 侧 id
        public var displayName: String {
            records.first(where: { $0.host == .codex })?.displayName ?? records.first?.displayName ?? normalizedID
        }
        /// 涉及到的宿主列表（去重）
        public var hosts: [HostKind] {
            HostKind.allCases.filter { kind in records.contains { $0.host == kind } }
        }
        /// 该模型在各宿主侧的别名
        public var aliases: [String] {
            var seen = Set<String>()
            return records.compactMap { record in
                seen.insert(record.id).inserted ? record.id : nil
            }
        }
        public var isGateway: Bool { records.contains { $0.isGateway } }
    }

    /// 聚合视图：同一模型跨宿主的别名归到一组
    public static func groups(_ records: [HostModelRecord]) -> [Group] {
        var order: [String] = []
        var map: [String: [HostModelRecord]] = [:]
        for record in records {
            if map[record.normalizedID] == nil {
                order.append(record.normalizedID)
                map[record.normalizedID] = []
            }
            map[record.normalizedID]?.append(record)
        }
        return order.compactMap { key in
            guard let items = map[key] else { return nil }
            return Group(normalizedID: key, records: items)
        }
    }

    /// 一条「密钥供给某模型」的绑定
    public struct Binding: Sendable, Hashable {
        /// 命中的模型记录 id（宿主侧真实模型名）
        public var modelID: String
        public var displayName: String
        public var host: HostKind
        public var owner: String
        public var inMenu: Bool
        public var credentialKey: String
        public var endpoint: String
        /// 绑定依据，供界面如实说明「为什么认为这个模型由该密钥供给」
        public var matchedBy: String

        public init(
            modelID: String,
            displayName: String,
            host: HostKind,
            owner: String,
            inMenu: Bool,
            credentialKey: String,
            endpoint: String,
            matchedBy: String
        ) {
            self.modelID = modelID
            self.displayName = displayName
            self.host = host
            self.owner = owner
            self.inMenu = inMenu
            self.credentialKey = credentialKey
            self.endpoint = endpoint
            self.matchedBy = matchedBy
        }
    }

    /// 计算某密钥供给的全部模型。
    ///
    /// 匹配规则（三条依据，命中其一即绑定）：
    ///   ① 凭据键名 + 端点一致：宿主声明的 `apiKeyEnv`（或落点键名）命中该密钥的
    ///      厂商环境变量名，**并且**端点同源或宿主类型与该 Key 厂商一致；
    ///   ② 端点地址：宿主的 baseURL 与该密钥自定义 Base URL 同源；
    ///   ③ 显式厂商：宿主声明的 `apiKeyEnv` 就是该厂商的官方环境变量名
    ///      （例如 DSH 里直连 `api.deepseek.com` 的 deepseek 供应商 ↔ DeepSeek Key）。
    ///
    /// 反例边界（实测踩坑，务必知悉）：
    ///   · 两条依据都不命中时不做任何猜测，界面显示「未绑定」而不是把模型硬塞给某个密钥；
    ///   · **禁止仅凭「落点键名」就把跨厂商的模型算到这把 Key 头上**。
    ///     实测曾把 Gemini Key 判成「供给公司网关 5 个模型」——原因是 DSH 落点的
    ///     `MIDPRO_API_KEY` 键名与网关供应商的 apiKeyEnv 同名，而该 Key 的端点
    ///     （generativelanguage.googleapis.com）与网关端点毫无关系。
    ///     这类误绑会让用户以为「换这把 Key 也能用这些模型」，是静默误导。
    public static func bindings(
        for record: KeyRecord,
        provider: Provider?,
        targets: [InjectionTarget],
        records: [HostModelRecord],
        excludeTargetID: String? = nil
    ) -> [Binding] {
        var credentialNames = Set<String>()
        var targetCredentialNames = Set<String>()
        if let provider {
            provider.envKeys.forEach { credentialNames.insert($0.uppercased()) }
        }
        for target in targets where target.id != excludeTargetID {
            var names: [String] = []
            if let key = target.itemKey, !key.isEmpty { names.append(key) }
            if let last = target.jsonPath.last, !last.isEmpty { names.append(last) }
            for name in names {
                credentialNames.insert(name.uppercased())
                targetCredentialNames.insert(name.uppercased())
            }
        }

        let keyEndpoint = (record.baseURL ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let officialEnvNames = Set((provider?.envKeys ?? []).map { $0.uppercased() })

        var out: [Binding] = []
        for model in records {
            var matchedBy: String?
            let declared = model.credentialKey.uppercased()
            if !declared.isEmpty, credentialNames.contains(declared) {
                let endpointMatches = !model.endpoint.isEmpty && !keyEndpoint.isEmpty
                    && sameEndpoint(keyEndpoint, model.endpoint)
                // 该模型是「直连本 Key 厂商官方端点」才允许仅凭凭据名绑定
                let officialMatch = officialEnvNames.contains(declared)
                    && !model.endpoint.isEmpty && endpointBelongsToProvider(model.endpoint, provider: provider)

                if endpointMatches {
                    matchedBy = declared == "" ? "端点 \(model.endpoint)" : "凭据键名 \(declared) 且端点同源"
                } else if officialMatch {
                    matchedBy = "凭据键名 \(declared)（厂商官方端点）"
                } else if !targetCredentialNames.contains(declared) {
                    // 凭据名来自该 Key 自己的厂商环境变量名，而非某个落点的注入键名：
                    // 这类命中即使端点不同源也保留（例如同一个 Key 换成中转地址）。
                    matchedBy = "凭据键名 \(declared)"
                }
                // 落点键名命中 + 端点不同源 + 非官方端点 → 不绑定（跨厂商误绑保护）
            } else if !model.endpoint.isEmpty, !keyEndpoint.isEmpty, sameEndpoint(keyEndpoint, model.endpoint) {
                matchedBy = "端点 \(model.endpoint)"
            }
            guard let reason = matchedBy else { continue }
            out.append(Binding(
                modelID: model.id,
                displayName: model.displayName,
                host: model.host,
                owner: model.owner,
                inMenu: model.inMenu,
                credentialKey: model.credentialKey,
                endpoint: model.endpoint,
                matchedBy: reason
            ))
        }
        return out
    }

    /// 判断某个端点是否属于该厂商（用于「仅凭凭据键名」这一条依据的安全护栏）
    public static func endpointBelongsToProvider(_ endpoint: String, provider: Provider?) -> Bool {
        guard let provider, let base = provider.baseURL, !base.isEmpty else { return false }
        return sameEndpoint(endpoint, base) || domain(of: endpoint) == domain(of: base)
    }

    /// 取主机名（小写，忽略路径与端口差异）
    public static func domain(of endpoint: String) -> String {
        let trimmed = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let host = url.host?.lowercased() else { return "" }
        return host
    }

    /// 端点同源判断：忽略结尾斜杠、大小写与默认端口差异
    public static func sameEndpoint(_ lhs: String, _ rhs: String) -> Bool {
        func canon(_ raw: String) -> String {
            var s = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if s.hasSuffix("/") { s = String(s.dropLast()) }
            return s
        }
        let a = canon(lhs), b = canon(rhs)
        guard !a.isEmpty, !b.isEmpty else { return false }
        return a == b
    }
}
