// ==============================================================================
// 门面服务：把仓库、注入引擎、健康探测与审计日志组装成单一入口，
// 供命令行与桌面界面共用（保证两端行为完全一致）。
// ==============================================================================
import Foundation

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

        // 选择密钥明文后端：钥匙串优先，失败则如实告知并降级
        var warnings: [String] = []
        var store: SecretStore
        switch wanted {
        case "memory":
            store = MemorySecretStore()
        case "file":
            store = try FileSecretStore(root: dir)
        default:
            #if canImport(Security)
            store = KeychainSecretStore()
            #else
            store = try FileSecretStore(root: dir)
            warnings.append("当前平台不支持钥匙串，已降级为本地加密文件后端")
            #endif
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

    public func addKey(providerID: String, label: String, secret: String, priority: Int = 100, tags: [String] = [], note: String = "") throws -> KeyRecord {
        guard providers.provider(id: providerID) != nil else {
            throw ServiceError.unknownProvider(providerID)
        }
        let record = try vault.add(providerID: providerID, label: label, secret: secret, priority: priority, tags: tags, note: note)
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
        itemKeyOverride: String? = nil
    ) throws -> InjectionPlan {
        guard let target = targets.target(id: targetID) else { throw ServiceError.unknownTarget(targetID) }
        let keys = try listKeys()
        guard let record = keys.first(where: { $0.id == keyID }) else { throw ServiceError.unknownKey(keyID) }
        guard let provider = providers.provider(id: record.providerID) else {
            throw ServiceError.unknownProvider(record.providerID)
        }
        let secret = try vault.secret(id: record.id)
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

    // MARK: - 健康探测

    @discardableResult
    public func checkKey(id: String) async throws -> CheckSummary {
        let keys = try listKeys()
        guard let record = keys.first(where: { $0.id == id }) else { throw ServiceError.unknownKey(id) }
        guard let provider = providers.provider(id: record.providerID) else {
            throw ServiceError.unknownProvider(record.providerID)
        }
        let secret = try vault.secret(id: record.id)
        let summary = await health.check(provider: provider, secret: secret)
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

    public var description: String {
        switch self {
        case .unknownProvider(let id): return "未知厂商：\(id)（可用值见 `keyinject providers`）"
        case .unknownTarget(let id): return "未知注入落点：\(id)（可用值见 `keyinject targets`）"
        case .unknownKey(let id): return "未找到密钥记录：\(id)（可用值见 `keyinject keys`）"
        }
    }
}
