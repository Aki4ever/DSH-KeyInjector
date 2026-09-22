import Foundation

/// 公司中间商网关模型目录的识别工具。
///
/// 背景：`~/.codex/codex-gateway-models.json` 由本工具与本机 codex-gateway 共同维护，
/// 其中「官方 Codex 模型」与「公司网关模型」混在同一个 `models` 数组里。
/// 只有后者才必须走 `codex_gateway` provider —— 一旦被 openai provider 接手，
/// ChatGPT 后端会直接返回
/// “The '<model>' model is not supported when using Codex with a ChatGPT account.”
public enum GatewayCatalog {
    /// 已知的公司网关模型 slug（双保险：即使目录缺失也能识别）
    public static let knownGatewaySlugs: Set<String> = [
        "ark/DeepSeek-V4.1-Flash",
        "gemini-3.8-flash-high"
    ]

    /// 网关模型在目录里的标记词（本工具与 codex-gateway 生成条目时都会带上）
    public static let gatewayMarkers = ["网关", "gateway"]

    /// 判断某个模型 slug 是否属于公司网关模型
    /// - Parameters:
    ///   - slug: 模型 slug，例如 `ark/DeepSeek-V4.1-Flash`
    ///   - catalogPath: 模型目录 JSON 路径；命中标记词的非官方条目同样视为网关模型
    public static func isGatewayModel(_ slug: String, catalogPath: String? = nil) -> Bool {
        if knownGatewaySlugs.contains(slug) { return true }
        guard let catalogPath, let marked = markedSlugs(inCatalog: catalogPath) else { return false }
        return marked.contains(slug)
    }

    /// 读取模型目录中带有网关标记词（display_name / description 含「网关」或 gateway）的 slug 集合
    public static func markedSlugs(inCatalog path: String) -> Set<String>? {
        guard let data = FileManager.default.contents(atPath: PathKit.expand(path)),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = root["models"] as? [[String: Any]] else { return nil }
        var result: Set<String> = []
        for model in models {
            guard let slug = model["slug"] as? String else { continue }
            let haystack = (["display_name", "description", "name"]
                .compactMap { model[$0] as? String }
                .joined(separator: " ")).lowercased()
            if gatewayMarkers.contains(where: { haystack.contains($0.lowercased()) }) {
                result.insert(slug)
            }
        }
        return result
    }
}
