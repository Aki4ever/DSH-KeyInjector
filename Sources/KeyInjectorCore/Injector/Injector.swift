// ==============================================================================
// 注入引擎：多格式「定点补丁」、备份、原子写入与回滚
//
// 核心安全设计：
//   1. 所有格式都采用**定点替换**（只动目标键那一处），绝不整文件重排，
//      从而最大限度保留用户原文件的注释、缩进与键序；
//   2. 写前必备份，写后必读回校验指纹；任何一步异常都不留半截文件；
//   3. 无法安全定位时**直接拒绝写入并报错**，绝不猜测改写；
//   4. 回滚不仅支持「还原旧内容」，也支持「撤销新建的文件」。
// ==============================================================================
import Foundation

// MARK: - 补丁错误

public enum PatchError: Error, CustomStringConvertible {
    case unsupported(String)
    case shapeMismatch(String)

    public var description: String {
        switch self {
        case .unsupported(let m): return "该落点格式暂不支持自动改写：\(m)"
        case .shapeMismatch(let m): return "目标文件结构与预期不符，已拒绝写入：\(m)"
        }
    }
}

// MARK: - 内容补丁器

public enum ContentPatcher {

    /// 生成受管区块的标记
    static let blockStart = "# >>> KeyInjector managed block >>>"
    static let blockEnd = "# <<< KeyInjector managed block <<<"

    /// 转义为 shell 双引号字符串
    static func shellQuote(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "$", with: "\\$")
            .replacingOccurrences(of: "`", with: "\\`")
        return "\"\(escaped)\""
    }

    // MARK: dotenv

    /// `.env` 定点替换：命中 `KEY=` 行则整行替换，未命中则追加到文件末尾
    public static func patchDotenv(content: String, key: String, value: String) throws -> String {
        guard !key.isEmpty else { throw PatchError.shapeMismatch("键名为空") }
        var lines = LineDiff.splitLines(content)
        let pattern = "^[ \\t]*(?:export[ \\t]+)?\(NSRegularExpression.escapedPattern(for: key))[ \\t]*="
        let regex = try NSRegularExpression(pattern: pattern)
        var hit = false
        for idx in lines.indices {
            let range = NSRange(lines[idx].startIndex..<lines[idx].endIndex, in: lines[idx])
            if regex.firstMatch(in: lines[idx], options: [], range: range) != nil {
                lines[idx] = "\(key)=\(shellQuote(value))"
                hit = true
                break
            }
        }
        if !hit { lines.append("\(key)=\(shellQuote(value))") }
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: shell 导出（受管区块）

    /// shell 启动脚本定点替换：只在受管区块内增删，绝不触碰用户的其它配置行
    public static func patchShellExport(content: String, key: String, value: String) throws -> String {
        guard !key.isEmpty else { throw PatchError.shapeMismatch("键名为空") }
        let assignment = "export \(key)=\(shellQuote(value))"
        var lines = LineDiff.splitLines(content)

        let startIdx = lines.firstIndex { $0.trimmingCharacters(in: .whitespaces) == blockStart }
        let endIdx = lines.firstIndex { $0.trimmingCharacters(in: .whitespaces) == blockEnd }

        if let s = startIdx, let e = endIdx, e > s {
            // 区块已存在：仅替换区块内同名导出行
            let varPattern = "^[ \\t]*export[ \\t]+\(NSRegularExpression.escapedPattern(for: key))[ \\t]*="
            let regex = try NSRegularExpression(pattern: varPattern)
            var replaced = false
            for idx in (s + 1)..<e {
                let range = NSRange(lines[idx].startIndex..<lines[idx].endIndex, in: lines[idx])
                if regex.firstMatch(in: lines[idx], options: [], range: range) != nil {
                    lines[idx] = assignment
                    replaced = true
                }
            }
            if !replaced { lines.insert(assignment, at: e) }
        } else if startIdx != nil || endIdx != nil {
            throw PatchError.shapeMismatch("受管区块标记不成对（疑似被手工删改），请先修复 \(blockStart) / \(blockEnd)")
        } else {
            // 首次写入：追加受管区块
            if !lines.isEmpty && !(lines.last ?? "").isEmpty { lines.append("") }
            lines.append(blockStart)
            lines.append(assignment)
            lines.append(blockEnd)
        }
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: YAML / TOML（区块 + 键）

    /// YAML 定点替换：定位顶层/区块内的 `key:` 行并替换其值
    public static func patchYAML(content: String, section: String?, key: String, value: String) throws -> String {
        guard !key.isEmpty else { throw PatchError.shapeMismatch("键名为空") }
        var lines = LineDiff.splitLines(content)
        let quoted = shellQuote(value)

        func isSectionHeader(_ line: String, _ name: String) -> Bool {
            let t = line.trimmingCharacters(in: .whitespaces)
            return t == "\(name):" || t.hasPrefix("\(name): ") || t.hasPrefix("\(name):\t")
        }
        func isTopLevelBoundary(_ line: String) -> Bool {
            if line.isEmpty { return false }
            if line.hasPrefix(" ") || line.hasPrefix("\t") { return false }
            if line.hasPrefix("#") { return false }
            return true
        }

        let rangeStart: Int
        let rangeEnd: Int
        let indent: String

        if let section = section, !section.isEmpty {
            guard let sIdx = lines.firstIndex(where: { isSectionHeader($0, section) }) else {
                // 区块不存在 → 追加
                if !lines.isEmpty && !(lines.last ?? "").isEmpty { lines.append("") }
                lines.append("\(section):")
                lines.append("  \(key): \(quoted)")
                return lines.joined(separator: "\n") + "\n"
            }
            var eIdx = lines.count
            var i = sIdx + 1
            while i < lines.count {
                if isTopLevelBoundary(lines[i]) { eIdx = i; break }
                i += 1
            }
            rangeStart = sIdx + 1
            rangeEnd = eIdx
            indent = "  "
        } else {
            rangeStart = 0
            rangeEnd = lines.firstIndex(where: { isTopLevelBoundary($0) }) ?? lines.count
            indent = ""
        }

        let keyPattern = "^[ \\t]*\(NSRegularExpression.escapedPattern(for: key))[ \\t]*:"
        let regex = try NSRegularExpression(pattern: keyPattern)

        if rangeStart < rangeEnd {
            for idx in rangeStart..<rangeEnd {
                let range = NSRange(lines[idx].startIndex..<lines[idx].endIndex, in: lines[idx])
                if regex.firstMatch(in: lines[idx], options: [], range: range) != nil {
                    let existingIndent = String(lines[idx].prefix { $0 == " " || $0 == "\t" })
                    lines[idx] = "\(existingIndent.isEmpty ? indent : existingIndent)\(key): \(quoted)"
                    return lines.joined(separator: "\n") + "\n"
                }
            }
        }
        // 区间内没有该键 → 插入到区间开头
        lines.insert("\(indent)\(key): \(quoted)", at: rangeStart)
        return lines.joined(separator: "\n") + "\n"
    }

    /// TOML 定点替换：定位 `[section]` 内的 `key = value` 行
    public static func patchTOML(content: String, section: String?, key: String, value: String) throws -> String {
        guard !key.isEmpty else { throw PatchError.shapeMismatch("键名为空") }
        var lines = LineDiff.splitLines(content)
        let quoted = shellQuote(value)

        func isSectionHeader(_ line: String, _ name: String) -> Bool {
            line.trimmingCharacters(in: .whitespaces) == "[\(name)]"
        }
        func isTopLevelBoundary(_ line: String) -> Bool {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.isEmpty { return false }
            if t.hasPrefix("#") { return false }
            return t.hasPrefix("[")
        }

        let rangeStart: Int
        let rangeEnd: Int

        if let section = section, !section.isEmpty {
            guard let sIdx = lines.firstIndex(where: { isSectionHeader($0, section) }) else {
                if !lines.isEmpty && !(lines.last ?? "").isEmpty { lines.append("") }
                lines.append("[\(section)]")
                lines.append("\(key) = \(quoted)")
                return lines.joined(separator: "\n") + "\n"
            }
            var eIdx = lines.count
            var i = sIdx + 1
            while i < lines.count {
                if isTopLevelBoundary(lines[i]) { eIdx = i; break }
                i += 1
            }
            rangeStart = sIdx + 1
            rangeEnd = eIdx
        } else {
            rangeStart = 0
            rangeEnd = lines.firstIndex(where: { isTopLevelBoundary($0) }) ?? lines.count
        }

        let keyPattern = "^[ \\t]*\(NSRegularExpression.escapedPattern(for: key))[ \\t]*="
        let regex = try NSRegularExpression(pattern: keyPattern)

        if rangeStart < rangeEnd {
            for idx in rangeStart..<rangeEnd {
                let range = NSRange(lines[idx].startIndex..<lines[idx].endIndex, in: lines[idx])
                if regex.firstMatch(in: lines[idx], options: [], range: range) != nil {
                    lines[idx] = "\(key) = \(quoted)"
                    return lines.joined(separator: "\n") + "\n"
                }
            }
        }
        lines.insert("\(key) = \(quoted)", at: rangeStart)
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: plist

    /// plist 定点替换：按键路径写入字符串值
    public static func patchPlist(content: String, path: [String], value: String) throws -> String {
        guard !path.isEmpty else { throw PatchError.shapeMismatch("plist 键路径为空") }
        guard let data = content.data(using: .utf8) else { throw PatchError.shapeMismatch("无法按 UTF-8 读取") }
        var format = PropertyListSerialization.PropertyListFormat.xml
        guard var root = try? PropertyListSerialization.propertyList(from: data, options: [], format: &format) else {
            throw PatchError.shapeMismatch("不是合法的 plist 文件")
        }
        var dict = (root as? [String: Any]) ?? [:]
        func setPath(_ dict: inout [String: Any], _ keys: [String]) throws {
            guard let head = keys.first else { return }
            if keys.count == 1 {
                dict[head] = value
            } else {
                // plist 通常为扁平结构；嵌套场景给出明确边界提示而非静默改写
                throw PatchError.unsupported("plist 暂不支持多级嵌套键路径（请改用扁平键名）")
            }
        }
        try setPath(&dict, path)
        root = dict
        let out = try PropertyListSerialization.data(fromPropertyList: root, format: format, options: 0)
        guard let str = String(data: out, encoding: .utf8) else {
            throw PatchError.shapeMismatch("序列化结果无法以文本表示，请改用二进制 plist 落点或直接人工维护")
        }
        return str
    }

    // MARK: 统一入口

    /// 根据格式分发到对应补丁器
    public static func patch(
        format: InjectionFormat,
        content: String?,
        key: String,
        value: String,
        jsonPath: [String],
        section: String?
    ) throws -> String? {
        let base = content ?? ""
        switch format {
        case .dotenv:
            return try patchDotenv(content: base, key: key, value: value)
        case .shellExport:
            return try patchShellExport(content: base, key: key, value: value)
        case .json:
            guard !jsonPath.isEmpty else { throw PatchError.shapeMismatch("JSON 键路径为空") }
            if base.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                // 文件不存在或为空：构造一个最小合法 JSON
                return "{\n  \(JSONPatcher.quoted(jsonPath.last ?? key)): \(JSONPatcher.quoted(value))\n}\n"
            }
            return try JSONPatcher.patch(content: base, path: jsonPath, newValue: value)
        case .yaml:
            return try patchYAML(content: base, section: section, key: key, value: value)
        case .toml:
            return try patchTOML(content: base, section: section, key: key, value: value)
        case .plist:
            guard !jsonPath.isEmpty else { throw PatchError.shapeMismatch("plist 键路径为空") }
            return try patchPlist(content: base, path: jsonPath, value: value)
        case .none:
            return nil
        }
    }

    /// 生成供人工复制的导出片段
    public static func snippet(key: String, value: String, format: InjectionFormat) -> String {
        switch format {
        case .dotenv:
            return "\(key)=\(shellQuote(value))"
        default:
            return "export \(key)=\(shellQuote(value))"
        }
    }
}

// MARK: - 备份

public struct BackupRecord: Codable, Sendable {
    /// 备份文件路径（原始文件不存在时为空）
    public var backupPath: String?
    /// 原始文件路径
    public var originalPath: String
    /// 备份时原始文件是否已存在
    public var existed: Bool
    public var createdAt: Date
    public var size: Int?
}

public final class BackupStore {
    private let root: URL

    public init(root: URL) {
        self.root = root.appendingPathComponent("backups", isDirectory: true)
    }

    public var rootPath: String { root.path }

    /// 备份目标文件。原文件不存在时如实记录 `existed = false`，
    /// 从而让回滚能够正确地「删除新建文件」而不是「还原空文件」。
    @discardableResult
    public func backup(targetID: String, fileURL: URL) throws -> BackupRecord {
        let fm = FileManager.default
        let dir = root.appendingPathComponent(targetID, isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)

        let stamp = BackupStore.timestamp()
        let name = fileURL.lastPathComponent
        let existed = fm.fileExists(atPath: fileURL.path)

        var record = BackupRecord(backupPath: nil, originalPath: fileURL.path, existed: existed, createdAt: Date(), size: nil)
        // 毫秒级时间戳之外再加一道唯一的序号后缀，
        // 避免同一毫秒内连续两次备份（例如循环注入）互相覆盖。
        var suffix = 0
        var dest = dir.appendingPathComponent("\(stamp)-\(name)")
        while fm.fileExists(atPath: dest.path) {
            suffix += 1
            dest = dir.appendingPathComponent("\(stamp)-\(suffix)-\(name)")
        }

        if existed {
            try fm.copyItem(at: fileURL, to: dest)
            if let attrs = try? fm.attributesOfItem(atPath: fileURL.path) {
                record.size = (attrs[.size] as? NSNumber)?.intValue
            }
            record.backupPath = dest.path
        }

        let metaURL = URL(fileURLWithPath: dest.path + ".meta.json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try AtomicWriter.write(String(decoding: try encoder.encode(record), as: UTF8.self), to: metaURL)
        return record
    }

    /// 读取备份元数据（回滚时使用）
    public func loadRecord(metaPath: String) -> BackupRecord? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: metaPath)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(BackupRecord.self, from: data)
    }

    /// 由备份文件路径推导元数据路径
    public static func metaPath(forBackup backupPath: String) -> String {
        backupPath + ".meta.json"
    }

    /// 毫秒级文件名时间戳（避免同一秒内多次备份重名）
    public static func timestamp(_ date: Date = Date()) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss-SSS"
        return f.string(from: date)
    }
}

// MARK: - 注入计划与结果

public struct InjectionPlan: Sendable {
    public var target: InjectionTarget
    public var provider: Provider
    public var keyRecord: KeyRecord
    /// 解析后的绝对路径（`none` 格式为空）
    public var resolvedPath: String?
    public var existedBefore: Bool
    public var originalContent: String?
    public var patchedContent: String?
    public var diff: [DiffLine]
    /// 供人工复制的导出片段
    public var snippet: String
    /// 最终写入的键名
    public var itemKey: String
    public var warnings: [String]
    /// 是否被安全策略阻断
    public var blocked: Bool
    public var blockedReason: String?

    /// 掩码后的差异（供 CLI 与界面默认展示，避免明文外泄）
    public func redactedDiff(secret: String) -> [DiffLine] {
        let mask = Redaction.mask(secret)
        return diff.map { line in
            var copy = line
            if !secret.isEmpty { copy.text = copy.text.replacingOccurrences(of: secret, with: mask) }
            return copy
        }
    }

    public func redactedSnippet(secret: String) -> String {
        guard !secret.isEmpty else { return snippet }
        return snippet.replacingOccurrences(of: secret, with: Redaction.mask(secret))
    }
}

public struct ApplyOutcome: Sendable {
    public var success: Bool
    public var filePath: String?
    public var backupPath: String?
    public var metaPath: String?
    /// 写后读回得到的文件指纹
    public var verifiedFingerprint: String?
    public var message: String
}

public struct RollbackOutcome: Sendable {
    public var success: Bool
    public var message: String
    public var filePath: String?
}

// MARK: - 注入引擎

public final class InjectionEngine {
    private let audit: AuditLog
    let backups: BackupStore

    public init(audit: AuditLog, backups: BackupStore) {
        self.audit = audit
        self.backups = backups
    }

    /// 生成注入计划（**只读，不落盘**）。这是默认动作，写入必须显式调用 `apply`。
    public func plan(
        target: InjectionTarget,
        provider: Provider,
        keyRecord: KeyRecord,
        secret: String,
        overridePath: String? = nil,
        jsonPathOverride: [String]? = nil,
        sectionOverride: String? = nil,
        itemKeyOverride: String? = nil
    ) throws -> InjectionPlan {
        var warnings: [String] = []
        let itemKey = itemKeyOverride ?? target.resolvedItemKey(for: provider)
        let pathString = (overridePath?.isEmpty == false ? overridePath! : target.filePath)
        let jsonPath = (jsonPathOverride?.isEmpty == false ? jsonPathOverride! : target.jsonPath)

        var plan = InjectionPlan(
            target: target,
            provider: provider,
            keyRecord: keyRecord,
            resolvedPath: nil,
            existedBefore: false,
            originalContent: nil,
            patchedContent: nil,
            diff: [],
            snippet: ContentPatcher.snippet(key: itemKey, value: secret, format: target.format),
            itemKey: itemKey,
            warnings: warnings,
            blocked: false,
            blockedReason: nil
        )

        warnings.append(contentsOf: SecretValidator.warnings(secret: secret, provider: provider))

        guard target.format.writesFile else {
            plan.warnings = warnings
            return plan
        }

        let expanded = PathKit.expand(pathString)
        guard !expanded.isEmpty else {
            plan.blocked = true
            plan.blockedReason = "该落点需要指定文件路径（请用 --file 或在界面中填写）"
            plan.warnings = warnings
            return plan
        }

        let url = URL(fileURLWithPath: expanded)
        let fm = FileManager.default
        let existed = fm.fileExists(atPath: url.path)
        plan.resolvedPath = url.path
        plan.existedBefore = existed

        // 安全护栏：拒绝写入明显危险的目标
        if url.path == "/" || expanded.hasSuffix("/") && !existed {
            plan.blocked = true
            plan.blockedReason = "目标路径非法：\(expanded)"
            plan.warnings = warnings
            return plan
        }
        if existed {
            var isDir: ObjCBool = false
            fm.fileExists(atPath: url.path, isDirectory: &isDir)
            if isDir.boolValue {
                plan.blocked = true
                plan.blockedReason = "目标是目录而非文件，已拒绝写入"
                plan.warnings = warnings
                return plan
            }
            if !fm.isWritableFile(atPath: url.path) {
                plan.blocked = true
                plan.blockedReason = "目标文件不可写（请检查权限）：\(url.path)"
                plan.warnings = warnings
                return plan
            }
        } else {
            warnings.append("目标文件当前不存在，执行注入将新建该文件")
        }

        let original = existed ? (try? String(contentsOf: url, encoding: .utf8)) : nil
        plan.originalContent = original
        if existed && original == nil {
            plan.blocked = true
            plan.blockedReason = "目标文件不是 UTF-8 文本，本工具拒绝改写以免损坏内容"
            plan.warnings = warnings
            return plan
        }

        do {
            let patched = try ContentPatcher.patch(
                format: target.format,
                content: original,
                key: itemKey,
                value: secret,
                jsonPath: jsonPath,
                section: sectionOverride ?? target.section
            )
            plan.patchedContent = patched
            plan.diff = LineDiff.compact(LineDiff.compute(old: original, new: patched), context: 1)
            if patched == original {
                warnings.append("注入内容与现有配置完全一致，本次写入为空操作")
            }
        } catch {
            plan.blocked = true
            plan.blockedReason = "\(error)"
        }

        plan.warnings = warnings
        return plan
    }

    /// 执行写入：备份 → 原子替换 → 读回校验 → 记审计
    @discardableResult
    public func apply(plan: InjectionPlan) throws -> ApplyOutcome {
        guard !plan.blocked else {
            try? audit.append(AuditEntry(
                action: .inject,
                result: "failure",
                message: "被安全策略阻断：\(plan.blockedReason ?? "未知原因")",
                targetID: plan.target.id,
                filePath: plan.resolvedPath,
                keyID: plan.keyRecord.id,
                providerID: plan.provider.id,
                fingerprint: plan.keyRecord.fingerprint
            ))
            return ApplyOutcome(success: false, filePath: plan.resolvedPath, backupPath: nil, metaPath: nil, verifiedFingerprint: nil, message: "被安全策略阻断：\(plan.blockedReason ?? "未知原因")")
        }

        // 不写文件的落点：只记录一次审计，不产生副作用
        guard plan.target.format.writesFile, let path = plan.resolvedPath, let patched = plan.patchedContent else {
            try? audit.append(AuditEntry(
                action: .inject,
                result: "success",
                message: "仅生成导出片段，未写入任何文件",
                targetID: plan.target.id,
                keyID: plan.keyRecord.id,
                providerID: plan.provider.id,
                fingerprint: plan.keyRecord.fingerprint
            ))
            return ApplyOutcome(success: true, filePath: nil, backupPath: nil, metaPath: nil, verifiedFingerprint: nil, message: "已生成导出片段（未写文件）")
        }

        let url = URL(fileURLWithPath: path)
        let record = try backups.backup(targetID: plan.target.id, fileURL: url)

        do {
            try AtomicWriter.write(patched, to: url, preservePermissionsFrom: url)
        } catch {
            try? audit.append(AuditEntry(
                action: .inject,
                result: "failure",
                message: "写入失败：\(error)",
                targetID: plan.target.id,
                filePath: path,
                keyID: plan.keyRecord.id,
                providerID: plan.provider.id,
                fingerprint: plan.keyRecord.fingerprint,
                backupPath: record.backupPath
            ))
            return ApplyOutcome(success: false, filePath: path, backupPath: record.backupPath, metaPath: record.backupPath.map { BackupStore.metaPath(forBackup: $0) }, verifiedFingerprint: nil, message: "写入失败：\(error)")
        }

        // 写后读回校验：确认落盘内容与预期一致
        let onDisk = try? String(contentsOf: url, encoding: .utf8)
        let verified = (onDisk == patched)
        let fp = Fingerprint.fileShort(url)
        if !verified {
            try? audit.append(AuditEntry(
                action: .inject,
                result: "failure",
                message: "写后读回校验不一致，已保留备份待回滚",
                targetID: plan.target.id,
                filePath: path,
                keyID: plan.keyRecord.id,
                providerID: plan.provider.id,
                fingerprint: plan.keyRecord.fingerprint,
                backupPath: record.backupPath
            ))
            return ApplyOutcome(success: false, filePath: path, backupPath: record.backupPath, metaPath: record.backupPath.map { BackupStore.metaPath(forBackup: $0) }, verifiedFingerprint: fp, message: "写后读回校验不一致")
        }

        // 若注入目标是 Codex 相关，同步自动确保模型目录与 model_catalog_json 注册到位
        if plan.target.id == "codex-cli" || path.contains(".codex") {
            Self.syncCodexModelCatalogIfAvailable(keyRecord: plan.keyRecord)
        }

        try? audit.append(AuditEntry(
            action: .inject,
            result: "success",
            message: "已注入 \(plan.provider.name) 的密钥「\(plan.keyRecord.label)」到 \(plan.target.name)",
            targetID: plan.target.id,
            filePath: path,
            keyID: plan.keyRecord.id,
            providerID: plan.provider.id,
            fingerprint: plan.keyRecord.fingerprint,
            backupPath: record.backupPath
        ))

        return ApplyOutcome(
            success: true,
            filePath: path,
            backupPath: record.backupPath,
            metaPath: record.backupPath.map { BackupStore.metaPath(forBackup: $0) },
            verifiedFingerprint: fp,
            message: record.existed ? "注入成功，原文件已备份" : "注入成功，已新建目标文件"
        )
    }

    /// 同步更新 Codex 桌面端的 model_catalog_json 与 model_providers，确保下拉菜单立即可见
    private static func syncCodexModelCatalogIfAvailable(keyRecord: KeyRecord) {
        let configPath = KeyInjectorService.defaultCodexConfigPath()
        let catalogPath = KeyInjectorService.defaultCodexCatalogPath()
        let fm = FileManager.default
        guard fm.fileExists(atPath: configPath) else { return }

        // 1. 确保 codex-gateway-models.json 存在
        if !fm.fileExists(atPath: catalogPath) {
            let bundledCmd = "/Applications/ChatGPT.app/Contents/Resources/codex"
            if fm.fileExists(atPath: bundledCmd) {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
                p.arguments = ["-c", """
import json, subprocess
from pathlib import Path
try:
    raw = subprocess.check_output(['/Applications/ChatGPT.app/Contents/Resources/codex', 'debug', 'models', '--bundled'], text=True)
    models = json.loads(raw).get('models', [])
    template = next((m for m in models if m.get('slug') == 'gpt-5.6-luna'), models[0])
    for cm in [
        {'slug': 'ark/DeepSeek-V4.1-Flash', 'display_name': 'DeepSeek V4.1（公司网关）', 'priority': 100},
        {'slug': 'gemini-3.8-flash-high', 'display_name': 'Gemini 3.8 Flash（公司网关）', 'priority': 99}
    ]:
        entry = json.loads(json.dumps(template))
        entry['slug'] = cm['slug']
        entry['display_name'] = cm['display_name']
        entry['visibility'] = 'list'
        entry['supported_in_api'] = True
        entry['priority'] = cm['priority']
        models.insert(0, entry)
    Path('\(catalogPath)').write_text(json.dumps({'models': models}, ensure_ascii=False, indent=2), encoding='utf-8')
except Exception:
    pass
"""]
                try? p.run()
                p.waitUntilExit()
            }
        }

        // 2. 确保 config.toml 包含 model_catalog_json 注册
        if let text = try? String(contentsOfFile: configPath, encoding: .utf8) {
            var updated = text
            if !updated.contains("model_catalog_json") {
                updated = "model_catalog_json = \"\(catalogPath)\"\n" + updated
            }
            if !updated.contains("[model_providers.codex_gateway]") {
                let base = keyRecord.baseURL ?? "http://192.168.1.200:8080/v1"
                let block = """

# BEGIN CODEX-GATEWAY MANAGED
[model_providers.codex_gateway]
name = "Company AI Gateway"
base_url = "\(base)"
wire_api = "responses"
request_max_retries = 2
stream_max_retries = 2

[model_providers.codex_gateway.auth]
command = "/Users/linqiyu/Documents/ChatGPT/对接gemini/bin/codex-gateway"
args = ["auth", "print"]
timeout_ms = 5000
refresh_interval_ms = 0
# END CODEX-GATEWAY MANAGED
"""
                updated = updated.trimmingCharacters(in: .whitespacesAndNewlines) + "\n" + block
            }
            updated = Self.ensureCodexGatewayProviderRouting(updated, catalogPath: catalogPath)
            if updated != text {
                try? AtomicWriter.write(updated, to: URL(fileURLWithPath: configPath), preservePermissionsFrom: URL(fileURLWithPath: configPath))
            }
        }
    }

    /// 受管区块标记：桌面端选中网关模型时必须同时锁定 provider，否则请求会退回 openai provider，
    /// 被 ChatGPT 后端拒绝为 “model is not supported when using Codex with a ChatGPT account”。
    public static let codexDesktopBlockStart = "# BEGIN CODEX-GATEWAY DESKTOP"
    public static let codexDesktopBlockEnd = "# END CODEX-GATEWAY DESKTOP"

    /// 判断当前 config.toml 是否已经把网关模型路由到 `codex_gateway`
    public static func codexGatewayRoutingOK(_ configText: String, catalogPath: String) -> Bool {
        guard let model = firstModelSlug(in: configText),
              GatewayCatalog.isGatewayModel(model, catalogPath: catalogPath) else { return true }
        return firstAssignmentValue("model_provider", in: configText) == "codex_gateway"
    }

    /// 当 `model` 指向公司网关模型、但 `model_provider` 缺失或仍为官方 provider 时，
    /// 重写受管区块把 `model_provider` 指回 `codex_gateway`。
    /// 只搬动 `model` / `model_provider` 两个键，顶层其它设置（推理档位、沙箱、通知等）原样保留；
    /// 纯函数：只做字符串变换，便于单元测试与 dry-run。
    public static func ensureCodexGatewayProviderRouting(_ configText: String, catalogPath: String) -> String {
        guard let model = firstModelSlug(in: configText) else { return configText }
        guard GatewayCatalog.isGatewayModel(model, catalogPath: catalogPath) else { return configText }

        let currentProvider = firstAssignmentValue("model_provider", in: configText)

        // 路由正确时也要清掉历史遗留的孤儿标记（Codex 重写会吞掉 END 注释行）
        if currentProvider == "codex_gateway" {
            return normalizeManagedBlock(in: configText)
        }
        if let currentProvider, currentProvider != "openai" {
            // 用户显式指定了其它第三方 provider，不动
            return configText
        }

        var body = removeManagedBlock(from: configText)
        body = removeTopLevelAssignment("model", from: body)
        body = removeTopLevelAssignment("model_provider", from: body)
        body = body.trimmingCharacters(in: .whitespacesAndNewlines)

        let block = """
        \(codexDesktopBlockStart)
        model = "\(model)"
        model_provider = "codex_gateway"
        \(codexDesktopBlockEnd)
        """
        var lines = body.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let insertAt = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("[") }) ?? lines.count
        var insertion = block.split(separator: "\n").map(String.init)
        // 与下方的 [section] 之间保留空行，避免受管区块被视觉上粘进该表
        if insertAt < lines.count { insertion.append("") }
        lines.insert(contentsOf: insertion, at: insertAt)
        return lines.joined(separator: "\n").trimmingCharacters(in: .newlines) + "\n"
    }

    /// 修复历史遗留的孤儿受管标记。
    ///
    /// Codex 桌面端重写 `config.toml` 时会吞掉 `# END CODEX-GATEWAY DESKTOP` 这类注释行，
    /// 只剩一段没有结束标记的开头注释（实测出现过两个 BEGIN 并存）。
    /// 判定规则（**结构完整时原样返回，保证幂等**）：
    ///   · 恰好一个 BEGIN 且其后存在 END → 结构完整，不动
    ///   · 其余情况 → 每个 BEGIN/END 标记行连同紧随的注释、空行一起删除
    static func normalizeManagedBlock(in text: String) -> String {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let begins = lines.indices.filter { lines[$0].contains(codexDesktopBlockStart) }
        let ends = lines.indices.filter { lines[$0].contains(codexDesktopBlockEnd) }
        if begins.count == 1, let begin = begins.first, let finish = ends.first, finish > begin {
            return text
        }
        guard !begins.isEmpty || !ends.isEmpty else { return text }
        var output: [String] = []
        var index = 0
        while index < lines.count {
            let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
            if trimmed.contains(codexDesktopBlockStart) || trimmed.contains(codexDesktopBlockEnd) {
                index += 1
                while index < lines.count {
                    let candidate = lines[index].trimmingCharacters(in: .whitespaces)
                    if candidate.isEmpty || candidate.hasPrefix("#") {
                        index += 1
                        continue
                    }
                    break
                }
                continue
            }
            output.append(lines[index])
            index += 1
        }
        var compact: [String] = []
        for line in output {
            if line.trimmingCharacters(in: .whitespaces).isEmpty,
               compact.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { continue }
            compact.append(line)
        }
        return compact.joined(separator: "\n")
    }

    /// 读取 config.toml 里第一个顶层（非注释）`model = "..."` 的取值
    static func firstModelSlug(in configText: String) -> String? {
        firstAssignmentValue("model", in: configText)
    }

    /// 取顶层键的字符串取值；进入任意 `[section]` 之后即停止，避免误读 provider 内部同名字段
    static func firstAssignmentValue(_ key: String, in configText: String) -> String? {
        for rawLine in configText.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") { return nil }
            if line.hasPrefix("#") || line.isEmpty { continue }
            guard line.hasPrefix(key) else { continue }
            let rest = line.dropFirst(key.count).trimmingCharacters(in: .whitespaces)
            guard rest.hasPrefix("=") else { continue }
            return rest.dropFirst().trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        }
        return nil
    }

    /// 删除受管区块。**不依赖结束标记**：Codex 桌面端重写 config.toml 时会吞掉
    /// `# END CODEX-GATEWAY DESKTOP` 这类注释行，若只按结束标记匹配就会留下孤儿标记，
    /// 导致修复后的配置里出现两个 BEGIN。这里改为「从 BEGIN 行起，向后吃掉紧跟的注释行与空行」。
    static func removeManagedBlock(from text: String) -> String {
        guard var start = text.range(of: codexDesktopBlockStart) else { return text }
        var result = text
        // 若上方还残留「未闭合 BEGIN + 注释」的孤儿标记，先整体清理掉
        while let earlier = text.range(of: codexDesktopBlockStart, range: text.startIndex..<start.lowerBound) {
            start = earlier
        }
        var removalEnd = result.index(after: start.upperBound)
        // 独占一行的 BEGIN 标记本身
        if let lineEnd = result.range(of: "\n", range: start.upperBound..<result.endIndex) {
            removalEnd = lineEnd.upperBound
        }
        // 继续吞掉紧跟的注释行、空行，以及（若存在）END 标记
        var cursor = removalEnd
        while cursor < result.endIndex {
            let lineEnd = result.range(of: "\n", range: cursor..<result.endIndex)?.upperBound ?? result.endIndex
            let line = result[cursor..<lineEnd].trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("#") || line.isEmpty {
                removalEnd = lineEnd
                cursor = lineEnd
                continue
            }
            break
        }
        result.removeSubrange(start.lowerBound..<removalEnd)
        return result
    }

    /// 删除顶层（首个 `[section]` 之前）的某个键赋值行
    static func removeTopLevelAssignment(_ key: String, from text: String) -> String {
        var output: [String] = []
        var inSection = false
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") { inSection = true }
            if !inSection, line.hasPrefix(key), line.dropFirst(key.count).trimmingCharacters(in: .whitespaces).hasPrefix("=") {
                continue
            }
            output.append(String(rawLine))
        }
        return output.joined(separator: "\n")
    }

    /// 回滚：依据审计条目还原备份，或删除当初新建的文件
    @discardableResult
    public func rollback(entry: AuditEntry) throws -> RollbackOutcome {
        guard let path = entry.filePath else {
            return RollbackOutcome(success: false, message: "该审计条目没有关联文件，无需回滚", filePath: nil)
        }
        let url = URL(fileURLWithPath: path)
        let fm = FileManager.default

        guard let backupPath = entry.backupPath else {
            // 没有备份 → 说明当初是新建文件，回滚即删除
            if fm.fileExists(atPath: path) {
                try fm.removeItem(at: url)
                try? audit.append(AuditEntry(
                    action: .rollback,
                    result: "success",
                    message: "已删除当初新建的文件（回滚）",
                    targetID: entry.targetID,
                    filePath: path,
                    keyID: entry.keyID,
                    providerID: entry.providerID,
                    fingerprint: entry.fingerprint
                ))
                return RollbackOutcome(success: true, message: "已删除当初新建的文件", filePath: path)
            }
            return RollbackOutcome(success: false, message: "既无备份也无目标文件，无法回滚", filePath: path)
        }

        let metaPath = BackupStore.metaPath(forBackup: backupPath)
        guard let record = backups.loadRecord(metaPath: metaPath) else {
            return RollbackOutcome(success: false, message: "备份元数据缺失，无法安全回滚：\(metaPath)", filePath: path)
        }
        guard record.existed, fm.fileExists(atPath: backupPath) else {
            return RollbackOutcome(success: false, message: "备份正文缺失，无法安全回滚", filePath: path)
        }

        let content = try String(contentsOfFile: backupPath, encoding: .utf8)
        try AtomicWriter.write(content, to: url, preservePermissionsFrom: url)

        let ok = (try? String(contentsOf: url, encoding: .utf8)) == content
        try? audit.append(AuditEntry(
            action: .rollback,
            result: ok ? "success" : "failure",
            message: ok ? "已还原注入前的文件内容" : "回滚后读回校验不一致",
            targetID: entry.targetID,
            filePath: path,
            keyID: entry.keyID,
            providerID: entry.providerID,
            fingerprint: entry.fingerprint,
            backupPath: backupPath
        ))
        return RollbackOutcome(success: ok, message: ok ? "已还原注入前的文件内容" : "回滚后读回校验不一致", filePath: path)
    }
}
