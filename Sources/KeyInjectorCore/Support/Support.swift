// ==============================================================================
// 通用支撑：指纹、掩码、路径、行级差异、JSON 定点扫描器、原子写入
// ==============================================================================
import Foundation
import CryptoKit

// MARK: - 指纹

public enum Fingerprint {
    /// 计算字符串的 SHA-256 短指纹（前 8 位十六进制）
    public static func short(_ text: String) -> String {
        let digest = SHA256.hash(data: Data(text.utf8))
        return digest.map { String(format: "%02x", $0) }.joined().prefix(8).description
    }

    /// 计算文件的 SHA-256 短指纹，用于「写后读回」校验
    public static func fileShort(_ url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined().prefix(8).description
    }

    /// 计算数据的 SHA-256 全量十六进制
    public static func full(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - 掩码与预检

public enum Redaction {
    /// 将密钥掩码为不可还原的提示串
    public static func mask(_ secret: String) -> String {
        let s = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.count <= 6 { return "…" }
        if s.count < 12 {
            return "\(s.prefix(2))…\(s.suffix(2))"
        }
        return "\(s.prefix(4))…\(s.suffix(4))"
    }
}

public enum SecretValidator {
    /// 对录入的密钥做轻量格式预检，返回警告列表（空列表表示没有发现问题）。
    /// 注意：这里**只做提示不做阻断**，因为自定义网关的密钥格式千差万别。
    public static func warnings(secret: String, provider: Provider) -> [String] {
        var out: [String] = []
        let s = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { return ["密钥内容为空"] }
        if s != secret { out.append("密钥首尾含空白字符，已自动去除后保存") }
        if s.contains(" ") || s.contains("\n") { out.append("密钥中间含空格或换行，疑似复制错误") }
        if s.count < 16 { out.append("密钥长度短于 16 字符，多数厂商密钥不会这么短") }
        if !provider.secretPrefixes.isEmpty {
            let ok = provider.secretPrefixes.contains { s.hasPrefix($0) }
            if !ok {
                out.append("该厂商密钥通常以 \(provider.secretPrefixes.joined(separator: " / ")) 开头，请复核是否贴错")
            }
        }
        return out
    }
}

// MARK: - 路径工具

public enum PathKit {
    /// 展开 `~` 与 `$HOME`，并标准化为绝对路径
    public static func expand(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return s }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if s == "~" { s = home }
        else if s.hasPrefix("~/") { s = home + String(s.dropFirst(1)) }
        s = s.replacingOccurrences(of: "$HOME", with: home)
        return (s as NSString).standardizingPath
    }

    /// 默认应用数据目录：`~/Library/Application Support/KeyInjector`
    public static func defaultSupportDirectory() -> URL {
        if let env = ProcessInfo.processInfo.environment["KEYINJECTOR_HOME"], !env.isEmpty {
            return URL(fileURLWithPath: expand(env), isDirectory: true)
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("KeyInjector", isDirectory: true)
    }
}

// MARK: - 行级差异（LCS 动态规划）

public struct DiffLine: Hashable, Sendable {
    public enum Kind: String, Sendable { case context = " ", added = "+", removed = "-" }
    public var kind: Kind
    public var text: String
    public var oldLineNo: Int?
    public var newLineNo: Int?

    public init(kind: Kind, text: String, oldLineNo: Int? = nil, newLineNo: Int? = nil) {
        self.kind = kind
        self.text = text
        self.oldLineNo = oldLineNo
        self.newLineNo = newLineNo
    }

    /// 便于 CLI 与 GUI 统一渲染
    public var rendered: String { "\(kind.rawValue) \(text)" }
}

public enum LineDiff {
    /// 计算两段文本的行级差异。为控制内存，仅对 4000 行以内的文本做精确 LCS，
    /// 超出时退化为「整块替换」表示。
    public static func compute(old: String?, new: String?) -> [DiffLine] {
        let oldLines = splitLines(old ?? "")
        let newLines = splitLines(new ?? "")

        if oldLines.count > 4000 || newLines.count > 4000 {
            var out: [DiffLine] = []
            out.append(contentsOf: oldLines.enumerated().map { DiffLine(kind: .removed, text: $0.element, oldLineNo: $0.offset + 1) })
            out.append(contentsOf: newLines.enumerated().map { DiffLine(kind: .added, text: $0.element, newLineNo: $0.offset + 1) })
            return out
        }

        // LCS 长度表
        let n = oldLines.count, m = newLines.count
        var dp = [[Int]](repeating: [Int](repeating: 0, count: m + 1), count: n + 1)
        if n > 0 && m > 0 {
            for i in stride(from: n - 1, through: 0, by: -1) {
                for j in stride(from: m - 1, through: 0, by: -1) {
                    dp[i][j] = oldLines[i] == newLines[j]
                        ? dp[i + 1][j + 1] + 1
                        : max(dp[i + 1][j], dp[i][j + 1])
                }
            }
        }

        var out: [DiffLine] = []
        var i = 0, j = 0
        while i < n && j < m {
            if oldLines[i] == newLines[j] {
                out.append(DiffLine(kind: .context, text: oldLines[i], oldLineNo: i + 1, newLineNo: j + 1))
                i += 1; j += 1
            } else if dp[i + 1][j] >= dp[i][j + 1] {
                out.append(DiffLine(kind: .removed, text: oldLines[i], oldLineNo: i + 1))
                i += 1
            } else {
                out.append(DiffLine(kind: .added, text: newLines[j], newLineNo: j + 1))
                j += 1
            }
        }
        while i < n { out.append(DiffLine(kind: .removed, text: oldLines[i], oldLineNo: i + 1)); i += 1 }
        while j < m { out.append(DiffLine(kind: .added, text: newLines[j], newLineNo: j + 1)); j += 1 }
        return out
    }

    /// 折叠输出：仅保留变更行及其上下 1 行上下文，返回携带跳过标记的结果
    public static func compact(_ lines: [DiffLine], context: Int = 1) -> [DiffLine] {
        var keep = Set<Int>()
        for (idx, line) in lines.enumerated() where line.kind != .context {
            for k in max(0, idx - context)...min(lines.count - 1, idx + context) { keep.insert(k) }
        }
        var out: [DiffLine] = []
        var lastKept = -2
        for (idx, line) in lines.enumerated() {
            if keep.contains(idx) {
                if idx - lastKept > 1 {
                    out.append(DiffLine(kind: .context, text: "…（省略 \(idx - lastKept - 1) 行未变更内容）"))
                }
                out.append(line)
                lastKept = idx
            }
        }
        return out
    }

    static func splitLines(_ text: String) -> [String] {
        if text.isEmpty { return [] }
        var lines = text.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        return lines
    }
}

// MARK: - JSON 定点扫描器（保留原文件缩进与键序，只替换目标值）

public enum JSONNode {
    case object([(key: String, value: JSONNode)])
    case array([JSONNode])
    case string(String, Range<Int>)
    case number(String, Range<Int>)
    case bool(Bool, Range<Int>)
    case null(Range<Int>)

    /// 该节点在原始字节流中的范围（含引号）
    public var range: Range<Int> {
        switch self {
        case .object: return 0..<0
        case .array: return 0..<0
        case .string(_, let r), .number(_, let r), .bool(_, let r), .null(let r): return r
        }
    }

    public func child(_ key: String) -> JSONNode? {
        if case .object(let pairs) = self {
            return pairs.first { $0.key == key }?.value
        }
        return nil
    }

    public func lookup(_ path: [String]) -> JSONNode? {
        var node: JSONNode? = self
        for key in path {
            guard let cur = node else { return nil }
            if case .array(let items) = cur, let idx = Int(key), idx >= 0, idx < items.count {
                node = items[idx]
            } else {
                node = cur.child(key)
            }
        }
        return node
    }
}

public enum JSONPatchError: Error, CustomStringConvertible {
    case parseFailed(String)
    case pathNotFound([String])
    case pathIsNotValue([String])
    case parentMissing([String])

    public var description: String {
        switch self {
        case .parseFailed(let m): return "JSON 解析失败：\(m)"
        case .pathNotFound(let p): return "未找到键路径 \(p.joined(separator: "."))"
        case .pathIsNotValue(let p): return "键路径 \(p.joined(separator: ".")) 指向的是容器而非单值，拒绝改写"
        case .parentMissing(let p): return "上级路径 \(p.joined(separator: ".")) 不存在，拒绝自动新建（避免破坏原文件结构）"
        }
    }
}

/// 极简 JSON 解析器：只负责定位「某个键路径对应值的字节区间」，
/// 从而在不重排键序、不改动缩进的前提下做定点替换。
struct JSONScanner {
    private let bytes: [UInt8]
    private var i = 0

    init(_ text: String) { self.bytes = Array(text.utf8) }

    static func parse(_ text: String) throws -> JSONNode {
        var scanner = JSONScanner(text)
        scanner.skipWhitespace()
        let node = try scanner.parseValue()
        return node
    }

    private mutating func skipWhitespace() {
        while i < bytes.count {
            let c = bytes[i]
            if c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D { i += 1 } else { break }
        }
    }

    private mutating func parseValue() throws -> JSONNode {
        skipWhitespace()
        guard i < bytes.count else { throw JSONPatchError.parseFailed("内容意外结束") }
        switch bytes[i] {
        case UInt8(ascii: "{"): return try parseObject()
        case UInt8(ascii: "["): return try parseArray()
        case UInt8(ascii: "\""):
            let start = i
            let s = try parseString()
            return .string(s, start..<i)
        case UInt8(ascii: "t"), UInt8(ascii: "f"):
            let start = i
            let lit = try parseLiteral()
            return .bool(lit == "true", start..<i)
        case UInt8(ascii: "n"):
            let start = i
            _ = try parseLiteral()
            return .null(start..<i)
        default:
            let start = i
            let num = try parseNumber()
            return .number(num, start..<i)
        }
    }

    private mutating func parseObject() throws -> JSONNode {
        i += 1 // 跳过 '{'
        var pairs: [(key: String, value: JSONNode)] = []
        skipWhitespace()
        if i < bytes.count && bytes[i] == UInt8(ascii: "}") { i += 1; return .object(pairs) }
        while true {
            skipWhitespace()
            guard i < bytes.count, bytes[i] == UInt8(ascii: "\"") else {
                throw JSONPatchError.parseFailed("对象键必须是字符串（偏移 \(i)）")
            }
            let key = try parseString()
            skipWhitespace()
            guard i < bytes.count, bytes[i] == UInt8(ascii: ":") else {
                throw JSONPatchError.parseFailed("对象键后缺少冒号（偏移 \(i)）")
            }
            i += 1
            let value = try parseValue()
            pairs.append((key, value))
            skipWhitespace()
            guard i < bytes.count else { throw JSONPatchError.parseFailed("对象未闭合") }
            if bytes[i] == UInt8(ascii: ",") { i += 1; continue }
            if bytes[i] == UInt8(ascii: "}") { i += 1; break }
            throw JSONPatchError.parseFailed("对象中出现意外字符（偏移 \(i)）")
        }
        return .object(pairs)
    }

    private mutating func parseArray() throws -> JSONNode {
        i += 1 // 跳过 '['
        var items: [JSONNode] = []
        skipWhitespace()
        if i < bytes.count && bytes[i] == UInt8(ascii: "]") { i += 1; return .array(items) }
        while true {
            let value = try parseValue()
            items.append(value)
            skipWhitespace()
            guard i < bytes.count else { throw JSONPatchError.parseFailed("数组未闭合") }
            if bytes[i] == UInt8(ascii: ",") { i += 1; continue }
            if bytes[i] == UInt8(ascii: "]") { i += 1; break }
            throw JSONPatchError.parseFailed("数组中出现意外字符（偏移 \(i)）")
        }
        return .array(items)
    }

    private mutating func parseString() throws -> String {
        i += 1 // 跳过起始引号
        var out: [UInt8] = []
        while i < bytes.count {
            let c = bytes[i]
            if c == UInt8(ascii: "\"") { i += 1; return String(decoding: out, as: UTF8.self) }
            if c == UInt8(ascii: "\\") {
                i += 1
                guard i < bytes.count else { throw JSONPatchError.parseFailed("转义序列不完整") }
                let e = bytes[i]
                switch e {
                case UInt8(ascii: "n"): out.append(0x0A)
                case UInt8(ascii: "t"): out.append(0x09)
                case UInt8(ascii: "r"): out.append(0x0D)
                case UInt8(ascii: "b"): out.append(0x08)
                case UInt8(ascii: "f"): out.append(0x0C)
                case UInt8(ascii: "\""): out.append(UInt8(ascii: "\""))
                case UInt8(ascii: "\\"): out.append(UInt8(ascii: "\\"))
                case UInt8(ascii: "/"): out.append(UInt8(ascii: "/"))
                case UInt8(ascii: "u"):
                    guard i + 4 < bytes.count else { throw JSONPatchError.parseFailed("\\u 转义不完整") }
                    let hex = String(decoding: bytes[(i + 1)...(i + 4)], as: UTF8.self)
                    guard let code = UInt32(hex, radix: 16) else { throw JSONPatchError.parseFailed("非法 \\u 转义：\(hex)") }
                    out.append(contentsOf: Array(String(UnicodeScalar(code) ?? "?").utf8))
                    i += 4
                default:
                    out.append(e)
                }
                i += 1
                continue
            }
            out.append(c)
            i += 1
        }
        throw JSONPatchError.parseFailed("字符串未闭合")
    }

    private mutating func parseLiteral() throws -> String {
        let start = i
        while i < bytes.count {
            let c = bytes[i]
            if (c >= UInt8(ascii: "a") && c <= UInt8(ascii: "z")) { i += 1 } else { break }
        }
        return String(decoding: bytes[start..<i], as: UTF8.self)
    }

    private mutating func parseNumber() throws -> String {
        let start = i
        let allowed = Set("-+.eE0123456789".utf8)
        while i < bytes.count, allowed.contains(bytes[i]) { i += 1 }
        guard i > start else { throw JSONPatchError.parseFailed("非法数字（偏移 \(start)）") }
        return String(decoding: bytes[start..<i], as: UTF8.self)
    }
}

public enum JSONPatcher {
    /// 生成符合 JSON 规范的字符串字面量（含首尾引号）
    public static func quoted(_ value: String) -> String {
        var out = "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\t": out += "\\t"
            case "\r": out += "\\r"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out + "\""
    }

    /// 在 JSON 文本中定位 `path` 的值并定点替换。
    /// - 只在键路径**已存在**时替换；路径不存在时抛出 `.pathNotFound`，
    ///   绝不擅自新建嵌套结构，以免破坏第三方的配置文件。
    public static func patch(content: String, path: [String], newValue: String) throws -> String {
        guard !path.isEmpty else { throw JSONPatchError.parentMissing(path) }
        let root = try JSONScanner.parse(content)
        guard let node = root.lookup(path) else { throw JSONPatchError.pathNotFound(path) }
        let r = node.range
        guard r.count > 0 else { throw JSONPatchError.pathIsNotValue(path) }

        var bytes = Array(content.utf8)
        let replacement = Array(quoted(newValue).utf8)
        bytes.replaceSubrange(r, with: replacement)
        return String(decoding: bytes, as: UTF8.self)
    }

    /// 读取某个键路径当前的字符串值（用于回滚前比对与展示）
    public static func readString(content: String, path: [String]) -> String? {
        guard let root = try? JSONScanner.parse(content) else { return nil }
        guard let node = root.lookup(path) else { return nil }
        if case .string(let s, _) = node { return s }
        return nil
    }
}

// MARK: - 原子写入

public enum AtomicWriteError: Error, CustomStringConvertible {
    case tempCreateFailed(String)
    case replaceFailed(String)
    case permissionFailed(String)

    public var description: String {
        switch self {
        case .tempCreateFailed(let m): return "临时文件创建失败：\(m)"
        case .replaceFailed(let m): return "原子替换失败：\(m)"
        case .permissionFailed(let m): return "权限设置失败：\(m)"
        }
    }
}

public enum AtomicWriter {
    /// 原子写入：先写同目录临时文件 → 落盘同步 → `replaceItemAt` 原子替换。
    /// 任何一步失败都不会留下半截目标文件（要么全新，要么保持原样）。
    /// - Parameter preservePermissionsFrom: 若目标文件已存在，沿用其权限位
    public static func write(_ content: String, to url: URL, preservePermissionsFrom existing: URL? = nil) throws {
        let fm = FileManager.default
        let dir = url.deletingLastPathComponent()
        if !fm.fileExists(atPath: dir.path) {
            do {
                try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            } catch {
                throw AtomicWriteError.tempCreateFailed("无法创建目录 \(dir.path)：\(error.localizedDescription)")
            }
        }

        let tmp = dir.appendingPathComponent(".keyinjector-\(UUID().uuidString).tmp")
        let data = Data(content.utf8)

        do {
            try data.write(to: tmp, options: .atomic)
        } catch {
            throw AtomicWriteError.tempCreateFailed(error.localizedDescription)
        }

        // 落盘同步，确保崩溃/断电时不出现空文件
        if let handle = try? FileHandle(forWritingTo: tmp) {
            try? handle.synchronize()
            try? handle.close()
        }

        // 沿用原文件权限，避免注入后权限被改成默认值
        if let src = existing, fm.fileExists(atPath: src.path) {
            if let attrs = try? fm.attributesOfItem(atPath: src.path),
               let perms = attrs[.posixPermissions] as? NSNumber {
                try? fm.setAttributes([.posixPermissions: perms], ofItemAtPath: tmp.path)
            }
        }

        if fm.fileExists(atPath: url.path) {
            do {
                _ = try fm.replaceItemAt(url, withItemAt: tmp)
            } catch {
                try? fm.removeItem(at: tmp)
                throw AtomicWriteError.replaceFailed(error.localizedDescription)
            }
        } else {
            do {
                try fm.moveItem(at: tmp, to: url)
            } catch {
                try? fm.removeItem(at: tmp)
                throw AtomicWriteError.replaceFailed(error.localizedDescription)
            }
        }
    }
}
