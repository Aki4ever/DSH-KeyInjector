// ==============================================================================
// 存储层：密钥明文后端（钥匙串 / 加密文件 / 内存）、密钥仓库、审计日志、应用设置
// ==============================================================================
import Foundation
import CryptoKit
#if canImport(Security)
import Security
#endif

// MARK: - 密钥明文后端协议

public protocol SecretStore: AnyObject {
    /// 后端中文名，用于在界面与审计里如实展示当前安全等级
    var backendName: String { get }
    func set(id: String, secret: String) throws
    func get(id: String) throws -> String?
    func delete(id: String) throws
}

public enum SecretStoreError: Error, CustomStringConvertible {
    case keychainFailed(OSStatus, String)
    case notFound(String)
    case backendUnavailable(String)
    case cryptoFailed(String)

    public var description: String {
        switch self {
        case .keychainFailed(let s, let m): return "钥匙串操作失败（状态码 \(s)）：\(m)"
        case .notFound(let id): return "未找到密钥记录 \(id) 的明文内容"
        case .backendUnavailable(let m): return "密钥后端不可用：\(m)"
        case .cryptoFailed(let m): return "加解密失败：\(m)"
        }
    }
}

// MARK: - 内存后端（测试与演示专用）

public final class MemorySecretStore: SecretStore {
    private var map: [String: String] = [:]
    public var backendName: String { "内存（进程退出即丢失）" }
    public init() {}
    public func set(id: String, secret: String) throws { map[id] = secret }
    public func get(id: String) throws -> String? { map[id] }
    public func delete(id: String) throws { map.removeValue(forKey: id) }
}

// MARK: - 系统钥匙串后端（生产默认）

#if canImport(Security)
public final class KeychainSecretStore: SecretStore {
    private let service: String
    public var backendName: String { "macOS 钥匙串" }

    public init(service: String = "com.aki4ever.keyinjector") {
        self.service = service
    }

    private func baseQuery(id: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id
        ]
    }

    public func set(id: String, secret: String) throws {
        SecItemDelete(baseQuery(id: id) as CFDictionary)
        var query = baseQuery(id: id)
        query[kSecValueData as String] = Data(secret.utf8)
        query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        #if os(macOS)
        // 允许当前应用自身在未来免输入系统密码直接访问本应用写入的密钥条目
        if let access = try? createDefaultAccess(label: "KeyInjector Secret") {
            query[kSecAttrAccess as String] = access
        }
        #endif
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw SecretStoreError.keychainFailed(status, "写入失败")
        }
    }

    #if os(macOS)
    private func createDefaultAccess(label: String) throws -> SecAccess? {
        var access: SecAccess?
        let status = SecAccessCreate(label as CFString, nil, &access)
        guard status == errSecSuccess else { return nil }
        return access
    }
    #endif

    public func get(id: String) throws -> String? {
        var query = baseQuery(id: id)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else {
            throw SecretStoreError.keychainFailed(status, "读取失败")
        }
        guard let data = item as? Data else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    public func delete(id: String) throws {
        let status = SecItemDelete(baseQuery(id: id) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw SecretStoreError.keychainFailed(status, "删除失败")
        }
    }
}
#endif

// MARK: - 本地加密文件后端（无头环境与自动化验证的降级方案）

/// 反例边界（务必知悉）：本后端的主密钥与密文存放在**同一台机器**上，
/// 因此它只能防止「配置文件被误同步/被随手打开看到明文」这类泄露，
/// **无法抵御**已经取得该机器文件读取权限的攻击者。生产环境请使用钥匙串后端。
public final class FileSecretStore: SecretStore {
    private let root: URL
    private let keyURL: URL
    private let dataURL: URL
    public var backendName: String { "本地安全加密存储 (AES-GCM)" }

    public init(root: URL) throws {
        self.root = root
        self.keyURL = root.appendingPathComponent(".storekey")
        self.dataURL = root.appendingPathComponent("secrets.enc.json")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        _ = try Self.loadOrCreateKey(at: keyURL)
    }

    private static func loadOrCreateKey(at url: URL) throws -> SymmetricKey {
        let fm = FileManager.default
        if let data = try? Data(contentsOf: url), data.count == 32 {
            return SymmetricKey(data: data)
        }
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else {
            throw SecretStoreError.cryptoFailed("随机数生成失败（状态码 \(status)）")
        }
        let data = Data(bytes)
        try data.write(to: url, options: [.atomic])
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return SymmetricKey(data: data)
    }

    private func loadMap() throws -> [String: String] {
        guard let raw = try? Data(contentsOf: dataURL) else { return [:] }
        guard let obj = try? JSONSerialization.jsonObject(with: raw) as? [String: String] else {
            throw SecretStoreError.cryptoFailed("密文容器格式损坏，无法解析")
        }
        return obj
    }

    private func saveMap(_ map: [String: String]) throws {
        let data = try JSONSerialization.data(withJSONObject: map, options: [.sortedKeys])
        try AtomicWriter.write(String(decoding: data, as: UTF8.self), to: dataURL)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: dataURL.path)
    }

    private func key() throws -> SymmetricKey { try Self.loadOrCreateKey(at: keyURL) }

    public func set(id: String, secret: String) throws {
        var map = try loadMap()
        let sealed = try ChaChaPoly.seal(Data(secret.utf8), using: try key())
        map[id] = sealed.combined.base64EncodedString()
        try saveMap(map)
    }

    public func get(id: String) throws -> String? {
        let map = try loadMap()
        guard let b64 = map[id], let combined = Data(base64Encoded: b64) else { return nil }
        do {
            let box = try ChaChaPoly.SealedBox(combined: combined)
            let opened = try ChaChaPoly.open(box, using: try key())
            return String(decoding: opened, as: UTF8.self)
        } catch {
            throw SecretStoreError.cryptoFailed("解密失败，可能是主密钥被替换：\(error.localizedDescription)")
        }
    }

    public func delete(id: String) throws {
        var map = try loadMap()
        map.removeValue(forKey: id)
        try saveMap(map)
    }
}

// MARK: - 密钥仓库

public struct VaultIndex: Codable, Sendable {
    public var schemaVersion: Int
    public var keys: [KeyRecord]
    public init(schemaVersion: Int = 1, keys: [KeyRecord] = []) {
        self.schemaVersion = schemaVersion
        self.keys = keys
    }
}

public final class KeyVault {
    private let indexURL: URL
    private let store: SecretStore

    public init(root: URL, store: SecretStore) {
        self.indexURL = root.appendingPathComponent("vault.json")
        self.store = store
    }

    public var backendName: String { store.backendName }

    private static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        e.dateEncodingStrategy = .iso8601
        return e
    }

    private static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    public func load() throws -> VaultIndex {
        guard let data = try? Data(contentsOf: indexURL) else { return VaultIndex() }
        return try Self.decoder().decode(VaultIndex.self, from: data)
    }

    private func save(_ index: VaultIndex) throws {
        let data = try Self.encoder().encode(index)
        try AtomicWriter.write(String(decoding: data, as: UTF8.self), to: indexURL)
    }

    @discardableResult
    public func add(providerID: String, label: String, secret: String, priority: Int = 100, tags: [String] = [], note: String = "", baseURL: String? = nil) throws -> KeyRecord {
        var index = try load()
        let trimmed = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedBaseURL = baseURL?.trimmingCharacters(in: .whitespacesAndNewlines)
        let record = KeyRecord(
            providerID: providerID,
            label: label.isEmpty ? "未命名密钥" : label,
            hint: Redaction.mask(trimmed),
            fingerprint: Fingerprint.short(trimmed),
            priority: priority,
            tags: tags,
            note: note,
            baseURL: (trimmedBaseURL?.isEmpty == false) ? trimmedBaseURL : nil
        )
        try store.set(id: record.id, secret: trimmed)
        index.keys.append(record)
        do {
            try save(index)
        } catch {
            // 事务原子性：索引落盘失败则回收刚写入的明文，避免出现孤儿密钥
            try? store.delete(id: record.id)
            throw error
        }
        return record
    }

    public func update(
        id: String,
        label: String? = nil,
        secret: String? = nil,
        priority: Int? = nil,
        tags: [String]? = nil,
        note: String? = nil,
        baseURL: String? = nil
    ) throws -> KeyRecord {
        var index = try load()
        guard let pos = index.keys.firstIndex(where: { $0.id == id }) else {
            throw SecretStoreError.notFound(id)
        }
        var oldSecret: String?
        var secretUpdated = false
        if let secret, !secret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let trimmed = secret.trimmingCharacters(in: .whitespacesAndNewlines)
            oldSecret = try store.get(id: id)
            index.keys[pos].hint = Redaction.mask(trimmed)
            index.keys[pos].fingerprint = Fingerprint.short(trimmed)
            try store.set(id: id, secret: trimmed)
            secretUpdated = true
        }

        let oldRecord = index.keys[pos]

        if let label, !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            index.keys[pos].label = label.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let priority {
            index.keys[pos].priority = priority
        }
        if let tags {
            index.keys[pos].tags = tags
        }
        if let note {
            index.keys[pos].note = note
        }
        if let baseURL {
            let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            index.keys[pos].baseURL = trimmed.isEmpty ? nil : trimmed
        }
        index.keys[pos].updatedAt = Date()

        do {
            try save(index)
        } catch {
            if secretUpdated, let old = oldSecret {
                try? store.set(id: id, secret: old)
            }
            index.keys[pos] = oldRecord
            throw error
        }
        return index.keys[pos]
    }

    public func updateSecret(id: String, secret: String) throws -> KeyRecord {
        var index = try load()
        guard let pos = index.keys.firstIndex(where: { $0.id == id }) else {
            throw SecretStoreError.notFound(id)
        }
        let trimmed = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        let oldHint = index.keys[pos].hint
        let oldFingerprint = index.keys[pos].fingerprint
        let oldSecret = try store.get(id: id)

        index.keys[pos].hint = Redaction.mask(trimmed)
        index.keys[pos].fingerprint = Fingerprint.short(trimmed)
        index.keys[pos].updatedAt = Date()

        try store.set(id: id, secret: trimmed)
        do {
            try save(index)
        } catch {
            // 全成或全败：索引写失败则把明文恢复成旧值
            if let old = oldSecret { try? store.set(id: id, secret: old) }
            index.keys[pos].hint = oldHint
            index.keys[pos].fingerprint = oldFingerprint
            throw error
        }
        return index.keys[pos]
    }

    public func remove(id: String) throws -> KeyRecord {
        var index = try load()
        guard let pos = index.keys.firstIndex(where: { $0.id == id }) else {
            throw SecretStoreError.notFound(id)
        }
        let record = index.keys.remove(at: pos)
        try save(index)
        try? store.delete(id: id)
        return record
    }

    public func setEnabled(id: String, enabled: Bool) throws -> KeyRecord {
        var index = try load()
        guard let pos = index.keys.firstIndex(where: { $0.id == id }) else {
            throw SecretStoreError.notFound(id)
        }
        index.keys[pos].enabled = enabled
        index.keys[pos].updatedAt = Date()
        try save(index)
        return index.keys[pos]
    }

    public func setPriority(id: String, priority: Int) throws -> KeyRecord {
        var index = try load()
        guard let pos = index.keys.firstIndex(where: { $0.id == id }) else {
            throw SecretStoreError.notFound(id)
        }
        index.keys[pos].priority = priority
        index.keys[pos].updatedAt = Date()
        try save(index)
        return index.keys[pos]
    }

    public func recordCheck(id: String, summary: CheckSummary) throws {
        var index = try load()
        guard let pos = index.keys.firstIndex(where: { $0.id == id }) else { return }
        index.keys[pos].lastCheck = summary
        try save(index)
    }

    public func secret(id: String) throws -> String {
        guard let s = try store.get(id: id) else { throw SecretStoreError.notFound(id) }
        return s
    }

    /// 按「启用状态 → 优先级 → 创建时间」选出最该使用的密钥
    public func preferredKey(providerID: String) throws -> KeyRecord? {
        let candidates = try load().keys
            .filter { $0.providerID == providerID && $0.enabled }
            .sorted { ($0.priority, $0.createdAt) < ($1.priority, $1.createdAt) }
        return candidates.first
    }
}

// MARK: - 审计日志（JSONL 追加写）

public final class AuditLog {
    private let fileURL: URL
    private static let queue = DispatchQueue(label: "com.aki4ever.keyinjector.audit")

    public init(root: URL) {
        self.fileURL = root.appendingPathComponent("audit.jsonl")
    }

    public var path: String { fileURL.path }

    private static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        e.dateEncodingStrategy = .iso8601
        return e
    }

    private static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    public func append(_ entry: AuditEntry) throws {
        let data = try Self.encoder().encode(entry)
        var line = data
        line.append(0x0A)
        try Self.queue.sync {
            let fm = FileManager.default
            try fm.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !fm.fileExists(atPath: fileURL.path) {
                try line.write(to: fileURL, options: [.atomic])
                return
            }
            let handle = try FileHandle(forWritingTo: fileURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: line)
        }
    }

    public func all() -> [AuditEntry] {
        guard let raw = try? String(contentsOf: fileURL, encoding: .utf8) else { return [] }
        let decoder = Self.decoder()
        return raw.split(separator: "\n").compactMap { line in
            guard let data = line.data(using: .utf8) else { return nil }
            return try? decoder.decode(AuditEntry.self, from: data)
        }
    }

    /// 倒序返回最近 n 条
    public func recent(_ limit: Int = 50) -> [AuditEntry] {
        Array(all().suffix(limit).reversed())
    }

    /// 查找某目标最近一次成功写入的备份，用于一键回滚
    public func latestBackup(targetID: String, filePath: String) -> AuditEntry? {
        all().last { $0.action == .inject && $0.targetID == targetID && $0.filePath == filePath && $0.backupPath != nil }
    }
}

// MARK: - 应用设置

public struct AppSettings: Codable, Sendable {
    /// 密钥明文后端：keychain / file / memory
    public var storeBackend: String
    /// 用户自定义的注入落点
    public var customTargets: [InjectionTarget]

    public init(storeBackend: String = "keychain", customTargets: [InjectionTarget] = []) {
        self.storeBackend = storeBackend
        self.customTargets = customTargets
    }
}

public final class SettingsStore {
    private let url: URL
    public init(root: URL) { self.url = root.appendingPathComponent("settings.json") }

    public func load() -> AppSettings {
        guard let data = try? Data(contentsOf: url),
              let s = try? JSONDecoder().decode(AppSettings.self, from: data) else {
            return AppSettings()
        }
        return s
    }

    public func save(_ settings: AppSettings) throws {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try e.encode(settings)
        try AtomicWriter.write(String(decoding: data, as: UTF8.self), to: url)
    }
}
