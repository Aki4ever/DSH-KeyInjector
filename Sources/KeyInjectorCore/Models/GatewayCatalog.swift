import Foundation

/// 公司中间商网关模型目录的识别工具。
///
/// 背景：`~/.codex/codex-gateway-models.json` 由本工具与本机 codex-gateway 共同维护，
/// 其中「官方 Codex 模型」与「公司网关模型」混在同一个 `models` 数组里。
/// 只有后者才必须走 `codex_gateway` provider —— 一旦被 openai provider 接手，
/// ChatGPT 后端会直接返回
/// “The '<model>' model is not supported when using Codex with a ChatGPT account.”
public enum GatewayCatalog {
    /// 公司网关模型 slug —— **不再硬编码**。
    ///
    /// v1.4.0 之前这里写死两个 slug，网关一加模型就得改代码，是明确的维护负担。
    /// 现在唯一事实源是网关自己的配置（`~/.config/codex-gateway/config.json` 的
    /// `models` 路由表）。读不到网关配置时回退为空集合，由目录标记词与
    /// `model_provider` 归属继续兜底判定，不会把网关模型误判成官方模型。
    public static var knownGatewaySlugs: Set<String> {
        Set(GatewayConfig.declaredModels())
    }

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
