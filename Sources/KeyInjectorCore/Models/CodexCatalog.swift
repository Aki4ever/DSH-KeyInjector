// ==============================================================================
// Codex 模型目录读写
//
// `~/.codex/codex-gateway-models.json` 是 Codex 桌面端顶部模型菜单的唯一数据源，
// 由 `model_catalog_json` 指向。目录里同时存在两类条目：
//   · 官方条目（GPT-5.x 等）—— 来自 Codex 自带的 `codex debug models --bundled`
//   · 公司网关条目（DeepSeek / Gemini）—— 由本工具或本机 codex-gateway 注册
// 本文件负责「列出来源、可视化增删、切换是否出现在菜单里」，让模型清单不再黑箱。
// ==============================================================================
import Foundation

/// 目录中的一个模型条目（只保留可视化需要的字段）
public struct CodexCatalogEntry {
    public var slug: String
    public var displayName: String
    public var description: String
    /// 是否为「公司网关」条目（display_name / description 命中网关标记词）
    public var isGateway: Bool
    /// 是否出现在桌面端模型菜单里（visibility == "list"）
    public var inPicker: Bool
    /// 完整原始条目（写回时保持字段不丢）
    public var raw: [String: Any]

    public init(slug: String, displayName: String, description: String, isGateway: Bool, inPicker: Bool, raw: [String: Any]) {
        self.slug = slug
        self.displayName = displayName
        self.description = description
        self.isGateway = isGateway
        self.inPicker = inPicker
        self.raw = raw
    }

    /// 来源标签，供界面直接展示
    public var sourceLabel: String { isGateway ? "公司网关" : "Codex 官方" }
}

/// 模型目录读写器
public enum CodexCatalogStore {
    /// 默认目录路径
    public static var defaultPath: String { PathKit.expand("~/.codex/codex-gateway-models.json") }

    /// 读取全部条目；文件不存在或损坏时返回空数组
    public static func load(path: String = defaultPath) -> [CodexCatalogEntry] {
        guard let data = FileManager.default.contents(atPath: PathKit.expand(path)),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = root["models"] as? [[String: Any]] else { return [] }
        return models.compactMap { entry(from: $0) }
    }

    /// 从原始条目解析出可视化信息
    static func entry(from raw: [String: Any]) -> CodexCatalogEntry? {
        guard let slug = raw["slug"] as? String else { return nil }
        let displayName = (raw["display_name"] as? String) ?? slug
        let description = (raw["description"] as? String) ?? ""
        let haystack = "\(displayName) \(description) \(raw["name"] as? String ?? "")".lowercased()
        let isGateway = GatewayCatalog.gatewayMarkers.contains { haystack.contains($0.lowercased()) }
        let visibility = (raw["visibility"] as? String) ?? "list"
        return CodexCatalogEntry(
            slug: slug,
            displayName: displayName,
            description: description,
            isGateway: isGateway,
            inPicker: visibility == "list",
            raw: raw
        )
    }

    /// 读取 Codex 自带（官方）模型条目，作为新增网关条目的模板来源
    public static func officialModels(codexBinary: String = "/Applications/ChatGPT.app/Contents/Resources/codex") -> [[String: Any]] {
        guard FileManager.default.isExecutableFile(atPath: codexBinary) else { return [] }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: codexBinary)
        process.arguments = ["debug", "models", "--bundled"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do { try process.run() } catch { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = root["models"] as? [[String: Any]] else { return [] }
        return models
    }

    /// 写回目录（原子写入）
    public static func write(_ entries: [[String: Any]], path: String = defaultPath) throws {
        let url = URL(fileURLWithPath: PathKit.expand(path))
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let payload: [String: Any] = ["models": entries]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .withoutEscapingSlashes])
        try AtomicWriter.write(String(decoding: data, as: UTF8.self), to: url, preservePermissionsFrom: url)
    }

    /// 新增一个公司网关模型条目（已存在则返回 false）
    /// - Parameters:
    ///   - slug: 网关侧真实模型名，例如 `ark/DeepSeek-V4.1-Flash`
    ///   - displayName: 菜单里显示的名字，例如 `DeepSeek V4.1（公司网关）`
    ///   - description: 说明文字
    ///   - inPicker: 是否立即出现在菜单
    @discardableResult
    public static func addGatewayModel(
        slug: String,
        displayName: String,
        description: String = "Company gateway model registered by KeyInjector.",
        inPicker: Bool = true,
        path: String = defaultPath
    ) throws -> Bool {
        let trimmedSlug = slug.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSlug.isEmpty else { return false }
        var raw = allRaw(path: path)
        if raw.contains(where: { ($0["slug"] as? String) == trimmedSlug }) { return false }

        // 模板优先取 GPT-5.6-Luna（保持与 Codex 官方条目同构），否则取官方第一条
        let official = officialModels()
        let template = official.first(where: { ($0["slug"] as? String) == "gpt-5.6-luna" }) ?? official.first
        guard var entry = template ?? raw.first else { return false }
        entry = deepCopy(entry)
        entry["slug"] = trimmedSlug
        entry["display_name"] = displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? trimmedSlug : displayName
        entry["description"] = description
        entry["visibility"] = inPicker ? "list" : "hide"
        entry["supported_in_api"] = true
        entry["priority"] = 100
        raw.insert(entry, at: 0)
        try write(raw, path: path)
        return true
    }

    /// 切换某条目是否出现在桌面端模型菜单（其余未知字段保持原样）
    @discardableResult
    public static func setInPicker(slug: String, inPicker: Bool, path: String = defaultPath) throws -> Bool {
        var raw = allRaw(path: path)
        guard let index = raw.firstIndex(where: { ($0["slug"] as? String) == slug }) else { return false }
        raw[index]["visibility"] = inPicker ? "list" : "hide"
        try write(raw, path: path)
        return true
    }

    /// 删除一个公司网关条目（官方条目不可删）
    @discardableResult
    public static func removeGatewayModel(slug: String, path: String = defaultPath) throws -> Bool {
        var raw = allRaw(path: path)
        let before = raw.count
        raw.removeAll { ($0["slug"] as? String) == slug && (entry(from: $0)?.isGateway ?? false) }
        guard raw.count != before else { return false }
        try write(raw, path: path)
        return true
    }

    /// 原样读回所有原始条目（保证写回时字段零丢失）
    static func allRaw(path: String) -> [[String: Any]] {
        guard let data = FileManager.default.contents(atPath: PathKit.expand(path)),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = root["models"] as? [[String: Any]] else { return [] }
        return models
    }

    /// 深拷贝，避免模板条目被跨条目共享引用
    static func deepCopy(_ value: [String: Any]) -> [String: Any] {
        guard let data = try? JSONSerialization.data(withJSONObject: value),
              let copy = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return value }
        return copy
    }
}
