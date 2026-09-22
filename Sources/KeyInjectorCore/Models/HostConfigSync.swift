// ==============================================================================
// 宿主配置同步：把网关声明的模型清单落到两个客户端
//
// 事实源：`~/.config/codex-gateway/config.json`（见 GatewayConfig.swift）。
//   「网关加了一个模型」→ 本工具把这个事实同步到
//     · DSH  `harness/settings.yaml` 的 `llm-pi-ai.providers.<网关供应商>.models`
//     · Codex `~/.codex/codex-gateway-models.json` 的网关条目
//
// 安全策略（用户确认：定点改写 + 每次自动备份）：
//   · 只改 `models:` 这一个列表，该供应商区块之外的字节一律不动；
//   · 每次落盘前由调用方备份（`BackupStore`），可一键回滚；
//   · 找不到可唯一确定的网关供应商时**拒绝写入**并给出原因，不做任何猜测性插入；
//   · 清单已一致时返回「无变化」，不产生空操作写入与无意义备份。
// ==============================================================================
import Foundation

/// 宿主配置同步器
public enum HostConfigSync {

    // MARK: - 结果类型

    /// 一次同步动作的结果（同时用于 dry-run 预览与真实落盘）
    public struct Result: Sendable {
        /// 是否有实际变化（false 表示已一致，没动任何字节）
        public var changed: Bool
        /// true 表示仅预览，未落盘
        public var dryRun: Bool
        /// 人类可读摘要
        public var summary: String
        /// 被同步的文件路径
        public var targetPath: String
        /// 新旧内容（供界面/CLI 出差异）
        public var before: String?
        public var after: String?
        /// 变化说明（逐条）
        public var notes: [String]
        /// 落盘失败或前置条件不满足时的原因
        public var failure: String?
        /// 落盘时的备份路径
        public var backupPath: String?

        public var succeeded: Bool { failure == nil }
    }

    /// 同步计划：把两个目标的结果打包，便于一次性预览
    public struct Plan: Sendable {
        public var gateway: GatewayConfig
        public var dsh: Result
        public var codex: Result

        /// 全部目标都已一致
        public var allConsistent: Bool { !dsh.changed && !codex.changed }
        public var anyChanged: Bool { dsh.changed || codex.changed }
    }

    // MARK: - DSH settings.yaml 的定点改写

    /// DSH 设置文件的解析视图：定位承载网关模型的供应商区块
    public struct DshLocation: Sendable {
        public var providerID: String
        /// `models:` 行的缩进（空格数）
        public var modelsKeyIndent: Int
        /// 模型条目的缩进（空格数）
        public var itemIndent: Int
        /// 当前已声明的模型 id
        public var currentModels: [String]
        /// `models:` 键所在行号（内部定位用，避免同名键串到别的供应商）
        var modelsKeyLine: Int
    }

    /// `models:` 列表的同步口径
    public enum MergeMode: String, Sendable {
        /// **默认**：只补齐网关声明而宿主缺失的模型，绝不删除宿主已有的条目。
        ///
        /// 这是唯一安全的默认值。实测反例：本机 DSH 的 `models` 里有
        /// `gpt-6-astra`、`gpt-image-2.5`、`gpt-image-2.5-flare` 三个模型，
        /// 而网关配置只声明 `deepseek` 与 `gemini` 两条线路。
        /// 若按「以网关为准整体替换」，这三个用户正在用的模型会被静默删掉——
        /// 「消除手工维护」绝不能以破坏可用配置为代价。
        case merge
        /// 显式要求时才用：把列表完全对齐网关声明（少掉的会被移除）。
        case replace
    }

    /// 纯函数：在 settings.yaml 里定点改写某个供应商的 `models:` 列表。
    ///
    /// 只处理块式序列（`models:` 后每行一个 `- id: xxx`）。遇到行内流式写法
    /// （`models: [a, b]`）直接报错而不是猜测——本工具宁可不动，也不破坏用户配置。
    public static func patchDshModels(
        content: String,
        providerID: String,
        models: [String],
        mode: MergeMode = .merge
    ) throws -> (text: String, before: [String], after: [String]) {
        var lines = content.components(separatedBy: "\n")
        guard let located = locate(lines: lines, match: { _, id in id == providerID }) else {
            throw SyncError.providerNotFound(providerID)
        }
        // 行内流式写法无法安全定点替换：宁可报错也不猜
        let keyLine = lines[located.modelsKeyLine]
        if keyLine.contains("[") {
            throw SyncError.unsupportedShape("models 使用了行内流式写法（models: [...]），请改为块式序列后重试")
        }
        let target = resolveModels(mode: mode, declared: models, existing: located.currentModels)

        // models 区块的范围：从 `models:` 行到该区块内最后一个模型条目行。
        // 注意不能把范围扩到「下一个浅于等于 models 的行」——那样会把区块尾部的空行
        // 一起吞掉，且插入点会落到空行之后，实测会插出**重复的 `models:` 键**。
        let start = located.modelsKeyLine
        var lastItemLine: Int?
        var scan = start + 1
        while scan < lines.count {
            let line = lines[scan]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { scan += 1; continue }
            let level = line.prefix { $0 == " " }.count
            if level <= located.modelsKeyIndent { break }
            if level == located.itemIndent, trimmed.hasPrefix("- ") { lastItemLine = scan }
            scan += 1
        }
        let blockEnd = (lastItemLine ?? start) + 1

        // merge 模式做**纯插入**：既有行一个字节都不重写。
        // 这样「同步」对用户已有配置的扰动为零，diff 里只会出现新增的那几行。
        if mode == .merge {
            let newModels = target.filter { !located.currentModels.contains($0) }
            guard !newModels.isEmpty else { return (content, located.currentModels, target) }
            // 条目形状跟随既有条目：宿主原来用单行标量就继续用单行标量，
            // 不擅自给新条目加 input 字段，避免同一列表里出现两种形状。
            let shape = existingEntryShape(lines: lines, location: located)
            let inserted = makeDshModelsBlock(modelsKeyIndent: located.modelsKeyIndent,
                                              itemIndent: located.itemIndent,
                                              models: newModels, rich: shape)
            lines.insert(contentsOf: inserted, at: blockEnd)
            return (lines.joined(separator: "\n"), located.currentModels, target)
        }

        let shape = existingEntryShape(lines: lines, location: located)
        let block = makeDshModelsBlock(modelsKeyIndent: located.modelsKeyIndent,
                                       itemIndent: located.itemIndent,
                                       models: target, rich: shape)
        lines.replaceSubrange(start..<blockEnd, with: block)
        return (lines.joined(separator: "\n"), located.currentModels, target)
    }

    /// 按口径算出最终列表。
    ///
    /// merge：宿主已有条目**原样保留原有顺序**，网关新增的追加到末尾
    ///        （不插到前面，避免打乱用户在宿主菜单里习惯的顺序）。
    public static func resolveModels(mode: MergeMode, declared: [String], existing: [String]) -> [String] {
        switch mode {
        case .merge:
            var result = existing
            for model in declared where !result.contains(model) { result.append(model) }
            return result
        case .replace:
            return declared
        }
    }

    /// 组装块式 models 序列（**不含** `models:` 键行，便于就地插入）。
    ///
    /// `rich = true` 时每条带 `input: [text, image]`（公司网关的两个线路都是多模态模型）；
    /// 为 false 时只写 `- id: xxx` 单行标量。形状由既有条目决定，见 `existingEntryShape`。
    static func makeDshModelsBlock(
        modelsKeyIndent: Int, itemIndent: Int, models: [String],
        includeKeyLine: Bool = false, rich: Bool = true
    ) -> [String] {
        var block: [String] = includeKeyLine ? ["\(String(repeating: " ", count: modelsKeyIndent))models:"] : []
        for model in models {
            block.append("\(String(repeating: " ", count: itemIndent))- id: \(model)")
            guard rich else { continue }
            block.append("\(String(repeating: " ", count: itemIndent + 2))input:")
            block.append("\(String(repeating: " ", count: itemIndent + 4))- text")
            block.append("\(String(repeating: " ", count: itemIndent + 4))- image")
        }
        return block
    }

    /// 判断既有模型条目是「单行标量」还是「带 input 的富条目」。
    ///
    /// 之所以要看既有形状：往一个全是 `- id: xxx` 的列表里插富条目，
    /// 会让同一个列表出现两种写法，用户会以为工具把配置改坏了。
    /// 无既有条目时默认富条目（网关模型确为多模态）。
    static func existingEntryShape(lines: [String], location: DshLocation) -> Bool {
        var scan = location.modelsKeyLine + 1
        while scan < lines.count {
            let line = lines[scan]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { scan += 1; continue }
            let level = line.prefix { $0 == " " }.count
            if level <= location.modelsKeyIndent { break }
            if level == location.itemIndent, trimmed.hasPrefix("- ") {
                return false
            }
            if level > location.itemIndent, trimmed.hasPrefix("input:") {
                return true
            }
            scan += 1
        }
        return true
    }

    /// 在 settings.yaml 里定位指定 id 的供应商，并读出它当前的 models 列表。
    public static func locateDshProvider(lines: [String], providerID: String) -> DshLocation? {
        locate(lines: lines) { _, id in id == providerID }
    }

    /// 在 settings.yaml 里定位指向网关地址的那个供应商。
    public static func locateDshProvider(lines: [String], baseURL: String) -> DshLocation? {
        guard !baseURL.isEmpty else { return nil }
        return locate(lines: lines) { base, _ in HostModelInventory.sameEndpoint(base, baseURL) }
    }

    /// 统一的 YAML 供应商标记扫描，只暴露最外层供应商。
    private static func locate(
        lines: [String],
        match: (_ baseURL: String, _ providerID: String) -> Bool
    ) -> DshLocation? {
        var matches: [DshLocation] = []

        var inRoot = false, inProviders = false
        var rootIndent = 0, providersIndent = 0, providerIndent = 0
        var currentID: String?
        var currentBase = ""
        var modelsKeyIndex: Int?
        var modelsKeyIndent = 0
        var itemIndent = 0
        var models: [String] = []
        var inModels = false
        var modelsIndent = 0

        func flush() {
            guard let id = currentID else { return }
            if match(currentBase, id), let keyLine = modelsKeyIndex {
                matches.append(DshLocation(providerID: id, modelsKeyIndent: modelsKeyIndent,
                                           itemIndent: itemIndent, currentModels: models,
                                           modelsKeyLine: keyLine))
            }
            currentID = nil; currentBase = ""; modelsKeyIndex = nil; models = []; inModels = false
        }

        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            let level = line.prefix { $0 == " " }.count

            if !inRoot {
                guard trimmed.hasPrefix("llm-pi-ai:"), !trimmed.hasPrefix("-") else { continue }
                inRoot = true; rootIndent = level; continue
            }
            if level <= rootIndent { flush(); inRoot = false; inProviders = false; continue }
            if !inProviders {
                guard trimmed.hasPrefix("providers:"), !trimmed.hasPrefix("-") else { continue }
                inProviders = true; providersIndent = level; continue
            }
            if level <= providersIndent { flush(); inProviders = false; continue }

            // 供应商键：恰好比 providers 深一级且不是列表项
            if level == providersIndent + 2, !trimmed.hasPrefix("-"), trimmed.hasSuffix(":") {
                flush()
                currentID = String(trimmed.dropLast()).trimmingCharacters(in: .whitespaces)
                providerIndent = level
                continue
            }
            guard currentID != nil else { continue }

            if inModels, level >= modelsIndent, trimmed.hasPrefix("- ") {
                let body = String(trimmed.dropFirst(2))
                if body.hasPrefix("id:") {
                    let value = body.dropFirst(3).trimmingCharacters(in: .whitespaces)
                    if !value.isEmpty { models.append(value) }
                    if itemIndent == 0 { itemIndent = level }
                }
                continue
            }
            guard level == providerIndent + 2 else { continue }

            if trimmed.hasPrefix("models:") {
                // 行内流式写法的可行性由 patchDshModels 判定并报错；这里只负责定位
                inModels = !trimmed.contains("[")
                modelsIndent = level
                modelsKeyIndex = index
                modelsKeyIndent = level
                if itemIndent == 0 { itemIndent = level + 2 }
                continue
            }
            inModels = false
            if trimmed.hasPrefix("baseURL:") || trimmed.hasPrefix("baseUrl:") || trimmed.hasPrefix("base_url:") {
                let value = trimmed.drop { $0 != ":" }.dropFirst().trimmingCharacters(in: .whitespaces)
                currentBase = value.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            }
        }
        flush()

        // 只有一个候选才允许写入：多个候选说明有歧义，交给用户决定
        return matches.count == 1 ? matches[0] : nil
    }

    /// 生成一段可粘贴的供应商区块（仅当 DSH 里完全没有指向网关的供应商时，供人工使用）
    public static func suggestedDshProviderBlock(
        providerID: String = "gateway",
        displayName: String = "公司网关",
        baseURL: String,
        apiKeyEnv: String,
        models: [String]
    ) -> String {
        var lines = [
            "    \(providerID):",
            "      displayName: \(displayName)",
            "      apiKeyEnv: \(apiKeyEnv)",
            "      api: openai-completions",
            "      baseURL: \(baseURL)",
            "      models:"
        ]
        for model in models {
            lines.append("        - id: \(model)")
            lines.append("          input:")
            lines.append("            - text")
            lines.append("            - image")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Codex 目录

    /// Codex 目录同步的输出：新的条目数组 + 补齐了哪些 slug
    /// `entries` 是 JSON 原始形状（`[[String: Any]]`，写回时字段零丢失），
    /// 只能在返回后由调用方独占消费，故标注 `@unchecked Sendable`。
    public struct CodexOutcome: @unchecked Sendable {
        public var entries: [[String: Any]]
        public var added: [String]
        public var changed: Bool
    }

    /// 把网关声明的模型同步进 Codex 模型目录（补齐缺失条目，不删除用户自建条目）。
    ///
    /// 与 DSH 侧一致：已存在同 slug 的条目**只补齐可见性**，不覆盖用户改过的显示名与描述。
    public static func syncCodexCatalog(
        gateway: GatewayConfig,
        existingEntries: [[String: Any]]
    ) throws -> CodexOutcome {
        guard !gateway.upstreamModels.isEmpty else {
            return CodexOutcome(entries: existingEntries, added: [], changed: false)
        }
        var entries = existingEntries
        var added: [String] = []

        for slug in gateway.upstreamModels {
            if let idx = entries.firstIndex(where: { ($0["slug"] as? String) == slug }) {
                // 已存在：只在「被隐藏」时恢复为菜单可见，其余字段一律尊重用户
                let visibility = (entries[idx]["visibility"] as? String) ?? "list"
                if visibility != "list" {
                    entries[idx]["visibility"] = "list"
                    added.append(slug)
                }
                continue
            }
            guard var template = codexTemplate(existing: entries) else { continue }
            template["slug"] = slug
            template["display_name"] = GatewayConfig.displayName(forSlug: slug)
            template["description"] = "公司中间商网关提供的模型（由 keyinject 从网关配置同步）"
            template["visibility"] = "list"
            template["supported_in_api"] = true
            template["priority"] = 100
            entries.insert(template, at: 0)
            added.append(slug)
        }

        guard !added.isEmpty else { return CodexOutcome(entries: existingEntries, added: [], changed: false) }
        return CodexOutcome(entries: entries, added: added, changed: true)
    }

    /// 取一个已有条目当模板（保持与 Codex 官方条目同构，字段零丢失）
    static func codexTemplate(existing: [[String: Any]]) -> [String: Any]? {
        let official = CodexCatalogStore.officialModels()
        let pick = official.first(where: { ($0["slug"] as? String) == "gpt-5.6-luna" })
            ?? official.first
            ?? existing.first
        guard let pick else { return nil }
        return CodexCatalogStore.deepCopy(pick)
    }
}

public enum SyncError: Error, CustomStringConvertible {
    case providerNotFound(String)
    case unsupportedShape(String)
    case gatewayUnavailable(String)

    public var description: String {
        switch self {
        case .providerNotFound(let id):
            return "在 DSH 设置文件里找不到指向该网关地址的供应商区块（\(id)）：清单不同源时本工具拒绝猜测性插入，请先手工确认"
        case .unsupportedShape(let message):
            return "配置写法暂不支持：\(message)"
        case .gatewayUnavailable(let path):
            return "读不到网关配置（\(path)）：网关未安装或尚未初始化，已跳过同步"
        }
    }
}
