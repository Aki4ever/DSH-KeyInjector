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
        return try engine.plan(
            target: target,
            provider: provider,
            keyRecord: record,
            secret: secret,
            overridePath: overridePath,
            jsonPathOverride: jsonPathOverride,
            sectionOverride: sectionOverride,
            itemKeyOverride: itemKeyOverride
        )
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
            "targetCount": String(targets.targets.count)
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
