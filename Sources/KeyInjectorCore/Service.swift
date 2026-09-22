// ==============================================================================
// 门面服务：把仓库、注入引擎、健康探测与审计日志组装成单一入口，
// 供命令行与桌面界面共用（保证两端行为完全一致）。
// ==============================================================================
import Foundation

/// Codex 网关路由体检结果
public struct GatewayRoutingStatus: Sendable {
    public var configPath: String
    public var model: String?
    public var provider: String?
    public var healthy: Bool
    public var exists: Bool

    public var summary: String {
        guard exists else { return "未找到 Codex 配置文件：\(configPath)" }
        let modelText = model ?? "(未设置)"
        let providerText = provider ?? "(未设置，将回退官方 openai provider)"
        return healthy
            ? "路由正常：model=\(modelText) → provider=\(providerText)"
            : "路由异常：model=\(modelText) 是公司网关模型，但 provider=\(providerText)，请求会被 ChatGPT 后端拒绝"
    }
}

/// Codex 网关路由修复结果
public struct GatewayRoutingRepair: Sendable {
    public var status: GatewayRoutingStatus
    public var changed: Bool
    public var dryRun: Bool
    public var backupPath: String?
    public var preview: String?

    public init(status: GatewayRoutingStatus, changed: Bool, dryRun: Bool, backupPath: String?, preview: String? = nil) {
        self.status = status
        self.changed = changed
        self.dryRun = dryRun
        self.backupPath = backupPath
        self.preview = preview
    }
}

public final class KeyInjectorService {
    public let root: URL
    public private(set) var providers: ProviderCatalog
    public private(set) var targets: TargetCatalog
    public let vault: KeyVault
    public let audit: AuditLog
    public let engine: InjectionEngine
    public let health: HealthChecker
    public let settingsStore: SettingsStore
    /// 网络传输层：健康探测与模型发现共用，便于测试注入假传输层
    public let transport: HTTPTransport
    /// 模型发现引擎与结果缓存（只存掩码、指纹与模型名）
    public let discovery: ModelDiscovery
    public let discoveryCache: DiscoveryCache
    public private(set) var settings: AppSettings
    /// 启动过程中产生的非致命提示（例如钥匙串不可用而自动降级）
    public private(set) var bootWarnings: [String] = []

    public init(
        root: URL? = nil,
        storeBackend: String? = nil,
        transport: HTTPTransport = URLSessionTransport()
    ) throws {
        let dir = root ?? PathKit.defaultSupportDirectory()
        self.root = dir
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let settingsStore = SettingsStore(root: dir)
        self.settingsStore = settingsStore
        var loaded = settingsStore.load()

        let envBackend = ProcessInfo.processInfo.environment["KEYINJECTOR_STORE"]
        let wanted = (storeBackend ?? envBackend ?? loaded.storeBackend).lowercased()
        loaded.storeBackend = wanted

        // 选择密钥明文后端：默认采用本地 AES-GCM 安全加密文件存储（避免 macOS 钥匙串弹窗阻断）
        var warnings: [String] = []
        var store: SecretStore
        switch wanted {
        case "memory":
            store = MemorySecretStore()
        case "keychain":
            #if canImport(Security)
            store = KeychainSecretStore()
            #else
            store = try FileSecretStore(root: dir)
            warnings.append("当前平台不支持钥匙串，已降级为本地加密文件后端")
            #endif
        default:
            store = try FileSecretStore(root: dir)
        }
        self.bootWarnings = warnings

        self.vault = KeyVault(root: dir, store: store)
        self.audit = AuditLog(root: dir)
        let backups = BackupStore(root: dir)
        self.engine = InjectionEngine(audit: audit, backups: backups)
        self.health = HealthChecker(transport: transport)
        self.transport = transport
        self.discovery = ModelDiscovery()
        self.discoveryCache = DiscoveryCache(root: dir)

        // 加载可覆盖的预设目录（无需重新编译即可修正第三方工具路径）
        var catProviders = ProviderCatalog()
        var catTargets = TargetCatalog()
        let overrideDir = dir.appendingPathComponent("config", isDirectory: true)
        if let data = try? Data(contentsOf: overrideDir.appendingPathComponent("providers.json")),
           let list = try? JSONDecoder().decode([Provider].self, from: data) {
            catProviders = catProviders.merged(with: list)
        }
        if let data = try? Data(contentsOf: overrideDir.appendingPathComponent("targets.json")),
           let list = try? JSONDecoder().decode([InjectionTarget].self, from: data) {
            catTargets = catTargets.merged(with: list)
        }
        catTargets = catTargets.merged(with: loaded.customTargets)
        self.providers = catProviders
        self.targets = catTargets
        self.settings = loaded
    }

    // MARK: - 目录查询

    public func provider(id: String) -> Provider? { providers.provider(id: id) }
    public func target(id: String) -> InjectionTarget? { targets.target(id: id) }

    /// 把内置预设导出为可编辑的 JSON 模板（已存在则不覆盖）
    @discardableResult
    public func exportConfigTemplates() throws -> [String] {
        let dir = root.appendingPathComponent("config", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var written: [String] = []

        let providerURL = dir.appendingPathComponent("providers.json")
        if !FileManager.default.fileExists(atPath: providerURL.path) {
            let data = try encoder.encode(ProviderCatalog.builtins)
            try AtomicWriter.write(String(decoding: data, as: UTF8.self), to: providerURL)
            written.append(providerURL.path)
        }
        let targetURL = dir.appendingPathComponent("targets.json")
        if !FileManager.default.fileExists(atPath: targetURL.path) {
            let data = try encoder.encode(TargetCatalog.builtins)
            try AtomicWriter.write(String(decoding: data, as: UTF8.self), to: targetURL)
            written.append(targetURL.path)
        }
        return written
    }

    // MARK: - 密钥管理

    public func listKeys() throws -> [KeyRecord] {
        try vault.load().keys.sorted { ($0.priority, $0.createdAt) < ($1.priority, $1.createdAt) }
    }

    public func secret(for id: String) throws -> String {
        try vault.secret(id: id)
    }

    public func addKey(providerID: String, label: String, secret: String, priority: Int = 100, tags: [String] = [], note: String = "", baseURL: String? = nil) throws -> KeyRecord {
        guard providers.provider(id: providerID) != nil else {
            throw ServiceError.unknownProvider(providerID)
        }
        let record = try vault.add(providerID: providerID, label: label, secret: secret, priority: priority, tags: tags, note: note, baseURL: baseURL)
        try? audit.append(AuditEntry(
            action: .createKey,
            result: "success",
            message: "新增 \(providers.name(of: providerID)) 密钥「\(record.label)」（掩码 \(record.hint)）",
            keyID: record.id,
            providerID: providerID,
            fingerprint: record.fingerprint
        ))
        return record
    }

    public func updateKey(
        id: String,
        label: String? = nil,
        secret: String? = nil,
        priority: Int? = nil,
        tags: [String]? = nil,
        note: String? = nil,
        baseURL: String? = nil
    ) throws -> KeyRecord {
        let record = try vault.update(id: id, label: label, secret: secret, priority: priority, tags: tags, note: note, baseURL: baseURL)
        try? audit.append(AuditEntry(
            action: .updateKey,
            result: "success",
            message: "更新密钥「\(record.label)」（掩码 \(record.hint)）",
            keyID: record.id,
            providerID: record.providerID,
            fingerprint: record.fingerprint
        ))
        return record
    }

    public func updateSecret(id: String, secret: String) throws -> KeyRecord {
        let record = try vault.updateSecret(id: id, secret: secret)
        try? audit.append(AuditEntry(
            action: .updateKey,
            result: "success",
            message: "更新密钥「\(record.label)」的明文内容（新掩码 \(record.hint)）",
            keyID: record.id,
            providerID: record.providerID,
            fingerprint: record.fingerprint
        ))
        return record
    }

    public func removeKey(id: String) throws -> KeyRecord {
        let record = try vault.remove(id: id)
        // 一并丢掉该 Key 的发现缓存，避免删除后残留模型清单
        discoveryCache.remove(keyID: id)
        try? audit.append(AuditEntry(
            action: .deleteKey,
            result: "success",
            message: "删除密钥「\(record.label)」及其钥匙串明文",
            keyID: record.id,
            providerID: record.providerID,
            fingerprint: record.fingerprint
        ))
        return record
    }

    public func setEnabled(id: String, enabled: Bool) throws -> KeyRecord {
        let record = try vault.setEnabled(id: id, enabled: enabled)
        try? audit.append(AuditEntry(
            action: enabled ? .enableKey : .disableKey,
            result: "success",
            message: (enabled ? "启用" : "禁用") + "密钥「\(record.label)」",
            keyID: record.id,
            providerID: record.providerID,
            fingerprint: record.fingerprint
        ))
        return record
    }

    public func setPriority(id: String, priority: Int) throws -> KeyRecord {
        try vault.setPriority(id: id, priority: priority)
    }

    public func preferredKey(providerID: String) throws -> KeyRecord? {
        try vault.preferredKey(providerID: providerID)
    }

    // MARK: - 宿主模型清单与「密钥 → 模型」供给关系

    /// 全部宿主的模型记录（DSH 设置文件 + Codex 网关目录）
    ///
    /// 这是需求「从密钥库就能获取模型清单」的统一入口：两个宿主的模型
    /// 在这里被读成同一形状，再由 `modelBindings(for:)` 挂到具体密钥上。
    /// 路径可覆盖是为了让测试能在临时目录里造一套宿主配置，而不依赖本机 `~/.codex`。
    public func hostModelRecords(
        dshSettingsPath: String = DshModelCatalog.defaultSettingsPath,
        codexCatalogPath: String = CodexCatalogStore.defaultPath,
        codexConfigPath: String? = nil
    ) -> [HostModelRecord] {
        HostModelInventory.all(
            dshSettingsPath: dshSettingsPath,
            codexCatalogPath: codexCatalogPath,
            codexConfigPath: codexConfigPath
        )
    }

    /// 按归一化身份聚合后的模型分组（跨宿主同一模型合并为一条）
    public func hostModelGroups() -> [HostModelInventory.Group] {
        HostModelInventory.groups(hostModelRecords())
    }

    /// DSH 宿主供应商清单（含凭据引用名，不含任何明文）
    public func dshProviders() -> [DshModelCatalog.Provider] {
        DshModelCatalog.providers()
    }

    /// DSH 凭据文件的键名占用情况（键名 → 是否已配置）
    public func dshCredentialStatus() -> [String: Bool] {
        DshModelCatalog.credentialStatus()
    }

    /// 计算某密钥供给的模型清单
    public func modelBindings(for record: KeyRecord) -> [HostModelInventory.Binding] {
        HostModelInventory.bindings(
            for: record,
            provider: providers.provider(id: record.providerID),
            targets: targets.targets,
            records: hostModelRecords()
        )
    }

    /// 带模型供给关系的密钥列表（供界面在密钥卡内直接展示「这个 Key 供给了哪些模型」）
    public func listKeysWithModels() throws -> [KeyRecord] {
        let records = hostModelRecords()
        return try listKeys().map { record in
            var copy = record
            copy.modelBindings = HostModelInventory.bindings(
                for: record,
                provider: providers.provider(id: record.providerID),
                targets: targets.targets,
                records: records
            )
            return copy
        }
    }

    // MARK: - 密钥库分区（需求：按 key 别名分区）

    /// 一个「名字分区」：标题就是 key 别名，一把 key 一个分区
    public struct KeyGroup: Sendable {
        /// 分区标题（key 别名）
        public var label: String
        /// 分区内包含的 key（同名 key 不会合并到同一分区，仍各自成区）
        public var records: [KeyRecord]
        /// 该分区的模型并集数量（去重后）
        public var modelCount: Int

        public init(label: String, records: [KeyRecord], modelCount: Int) {
            self.label = label
            self.records = records
            self.modelCount = modelCount
        }
    }

    /// 按 key 别名分区（一把 key 一个分区）。
    ///
    /// 排序规则：**已启用优先 → 优先级升序 → 别名**（禁用的 Key 沉到列表尾部，
    /// 避免「停用的 key 排在第一位」造成误用）；分区之间同样先比「是否含启用成员」。
    ///
    /// `modelCount` 的口径必须只有一处，否则界面与 CLI 会出现两个不同的数字：
    ///   ① 有实测发现结果 → 去重后的实测模型数；
    ///   ② 无实测结果 → 宿主声明的绑定数（即「目前已知能提供几个」）。
    public func keyGroups() throws -> [KeyGroup] {
        let records = try listKeys()
        var order: [String] = []
        var buckets: [String: [KeyRecord]] = [:]
        for record in records {
            let label = record.label
            if buckets[label] == nil {
                buckets[label] = []
                order.append(label)
            }
            buckets[label]?.append(record)
        }

        let groups: [KeyGroup] = order.compactMap { label in
            guard var members = buckets[label] else { return nil }
            members.sort {
                if $0.enabled != $1.enabled { return $0.enabled }
                if $0.priority != $1.priority { return $0.priority < $1.priority }
                return $0.label < $1.label
            }
            let primary = members[0]
            // 计数取「实测去重数」与「宿主声明绑定数」的**较大者**。
            //
            // 为什么不直接二选一：本机实测发现 `cachedDiscovery` 在 `model-cache.json`
            // 不存在时并非恒定返回 nil，于是「有实测就用实测」会让标题显示 0，
            // 而同一张卡片内由 `modelBindings` 渲染出的模型却是 6 个——同一张卡两个数字打架。
            // 取较大者能保证「标题数 ≥ 卡片里看得到的数」，不会出现自相矛盾的 0。
            let discovered = cachedDiscovery(for: primary)?.modelCount ?? 0
            let declared = primary.modelBindings.count
            return KeyGroup(label: label, records: members, modelCount: max(discovered, declared))
        }

        return groups.sorted { lhs, rhs in
            let le = lhs.records.contains { $0.enabled }
            let re = rhs.records.contains { $0.enabled }
            if le != re { return le }
            let lp = lhs.records.map { $0.priority }.min() ?? 100
            let rp = rhs.records.map { $0.priority }.min() ?? 100
            if lp != rp { return lp < rp }
            return lhs.label < rhs.label
        }
    }

    // MARK: - 模型发现（需求：识别每把 key 能提供哪些模型）

    /// 单个候选端点是否可探测的判定（供界面提前告知用户「这把 key 没有可探测端点」）
    public func probeCandidates(for record: KeyRecord) -> [ModelEndpointProbe.Candidate] {
        let provider = providers.provider(id: record.providerID)
        return ModelEndpointProbe.candidates(
            baseURL: record.baseURL,
            providerBaseURL: provider?.baseURL,
            healthPath: provider?.healthPath
        )
    }

    /// 读取该 Key 已缓存的发现结果（不发起任何网络请求）
    public func cachedDiscovery(for record: KeyRecord) -> ModelDiscoveryResult? {
        discoveryCache.result(for: record.id, fingerprint: record.fingerprint)
    }

    /// 只读获取「这把 key 能提供哪些模型」：有缓存用缓存，没有缓存则执行一次发现。
    ///
    /// 关键取舍：**缓存优先**。避免每次打开密钥库都对所有端点发起真实请求
    /// （与 NOT-003「不做后台轮询」一致），同时用户仍可显式点「重新探测」刷新。
    @discardableResult
    public func ensureDiscoveredModels(
        for record: KeyRecord,
        hostRecords: [HostModelRecord]? = nil,
        force: Bool = false,
        persist: Bool = true
    ) async -> ModelDiscoveryResult {
        if !force, let cached = cachedDiscovery(for: record) { return cached }
        let result = await runDiscovery(for: record, hostRecords: hostRecords)
        if persist { discoveryCache.store(result, for: record.id) }
        return result
    }

    /// 探测单把 Key 的可用模型（显式动作，等价于界面上的「⟳ 探测模型」）
    @discardableResult
    public func discoverModels(forKeyID id: String, hostRecords: [HostModelRecord]? = nil) async throws -> ModelDiscoveryResult {
        let keys = try listKeys()
        guard let record = keys.first(where: { $0.id == id }) else { throw ServiceError.unknownKey(id) }
        let result = await ensureDiscoveredModels(for: record, hostRecords: hostRecords, force: true)
        try? audit.append(AuditEntry(
            action: .modelDiscovery,
            result: result.probed ? "success" : (result.models.isEmpty ? "failure" : "degraded"),
            message: "识别密钥「\(record.label)」可提供的模型：\(result.note)",
            keyID: record.id,
            providerID: record.providerID,
            fingerprint: record.fingerprint
        ))
        return result
    }

    /// 探测全部 Key（并发执行，界面上的「全部探测模型」）
    public func discoverAllModels(hostRecords: [HostModelRecord]? = nil) async throws -> [String: ModelDiscoveryResult] {
        let keys = try listKeys()
        let records = hostRecords ?? hostModelRecords()
        var out: [String: ModelDiscoveryResult] = [:]
        await withTaskGroup(of: (String, ModelDiscoveryResult).self) { group in
            for record in keys {
                group.addTask { [self] in
                    let result = await ensureDiscoveredModels(for: record, hostRecords: records, force: true)
                    return (record.id, result)
                }
            }
            for await pair in group { out[pair.0] = pair.1 }
        }
        let probed = out.values.filter { $0.probed }.count
        try? audit.append(AuditEntry(
            action: .modelDiscovery,
            result: "success",
            message: "批量识别密钥可用模型：\(probed)/\(out.count) 把密钥成功从端点取证",
            providerID: nil
        ))
        return out
    }

    /// 一次发现的内部实现：取明文 → 逐级兜底 → 返回结果（不落盘）
    private func runDiscovery(
        for record: KeyRecord,
        hostRecords: [HostModelRecord]? = nil
    ) async -> ModelDiscoveryResult {
        let provider = providers.provider(id: record.providerID)
        let secret = (try? vault.secret(id: record.id)) ?? ""
        let records = hostRecords ?? hostModelRecords()
        let bindings = HostModelInventory.bindings(
            for: record,
            provider: provider,
            targets: targets.targets,
            records: records
        )
        let hostMapped = ModelDiscovery.hostMappedModels(bindings)

        // T5 推断素材：宿主里有、但没被 T4 绑定的模型记录
        let boundIDs = Set(bindings.map { ModelIdentifier.comparisonKey($0.modelID) })
        let inferable = records.filter { !boundIDs.contains(ModelIdentifier.comparisonKey($0.id)) }

        let candidates = ModelEndpointProbe.candidates(
            baseURL: record.baseURL,
            providerBaseURL: provider?.baseURL,
            healthPath: provider?.healthPath
        )
        return await discovery.discover(
            secret: secret,
            provider: provider,
            candidates: candidates,
            transport: transport,
            hostMapped: hostMapped,
            inferable: inferable,
            balancePath: EndpointProtocol.balancePath(provider: provider, baseURL: record.baseURL),
            baseURL: record.baseURL,
            authOverride: EndpointProtocol.authOverride(provider: provider, baseURL: record.baseURL),
            fingerprint: record.fingerprint
        )
    }

    // MARK: - 密钥详情（需求：点进 key 查看详情）

    /// 该 Key 已注入到的宿主落点（来自审计日志的成功注入记录，按目标去重）
    public struct InjectedLocation: Sendable {
        public var targetID: String
        public var targetName: String
        public var filePath: String
        public var itemKey: String
        public var lastInjectedAt: Date

        public init(targetID: String, targetName: String, filePath: String, itemKey: String, lastInjectedAt: Date) {
            self.targetID = targetID
            self.targetName = targetName
            self.filePath = filePath
            self.itemKey = itemKey
            self.lastInjectedAt = lastInjectedAt
        }
    }

    /// 密钥详情聚合：元数据 + 可用模型 + 宿主绑定 + 落点 + 审计摘要
    ///
    /// 语义边界：`availableModels` 是「这把 Key 能提供什么」（端点取证优先），
    /// `bindings` 是「宿主当前声明使用什么」（配置映射）。两者刻意分开返回，
    /// 界面才能如实说明「哪些是实测到的、哪些只是宿主声明的」。
    public struct KeyDetail: Sendable {
        public var record: KeyRecord
        public var discovery: ModelDiscoveryResult?
        public var availableModels: [AvailableModel]
        public var bindings: [HostModelInventory.Binding]
        public var locations: [InjectedLocation]
        public var auditEntries: [AuditEntry]
        /// 该 Key 是否具备可探测端点（false 时界面提示「请填写端点」而不是假装探测过）
        public var probeable: Bool

        public init(
            record: KeyRecord,
            discovery: ModelDiscoveryResult?,
            availableModels: [AvailableModel],
            bindings: [HostModelInventory.Binding],
            locations: [InjectedLocation],
            auditEntries: [AuditEntry],
            probeable: Bool
        ) {
            self.record = record
            self.discovery = discovery
            self.availableModels = availableModels
            self.bindings = bindings
            self.locations = locations
            self.auditEntries = auditEntries
            self.probeable = probeable
        }
    }

    /// 组装密钥详情；`hostRecords` 可覆盖宿主记录（测试与隔离验证用）
    public func keyDetail(
        id: String,
        auditLimit: Int = 20,
        hostRecords: [HostModelRecord]? = nil
    ) throws -> KeyDetail {
        let keys = try listKeys()
        guard var record = keys.first(where: { $0.id == id }) else { throw ServiceError.unknownKey(id) }
        let resolvedHostRecords = hostRecords ?? hostModelRecords()
        let bindings = HostModelInventory.bindings(
            for: record,
            provider: providers.provider(id: record.providerID),
            targets: targets.targets,
            records: resolvedHostRecords
        )
        record.modelBindings = bindings
        let discovery = cachedDiscovery(for: record)
        let available = discovery?.normalizedModels ?? ModelDiscovery.hostMappedModels(bindings)

        let entries = audit.all().filter { $0.keyID == id }
        var locations: [String: InjectedLocation] = [:]
        var order: [String] = []
        for entry in entries where entry.action == .inject && entry.result == "success" {
            guard let targetID = entry.targetID, let filePath = entry.filePath else { continue }
            let target = targets.target(id: targetID)
            let itemKey = target.flatMap { t -> String? in
                guard let provider = providers.provider(id: record.providerID) else { return t.itemKey }
                return resolvedTargetItemKey(for: t, provider: provider)
            } ?? ""
            if locations[targetID] == nil {
                order.append(targetID)
                locations[targetID] = InjectedLocation(
                    targetID: targetID,
                    targetName: target?.name ?? targetID,
                    filePath: filePath,
                    itemKey: itemKey,
                    lastInjectedAt: entry.timestamp
                )
            } else if entry.timestamp > (locations[targetID]?.lastInjectedAt ?? .distantPast) {
                locations[targetID]?.lastInjectedAt = entry.timestamp
            }
        }

        return KeyDetail(
            record: record,
            discovery: discovery,
            availableModels: available.sorted { $0.sortKey < $1.sortKey },
            bindings: bindings,
            locations: order.compactMap { locations[$0] },
            auditEntries: Array(entries.suffix(auditLimit).reversed()),
            probeable: !probeCandidates(for: record).isEmpty
        )
    }

    /// 模型清单概览：跨宿主计数、来源路径与凭据占用
    ///
    /// 路径可覆盖是为了让测试能在临时目录里造一套宿主配置，
    /// 而不必依赖运行本机的 `~/.codex` 与 DSH 设置。
    public func hostModelOverview(
        dshSettingsPath: String = DshModelCatalog.defaultSettingsPath,
        dshCredentialsPath: String = DshModelCatalog.defaultCredentialsPath,
        codexCatalogPath: String = CodexCatalogStore.defaultPath,
        codexConfigPath: String? = nil
    ) -> [String: Any] {
        let records = DshModelCatalog.records(path: dshSettingsPath)
            + HostModelInventory.codexSnapshot(catalogPath: codexCatalogPath, configPath: codexConfigPath).gatewayRecords
        let groups = HostModelInventory.groups(records)
        let dshPath = PathKit.expand(dshSettingsPath)
        let codex = HostModelInventory.codexSnapshot(catalogPath: codexCatalogPath, configPath: codexConfigPath)
        let credentials = DshModelCatalog.credentialStatus(path: dshCredentialsPath)

        var dshDeclared = 0, dshConfigured = 0
        for record in records where record.host == .dsh {
            dshDeclared += 1
            if credentials[record.credentialKey] == true { dshConfigured += 1 }
        }

        return [
            "total": records.count,
            "uniqueModels": groups.count,
            "dshCount": records.filter { $0.host == .dsh }.count,
            "codexGatewayCount": codex.gatewayRecords.count,
            "codexOfficialCount": codex.officialCount,
            "dshSettingsPath": dshPath,
            "dshSettingsExists": FileManager.default.fileExists(atPath: dshPath),
            "dshCredentialsPath": PathKit.expand(dshCredentialsPath),
            "dshDeclared": dshDeclared,
            "dshCredentialConfigured": dshConfigured,
            "codexCatalogPath": codex.catalogPath,
            "codexConfigPath": codex.configPath,
            "codexEndpoint": codex.endpoint,
            "codexConfigModel": codex.configModel,
            "codexConfigProvider": codex.configProvider,
            "codexRoutingHealthy": codex.routingHealthy,
            "boundKeyCount": ((try? listKeysWithModels()) ?? []).filter { !$0.modelBindings.isEmpty }.count
        ]
    }

    // MARK: - 宿主配置同步（网关为唯一事实源）

    /// 网关配置的只读视图（模型清单、地址、二进制路径的唯一来源）
    public func gatewayConfig(path: String = GatewayConfig.defaultPath) -> GatewayConfig {
        GatewayConfig.loadOrEmpty(path: path)
    }

    /// 计算同步计划（只读，绝不落盘）。
    ///
    /// 把网关声明的模型清单与两个客户端的实际配置对比，得出「要不要改、改什么」。
    /// 与注入流程一致：先出计划，再显式落盘。
    public func planHostConfigSync(
        gatewayPath: String = GatewayConfig.defaultPath,
        dshSettingsPath: String = DshModelCatalog.defaultSettingsPath,
        codexCatalogPath: String = CodexCatalogStore.defaultPath,
        mergeMode: HostConfigSync.MergeMode = .merge
    ) -> HostConfigSync.Plan {
        let gateway = gatewayConfig(path: gatewayPath)

        // ---- DSH 侧 ----
        var dsh = HostConfigSync.Result(changed: false, dryRun: true, summary: "", targetPath: PathKit.expand(dshSettingsPath),
                                        before: nil, after: nil, notes: [], failure: nil, backupPath: nil)
        let dshExpanded = PathKit.expand(dshSettingsPath)
        if !gateway.isUsable {
            dsh.failure = SyncError.gatewayUnavailable(PathKit.expand(gatewayPath)).description
            dsh.summary = "已跳过：读不到网关声明的模型清单"
        } else if let text = try? String(contentsOfFile: dshExpanded, encoding: .utf8) {
            let lines = text.components(separatedBy: "\n")
            if let location = HostConfigSync.locateDshProvider(lines: lines, baseURL: gateway.baseURL) {
                do {
                    let patched = try HostConfigSync.patchDshModels(
                        content: text, providerID: location.providerID,
                        models: gateway.upstreamModels, mode: mergeMode
                    )
                    let added = patched.after.filter { !location.currentModels.contains($0) }
                    let removed = location.currentModels.filter { !patched.after.contains($0) }
                    if added.isEmpty && removed.isEmpty {
                        dsh.summary = "已一致（供应商 \(location.providerID)，\(location.currentModels.count) 个模型）"
                    } else {
                        dsh.changed = true
                        dsh.before = text
                        dsh.after = patched.text
                        if !added.isEmpty { dsh.notes.append("补齐网关模型：\(added.joined(separator: "、"))") }
                        if !removed.isEmpty { dsh.notes.append("移除：\(removed.joined(separator: "、"))") }
                        if mergeMode == .merge {
                            let kept = location.currentModels.filter { !gateway.upstreamModels.contains($0) }
                            if !kept.isEmpty {
                                dsh.notes.append("保留未在网关声明的 \(kept.count) 个模型（merge 模式只增不减）：\(kept.joined(separator: "、"))")
                            }
                        }
                        dsh.summary = "供应商 \(location.providerID)：\(location.currentModels.count) → \(patched.after.count) 个模型"
                    }
                } catch {
                    dsh.failure = String(describing: error)
                    dsh.summary = "已跳过：配置写法暂不支持"
                }
            } else {
                // 有歧义或找不到：如实说明，绝不猜测性插入（可能是用户还没建这个供应商）
                let candidates = DshModelCatalog.providers(path: dshExpanded).filter {
                    HostModelInventory.sameEndpoint($0.baseURL, gateway.baseURL)
                }
                if candidates.count > 1 {
                    dsh.failure = "DSH 里有 \(candidates.count) 个供应商都指向该网关地址，无法确定该改哪一个"
                } else {
                    dsh.failure = SyncError.providerNotFound(gateway.baseURL).description
                }
                dsh.summary = "已跳过：DSH 里没有唯一确定的网关供应商"
            }
        } else {
            dsh.failure = "读不到 DSH 设置文件（\(dshExpanded)）：DSH 未安装或尚未初始化"
            dsh.summary = "已跳过：DSH 设置文件不存在"
        }

        // ---- Codex 侧 ----
        var codex = HostConfigSync.Result(changed: false, dryRun: true, summary: "", targetPath: PathKit.expand(codexCatalogPath),
                                          before: nil, after: nil, notes: [], failure: nil, backupPath: nil)
        if !gateway.isUsable {
            codex.failure = SyncError.gatewayUnavailable(PathKit.expand(gatewayPath)).description
            codex.summary = "已跳过：读不到网关声明的模型清单"
        } else {
            let existing = CodexCatalogStore.allRaw(path: codexCatalogPath)
            if let outcome = try? HostConfigSync.syncCodexCatalog(gateway: gateway, existingEntries: existing) {
                if outcome.changed {
                    codex.changed = true
                    codex.notes = outcome.added.map { "补齐/恢复菜单可见：\($0)" }
                    codex.summary = "新增或恢复 \(outcome.added.count) 条网关模型"
                } else {
                    codex.summary = "已一致（\(gateway.upstreamModels.count) 个网关模型都在目录里）"
                }
            } else {
                codex.failure = "网关模型条目缺少可参照的模板（Codex 官方模型目录不可读）"
                codex.summary = "已跳过：无法构造条目"
            }
        }

        return HostConfigSync.Plan(gateway: gateway, dsh: dsh, codex: codex)
    }

    /// 落盘同步计划。每个目标在写入前备份，写入后读回校验。
    @discardableResult
    public func applyHostConfigSync(
        gatewayPath: String = GatewayConfig.defaultPath,
        dshSettingsPath: String = DshModelCatalog.defaultSettingsPath,
        codexCatalogPath: String = CodexCatalogStore.defaultPath,
        mergeMode: HostConfigSync.MergeMode = .merge
    ) -> HostConfigSync.Plan {
        var plan = planHostConfigSync(gatewayPath: gatewayPath, dshSettingsPath: dshSettingsPath,
                                      codexCatalogPath: codexCatalogPath, mergeMode: mergeMode)
        plan.dsh.dryRun = false
        plan.codex.dryRun = false

        if plan.dsh.changed, let after = plan.dsh.after {
            do {
                let url = URL(fileURLWithPath: plan.dsh.targetPath)
                let record = try engine.backups.backup(targetID: "dsh-settings", fileURL: url)
                plan.dsh.backupPath = record.backupPath
                try AtomicWriter.write(after, to: url, preservePermissionsFrom: url)
                let readBack = try String(contentsOfFile: plan.dsh.targetPath, encoding: .utf8)
                if readBack != after {
                    plan.dsh.failure = "写后读回校验不一致，已保留备份待回滚"
                    plan.dsh.changed = false
                }
            } catch {
                plan.dsh.failure = "写入失败：\(error)"
                plan.dsh.changed = false
            }
        }

        if plan.codex.changed {
            do {
                let url = URL(fileURLWithPath: plan.codex.targetPath)
                let record = try engine.backups.backup(targetID: "codex-model-catalog", fileURL: url)
                plan.codex.backupPath = record.backupPath
                let existing = CodexCatalogStore.allRaw(path: codexCatalogPath)
                if let outcome = try? HostConfigSync.syncCodexCatalog(gateway: plan.gateway, existingEntries: existing) {
                    try CodexCatalogStore.write(outcome.entries, path: codexCatalogPath)
                }
            } catch {
                plan.codex.failure = "写入失败：\(error)"
                plan.codex.changed = false
            }
        }

        return plan
    }

    /// 一键把 Codex 当前使用的网关模型切换为指定模型。
    ///
    /// 反例边界：本工具**不自动**在额度耗尽时替你换模型（这是用户的明确选择：
    /// 只告警、不自动切）。但「换模型」这件事本身要付出的人工代价应当被压到最低——
    /// 原本要在 Codex 菜单里点选并确认 provider，现在是一条命令 / 一个按钮，
    /// 且写入前备份、写入后校验，比手改更不容易出错。
    public func switchCodexGatewayModel(
        to model: String,
        configPath: String? = nil,
        dryRun: Bool = true
    ) throws -> GatewayRoutingRepair {
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ServiceError.invalidArgument("模型名不能为空") }
        let path = Self.defaultCodexConfigPath(explicit: configPath)
        let url = URL(fileURLWithPath: path)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            throw ServiceError.invalidArgument("找不到 Codex 配置文件：\(path)")
        }
        let before = checkCodexGatewayRouting(configPath: path)
        let updated = InjectionEngine.setCodexGatewayModel(trimmed, in: text)
        let status = GatewayRoutingStatus(
            configPath: path,
            model: trimmed,
            provider: "codex_gateway",
            healthy: true,
            exists: true
        )
        guard updated != text else {
            return GatewayRoutingRepair(status: before, changed: false, dryRun: dryRun, backupPath: nil, preview: nil)
        }
        if dryRun {
            return GatewayRoutingRepair(status: status, changed: true, dryRun: true, backupPath: nil, preview: updated)
        }
        let backup = try engine.backups.backup(targetID: "codex-gateway-routing", fileURL: url)
        try AtomicWriter.write(updated, to: url, preservePermissionsFrom: url)
        return GatewayRoutingRepair(status: status, changed: true, dryRun: false, backupPath: backup.backupPath, preview: nil)
    }

    // MARK: - 落点键名解析（宿主声明优先）

    /// 某落点**实际应当写入**的键名。
    ///
    /// 反例边界：`InjectionTarget.itemKey` 是落点目录里写死的静态值，而宿主的
    /// 真实要求由宿主自己的配置决定。DSH 落点此前硬编码 `DEEPSEEK_API_KEY`，
    /// 而 DSH 实际读取的是 `settings.yaml` 里 `apiKeyEnv` 声明的 `MIDPRO_API_KEY`，
    /// 结果「一键注入成功」但宿主读不到密钥——静默失效。
    /// 本方法把宿主声明作为唯一权威，静态值只作为回退。
    public func resolvedTargetItemKey(for target: InjectionTarget, provider: Provider) -> String {
        if let dynamic = hostDeclaredKeyName(forTargetID: target.id), !dynamic.isEmpty {
            return dynamic
        }
        return target.resolvedItemKey(for: provider)
    }

    /// 宿主配置里为该落点声明的键名（仅在能唯一确定时返回，否则 nil）
    public func hostDeclaredKeyName(forTargetID targetID: String) -> String? {
        guard targetID == "dsh-desktop" else { return nil }
        let enabled = dshProviders().filter { $0.enabled && !$0.apiKeyEnv.isEmpty }
        // 只有单供应商场景才能无歧义地把落点绑到某个键名；
        // 多供应商时必须由用户显式指定，绝不猜。
        guard enabled.count == 1 else { return nil }
        return enabled[0].apiKeyEnv
    }

    /// 落点键名与宿主声明的一致性体检（供 dry-run 明确提示，而不是写完才发现）
    public func targetKeyMismatch(for target: InjectionTarget, provider: Provider) -> String? {
        guard let declared = hostDeclaredKeyName(forTargetID: target.id) else { return nil }
        let configured = target.resolvedItemKey(for: provider)
        guard configured.uppercased() != declared.uppercased() else { return nil }
        return "落点目录登记键名为 \(configured)，但宿主实际读取 \(declared)；已按宿主声明写入 \(declared)，请确认该落点无需保留 \(configured)。"
    }

    // MARK: - 注入

    public func planInjection(
        targetID: String,
        keyID: String,
        overridePath: String? = nil,
        jsonPathOverride: [String]? = nil,
        sectionOverride: String? = nil,
        itemKeyOverride: String? = nil,
        cachedSecret: String? = nil
    ) throws -> InjectionPlan {
        guard let target = targets.target(id: targetID) else { throw ServiceError.unknownTarget(targetID) }
        let keys = try listKeys()
        guard let record = keys.first(where: { $0.id == keyID }) else { throw ServiceError.unknownKey(keyID) }
        let provider = providers.provider(id: record.providerID) ?? Provider(id: record.providerID, name: record.providerID, envKeys: [record.providerID.uppercased() + "_API_KEY"])
        let secret: String
        if let cachedSecret, !cachedSecret.isEmpty {
            secret = cachedSecret
        } else {
            secret = (try? vault.secret(id: record.id)) ?? ""
        }
        // 键名优先级：调用方显式覆盖 > 宿主声明 > 落点静态登记值。
        // 宿主声明必须压过落点静态值，否则会出现「注入成功但宿主读不到」的静默失效。
        let effectiveItemKey = itemKeyOverride ?? resolvedTargetItemKey(for: target, provider: provider)
        let keyMismatch = (itemKeyOverride == nil) ? targetKeyMismatch(for: target, provider: provider) : nil

        var plan = try engine.plan(
            target: target,
            provider: provider,
            keyRecord: record,
            secret: secret,
            overridePath: overridePath,
            jsonPathOverride: jsonPathOverride,
            sectionOverride: sectionOverride,
            itemKeyOverride: effectiveItemKey
        )
        if let keyMismatch {
            // 只在真正发生键名变更时提示：若宿主文件里已是声明的键名
            // （本次 patch 为空操作），静态登记值只剩文档意义，不该吓唬用户。
            let changed = plan.originalContent == nil || plan.patchedContent != plan.originalContent
            if changed { plan.warnings.append(keyMismatch) }
        }
        // 把该密钥供给的模型一并写进计划，dry-run 阶段即可核对「这个 Key 管哪些模型」
        plan.suppliedModels = modelBindings(for: record)
        return plan
    }

    @discardableResult
    public func applyInjection(_ plan: InjectionPlan) throws -> ApplyOutcome {
        try engine.apply(plan: plan)
    }

    @discardableResult
    public func rollback(entry: AuditEntry) throws -> RollbackOutcome {
        try engine.rollback(entry: entry)
    }

    /// 查找某落点最近一次可回滚的注入记录
    public func latestInjectableEntry(targetID: String, filePath: String) -> AuditEntry? {
        audit.latestBackup(targetID: targetID, filePath: filePath)
    }

    // MARK: - Codex 模型目录（可视化来源与投放）

    /// 读取 Codex 模型目录（默认只返回公司网关条目，`includeOfficial` 为真时返回全部）
    public func codexCatalogEntries(includeOfficial: Bool = false) -> [CodexCatalogEntry] {
        let entries = CodexCatalogStore.load()
        return includeOfficial ? entries : entries.filter { $0.isGateway }
    }

    /// 目录概览：路径、条目数、菜单可见数与 config.toml 注册状态
    public func codexCatalogOverview() -> [String: Any] {
        let path = CodexCatalogStore.defaultPath
        let entries = CodexCatalogStore.load(path: path)
        let gateway = entries.filter { $0.isGateway }
        let configPath = PathKit.expand("~/.codex/config.toml")
        let configText = (try? String(contentsOfFile: configPath, encoding: .utf8)) ?? ""
        return [
            "catalogPath": path,
            "catalogExists": FileManager.default.fileExists(atPath: path),
            "total": entries.count,
            "gateway": gateway.count,
            "gatewayInPicker": gateway.filter { $0.inPicker }.count,
            "officialInPicker": entries.filter { !$0.isGateway && $0.inPicker }.count,
            "registeredInConfig": configText.contains(path),
            "configPath": configPath,
            "configModel": InjectionEngine.firstModelSlug(in: configText) ?? "",
            "configProvider": InjectionEngine.firstAssignmentValue("model_provider", in: configText) ?? ""
        ]
    }

    /// 新增公司网关模型到目录
    @discardableResult
    public func addCodexGatewayModel(slug: String, displayName: String, description: String = "", inPicker: Bool = true) throws -> Bool {
        try CodexCatalogStore.addGatewayModel(slug: slug, displayName: displayName,
                                             description: description.isEmpty ? "Company gateway model registered by KeyInjector." : description,
                                             inPicker: inPicker)
    }

    /// 切换条目是否出现在桌面端模型菜单
    @discardableResult
    public func setCodexModelInPicker(slug: String, inPicker: Bool) throws -> Bool {
        try CodexCatalogStore.setInPicker(slug: slug, inPicker: inPicker)
    }

    /// 删除公司网关模型条目
    @discardableResult
    public func removeCodexGatewayModel(slug: String) throws -> Bool {
        try CodexCatalogStore.removeGatewayModel(slug: slug)
    }

    // MARK: - Codex 网关 provider 路由守护

    /// Codex 配置目录：优先 `CODEX_HOME` 环境变量，其次 `~/.codex`。
    /// launchd 守护可用 plist 的 EnvironmentVariables 指向沙箱目录做隔离验证。
    public static func codexHome() -> String {
        if let env = ProcessInfo.processInfo.environment["CODEX_HOME"], !env.isEmpty {
            return PathKit.expand(env)
        }
        return PathKit.expand("~/.codex")
    }

    public static func defaultCodexConfigPath(explicit: String? = nil) -> String {
        if let explicit, !explicit.isEmpty { return PathKit.expand(explicit) }
        return (codexHome() as NSString).appendingPathComponent("config.toml")
    }

    public static func defaultCodexCatalogPath() -> String {
        (codexHome() as NSString).appendingPathComponent("codex-gateway-models.json")
    }

    /// 检查 `~/.codex/config.toml` 是否把当前网关模型路由到 `codex_gateway`
    public func checkCodexGatewayRouting(configPath: String? = nil) -> GatewayRoutingStatus {
        let path = Self.defaultCodexConfigPath(explicit: configPath)
        let catalog = Self.defaultCodexCatalogPath()
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
            return GatewayRoutingStatus(configPath: path, model: nil, provider: nil, healthy: true, exists: false)
        }
        let model = InjectionEngine.firstModelSlug(in: text)
        let provider = InjectionEngine.firstAssignmentValue("model_provider", in: text)
        return GatewayRoutingStatus(
            configPath: path,
            model: model,
            provider: provider,
            healthy: InjectionEngine.codexGatewayRoutingOK(text, catalogPath: catalog),
            exists: true
        )
    }

    /// 修复网关模型的路由（必要时先备份再原子写入）
    @discardableResult
    public func repairCodexGatewayRouting(configPath: String? = nil, dryRun: Bool = true) throws -> GatewayRoutingRepair {
        let path = Self.defaultCodexConfigPath(explicit: configPath)
        let catalog = Self.defaultCodexCatalogPath()
        let url = URL(fileURLWithPath: path)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            throw ServiceError.invalidArgument("找不到 Codex 配置文件：\(path)")
        }
        let before = checkCodexGatewayRouting(configPath: path)
        let updated = InjectionEngine.ensureCodexGatewayProviderRouting(text, catalogPath: catalog)
        if updated == text {
            return GatewayRoutingRepair(status: before, changed: false, dryRun: dryRun, backupPath: nil)
        }
        if dryRun {
            return GatewayRoutingRepair(status: before, changed: true, dryRun: true, backupPath: nil, preview: updated)
        }
        let backup = try? engine.backups.backup(targetID: "codex-gateway-routing", fileURL: url)
        try AtomicWriter.write(updated, to: url, preservePermissionsFrom: url)
        try? audit.append(AuditEntry(
            action: .inject,
            result: "success",
            message: "已修复 Codex 网关路由：model_provider = codex_gateway",
            targetID: "codex-gateway-routing",
            filePath: path,
            keyID: nil,
            providerID: "custom",
            fingerprint: Fingerprint.short(updated),
            backupPath: backup?.backupPath
        ))
        return GatewayRoutingRepair(status: checkCodexGatewayRouting(configPath: path), changed: true, dryRun: false, backupPath: backup?.backupPath)
    }

    // MARK: - 健康探测

    @discardableResult
    public func checkKey(id: String) async throws -> CheckSummary {
        let keys = try listKeys()
        guard let record = keys.first(where: { $0.id == id }) else { throw ServiceError.unknownKey(id) }
        guard let provider = providers.provider(id: record.providerID) else {
            throw ServiceError.unknownProvider(record.providerID)
        }
        let secret = try vault.secret(id: record.id)
        let summary = await health.check(provider: provider, secret: secret, overrideBaseURL: record.baseURL)
        try? vault.recordCheck(id: record.id, summary: summary)
        try? audit.append(AuditEntry(
            action: .healthCheck,
            result: summary.status == .valid ? "success" : "failure",
            message: "探测密钥「\(record.label)」：\(summary.status.label) — \(summary.message)",
            keyID: record.id,
            providerID: provider.id,
            fingerprint: record.fingerprint
        ))
        return summary
    }

    public func checkAllKeys() async throws -> [String: CheckSummary] {
        let keys = try listKeys()
        var items: [(record: KeyRecord, provider: Provider, secret: String)] = []
        for record in keys {
            guard let provider = providers.provider(id: record.providerID) else { continue }
            guard let secret = try? vault.secret(id: record.id) else { continue }
            items.append((record, provider, secret))
        }
        let results = await health.checkAll(items)
        for (id, summary) in results {
            try? vault.recordCheck(id: id, summary: summary)
        }
        if !results.isEmpty {
            let ok = results.values.filter { $0.status == .valid }.count
            try? audit.append(AuditEntry(
                action: .healthCheck,
                result: ok == results.count ? "success" : "failure",
                message: "批量探测完成：\(ok)/\(results.count) 个密钥有效",
                providerID: nil
            ))
        }
        return results
    }

    // MARK: - 审计与设置

    public func recentAudit(_ limit: Int = 50) -> [AuditEntry] { audit.recent(limit) }

    public func saveSettings(_ newValue: AppSettings) throws {
        let s = newValue
        settings = s
        try settingsStore.save(s)
    }

    public func addCustomTarget(_ target: InjectionTarget) throws {
        var s = settings
        s.customTargets.removeAll { $0.id == target.id }
        s.customTargets.append(target)
        try saveSettings(s)
        targets = targets.merged(with: [target])
    }

    public func removeCustomTarget(id: String) throws {
        var s = settings
        s.customTargets.removeAll { $0.id == id }
        try saveSettings(s)
        targets = TargetCatalog().merged(with: s.customTargets)
        let overrideDir = root.appendingPathComponent("config", isDirectory: true)
        if let data = try? Data(contentsOf: overrideDir.appendingPathComponent("targets.json")),
           let list = try? JSONDecoder().decode([InjectionTarget].self, from: data) {
            targets = targets.merged(with: list)
        }
    }

    // MARK: - 运行时信息

    public func runtimeInfo() -> [String: String] {
        [
            "root": root.path,
            "storeBackend": vault.backendName,
            "auditFile": audit.path,
            "providerCount": String(providers.providers.count),
            "targetCount": String(targets.targets.count),
            // 版本来自代码常量这一唯一来源，界面的版本徽标直接消费它，
            // 因此 HTML 里的静态占位文字永远只是「首帧占位」，不会长期漂移。
            "version": AppVersion.current,
            "productName": AppVersion.productName
        ]
    }
}

public enum ServiceError: Error, CustomStringConvertible {
    case unknownProvider(String)
    case unknownTarget(String)
    case unknownKey(String)
    case invalidArgument(String)

    public var description: String {
        switch self {
        case .unknownProvider(let id): return "未知厂商：\(id)（可用值见 `keyinject providers`）"
        case .unknownTarget(let id): return "未知注入落点：\(id)（可用值见 `keyinject targets`）"
        case .unknownKey(let id): return "未找到密钥记录：\(id)（可用值见 `keyinject keys`）"
        case .invalidArgument(let message): return message
        }
    }
}

// MARK: - 端点协议适配（REQ-024 / REQ-026）

/// 判定「这家厂商的这个端点该用哪种鉴权」。
///
/// 为什么需要它：厂商预设的 `authStyle` 描述的是**原生端点**的规则，
/// 但同一个厂商可能同时提供原生协议与 OpenAI 兼容协议，而两者鉴权方式不同。
/// 实测（见 `docs/knowledge-account-protocols.md` 第六之二节）：
/// - Gemini 原生 `…/v1beta/models`：`?key=` 或 `x-goog-api-key`
/// - Gemini 兼容 `…/v1beta/openai/models`：**必须** `Authorization: Bearer`，
///   且缺少该头时返回 404 而非 401/403，极易被误读成「不支持模型列表」
/// 所以对 Gemini 的兼容端点必须覆盖为 Bearer，否则探测会稳定失败。
enum EndpointProtocol {

    /// 需要覆盖的鉴权风格；nil 表示沿用厂商预设
    static func authOverride(provider: Provider?, baseURL: String?) -> AuthStyle? {
        guard let provider, provider.id == "google" else { return nil }
        let custom = (baseURL ?? "").lowercased()
        guard custom.contains("/openai") else { return nil }
        return .bearer
    }

    /// 该 Key 当前配置下是否可比较余额（余额接口只在厂商官方端点上存在）。
    ///
    /// 反例保护：自定义中转网关不会转 `/user/balance`，若照样请求，
    /// 只会得到一条 404 噪声并把「余额不可得」误报成「余额为零」。
    static func balancePath(provider: Provider?, baseURL: String?) -> String? {
        guard let path = provider?.balancePath, !path.isEmpty else { return nil }
        let custom = (baseURL ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !custom.isEmpty else { return path }
        let official = (provider?.baseURL ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !official.isEmpty, custom.hasPrefix(official) else { return nil }
        return path
    }
}
