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

        // 幂等护栏：YAML 里 `KEY: sk-xxx` 与 `KEY: "sk-xxx"` 是同一个值。
        // 若只比较原始行文本，本工具会给一个「值没变、只是加了引号」的行制造假差异，
        // 并让注入结果看起来像一次空操作写入。这里先把既有值的引号剥掉再比较。
        func unquotedExistingValue(_ line: String) -> String {
            guard let colon = line.firstIndex(of: ":") else { return "" }
            var v = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            if let hash = v.firstIndex(of: "#"), !v.hasPrefix("\"") {
                v = String(v[v.startIndex..<hash]).trimmingCharacters(in: .whitespaces)
            }
            if v.count >= 2, v.hasPrefix("\""), v.hasSuffix("\"") {
                v = String(v.dropFirst().dropLast())
            } else if v.count >= 2, v.hasPrefix("'"), v.hasSuffix("'") {
                v = String(v.dropFirst().dropLast())
            }
            return v
        }

        if rangeStart < rangeEnd {
            for idx in rangeStart..<rangeEnd {
                let range = NSRange(lines[idx].startIndex..<lines[idx].endIndex, in: lines[idx])
                if regex.firstMatch(in: lines[idx], options: [], range: range) != nil {
                    // 值本就相同（忽略引号差异）时原样返回，避免「空操作注入」污染历史与备份
                    if unquotedExistingValue(lines[idx]) == value { return content }
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
    /// 该密钥供给的宿主模型（由服务层写入；dry-run 阶段即可核对）
    public var suppliedModels: [HostModelInventory.Binding] = []

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
    ///
    /// v1.4.0 起模型清单与网关地址**不再硬编码**：全部取自网关自己的配置
    /// （`~/.config/codex-gateway/config.json`，见 `GatewayConfig`）。
    /// 此前的实现内嵌了一段 Python 并写死两个 slug 与绝对路径，
    /// 导致「网关新增模型」必须改代码、换机器时路径失效。
    private static func syncCodexModelCatalogIfAvailable(keyRecord: KeyRecord) {
        let configPath = KeyInjectorService.defaultCodexConfigPath()
        let catalogPath = KeyInjectorService.defaultCodexCatalogPath()
        let fm = FileManager.default
        guard fm.fileExists(atPath: configPath) else { return }

        let existingConfig = try? String(contentsOfFile: configPath, encoding: .utf8)
        let gateway = GatewayConfig.loadOrEmpty()

        // 1. 确保 codex-gateway-models.json 里有网关声明的全部模型
        let existingEntries = CodexCatalogStore.allRaw(path: catalogPath)
        if let outcome = try? HostConfigSync.syncCodexCatalog(gateway: gateway, existingEntries: existingEntries),
           outcome.changed {
            try? CodexCatalogStore.write(outcome.entries, path: catalogPath)
        } else if existingEntries.isEmpty, fm.fileExists(atPath: catalogPath) {
            // 目录存在但读不出条目：不去编造内容，留给显式同步处理
        }

        // 2. 确保 config.toml 包含 model_catalog_json 注册与网关 provider 段
        if let text = existingConfig {
            var updated = text
            if !updated.contains("model_catalog_json") {
                updated = "model_catalog_json = \"\(catalogPath)\"\n" + updated
            }
            if !updated.contains("[model_providers.codex_gateway]") {
                // 地址与二进制路径优先取网关配置；两者都拿不到时如实用密钥里的自定义地址，
                // 仍然拿不到就跳过写入——绝不写一个猜出来的地址进用户配置。
                let base = gateway.baseURL.isEmpty ? (keyRecord.baseURL ?? "") : gateway.baseURL
                let binary = GatewayConfig.binaryPath(codexConfigText: updated)
                if !base.isEmpty, let binary {
                    let block = """

# BEGIN CODEX-GATEWAY MANAGED
[model_providers.codex_gateway]
name = "Company AI Gateway"
base_url = "\(base)"
wire_api = "responses"
request_max_retries = 6
stream_max_retries = 6

[model_providers.codex_gateway.auth]
command = "\(binary)"
args = ["auth", "print"]
timeout_ms = 5000
refresh_interval_ms = 0
# END CODEX-GATEWAY MANAGED
"""
                    updated = updated.trimmingCharacters(in: .whitespacesAndNewlines) + "\n" + block
                }
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

        var body = strippedOfManagedMarkers(configText)
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

    /// 把 Codex 配置里的 `model` 定为指定值，并确保 `model_provider = codex_gateway`。
    ///
    /// 与 `ensureCodexGatewayProviderRouting` 的区别：后者只在「当前模型属于网关」时才动手
    /// （守护场景必须保守），本函数是用户显式点名要换模型，因此主动改写。
    /// 依然只搬动 `model` 与 `model_provider` 两个键，其余设置字节不动。
    public static func setCodexGatewayModel(_ model: String, in configText: String) -> String {
        var body = strippedOfManagedMarkers(configText)
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
        // 插到第一个 `[section]` 之前，与既有受管区块的位置保持一致
        let insertAt = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("[") }) ?? lines.count
        var insertion = block.split(separator: "\n").map(String.init)
        if insertAt < lines.count { insertion.append("") }
        lines.insert(contentsOf: insertion, at: insertAt)
        return lines.joined(separator: "\n").trimmingCharacters(in: .newlines) + "\n"
    }

    /// 清掉成段的孤儿 `# END` 标记。
    ///
    /// 只处理「标记行」本身：连续出现的纯标记行会被整段删除；
    /// 一行里既有标记又有别的内容时不动它（宁可少删也不误删）。
    /// 清掉孤儿 `# END` 标记，并把受管区块整体剥掉（含 BEGIN/END 与块内内容）。
    ///
    /// `setCodexGatewayModel` 用「先剥干净、再重建一个干净区块」的方式保证幂等：
    /// 而不是去猜哪些标记是孤儿——真实形态 `END / BEGIN / 内容 / END` 证明猜测法不可靠
    /// （实测删掉「正确」的那个反而留下一个没有 BEGIN 的 END）。
    /// 区块内只有 `model` 与 `model_provider` 两行，且都会立刻被重建，
    /// 因此「整体剥掉」不会丢任何用户设置。
    static func strippedOfManagedMarkers(_ text: String) -> String {
        let lines = text.components(separatedBy: "\n")
        var kept: [String] = []
        var insideBlock = false
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == codexDesktopBlockStart {
                // 孤儿 BEGIN（后面没有 END）只能删到「BEGIN 行 + 紧跟的注释行」，
                // 因为块内那两行 `model` / `model_provider` 由 removeTopLevelAssignment 处理，
                // 而更后面的内容很可能是用户自己的 [section] 设置——绝不能一并吞掉。
                insideBlock = true
                continue
            }
            if trimmed == codexDesktopBlockEnd {
                insideBlock = false
                continue
            }
            if insideBlock {
                // 只跳过注释与被托管的赋值行，遇到 section 或其它设置立即退出块状态
                if trimmed.hasPrefix("#") || trimmed.hasPrefix("model =") || trimmed.hasPrefix("model_provider =") {
                    continue
                }
                insideBlock = false
            }
            kept.append(line)
        }
        return kept.joined(separator: "\n")
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
        // 先剥掉成对的受管区块（含块内的 model/model_provider），
        // 剩下的孤儿标记由下面的循环按保守口径处理。
        let lines = strippedOfManagedMarkers(text).components(separatedBy: "\n")
        guard let begin = lines.firstIndex(where: {
            $0.trimmingCharacters(in: .whitespaces) == codexDesktopBlockStart
        }) else { return lines.joined(separator: "\n") }

        // 孤儿 BEGIN：连它后面紧跟的注释行一起移除（块内的赋值行由 removeTopLevelAssignment 清理）
        var removalEnd = begin + 1
        while removalEnd < lines.count,
              lines[removalEnd].trimmingCharacters(in: .whitespaces).hasPrefix("#") {
            removalEnd += 1
        }
        var kept = lines
        kept.removeSubrange(begin..<removalEnd)
        return kept.joined(separator: "\n")
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
