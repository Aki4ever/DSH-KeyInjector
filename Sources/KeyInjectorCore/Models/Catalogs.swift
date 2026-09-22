// ==============================================================================
// 预设目录：厂商目录 (ProviderCatalog) 与注入落点目录 (TargetCatalog)
//
// 设计取舍说明：
// 第三方工具（Claude Code / Codex 等）的配置文件路径与键名由各自的厂商决定，
// 可能随版本变化。因此这里的内置预设刻意保持「保守 + 可覆盖」：
//   1) 内置项只收录路径稳定、社区通用的落点；
//   2) 全部落点都带有「反例边界」说明，提示先走 dry-run 预览；
//   3) 运行时可从 `<数据目录>/config/providers.json` 与 `config/targets.json`
//      加载覆盖项，无需重新编译即可修正路径（见 KeyInjectorService.loadOverrides）。
// ==============================================================================
import Foundation

// MARK: - 厂商目录

public struct ProviderCatalog: Sendable {
    public private(set) var providers: [Provider]

    public init(providers: [Provider] = ProviderCatalog.builtins) {
        self.providers = providers
    }

    public func provider(id: String) -> Provider? {
        providers.first { $0.id == id }
    }

    public func name(of id: String) -> String {
        provider(id: id)?.name ?? id
    }

    /// 合并外部覆盖：同 id 覆盖内置项，新 id 追加
    public func merged(with overrides: [Provider]) -> ProviderCatalog {
        var list = providers
        for item in overrides {
            if let idx = list.firstIndex(where: { $0.id == item.id }) {
                list[idx] = item
            } else {
                list.append(item)
            }
        }
        return ProviderCatalog(providers: list)
    }

    public static let builtins: [Provider] = [
        Provider(
            id: "openai",
            name: "OpenAI",
            envKeys: ["OPENAI_API_KEY"],
            baseURL: "https://api.openai.com/v1",
            healthPath: "/models",
            consoleURL: "https://platform.openai.com/api-keys",
            secretPrefixes: ["sk-"],
            authStyle: .bearer,
            note: "探测使用 GET /v1/models，仅校验鉴权是否通过，不产生推理计费。"
        ),
        Provider(
            id: "anthropic",
            name: "Anthropic (Claude)",
            envKeys: ["ANTHROPIC_API_KEY"],
            baseURL: "https://api.anthropic.com/v1",
            healthPath: "/models",
            consoleURL: "https://console.anthropic.com/settings/keys",
            secretPrefixes: ["sk-ant-"],
            authStyle: .headerKey,
            extraHeaders: ["anthropic-version": "2023-06-01"],
            note: "Anthropic 使用 x-api-key 头而非 Bearer，本工具已内置该差异。"
        ),
        Provider(
            id: "deepseek",
            name: "DeepSeek",
            envKeys: ["DEEPSEEK_API_KEY"],
            baseURL: "https://api.deepseek.com",
            healthPath: "/models",
            balancePath: "/user/balance",
            consoleURL: "https://platform.deepseek.com/api_keys",
            secretPrefixes: ["sk-"],
            authStyle: .bearer,
            note: "OpenAI 兼容接口，DSH 宿主即读取 DEEPSEEK_API_KEY 环境变量。三家实测中唯一提供余额接口的厂商：GET /user/balance 返回 is_available 与分币种余额。模型清单本身不含任何时间字段，故「更新日期」维度显示为「该协议不提供」。"
        ),
        Provider(
            id: "google",
            name: "Google Gemini",
            envKeys: ["GEMINI_API_KEY"],
            baseURL: "https://generativelanguage.googleapis.com/v1beta",
            healthPath: "/models",
            consoleURL: "https://aistudio.google.com/app/apikey",
            secretPrefixes: ["AIza", "AQ."],
            authStyle: .queryKey,
            note: "Gemini 走 ?key= 或 Bearer 鉴权，支持 Google AI Studio (AIza) 及 Cloud/中转凭证 (AQ.)。"
        ),
        Provider(
            id: "openrouter",
            name: "OpenRouter",
            envKeys: ["OPENROUTER_API_KEY"],
            baseURL: "https://openrouter.ai/api/v1",
            healthPath: "/key",
            consoleURL: "https://openrouter.ai/keys",
            secretPrefixes: ["sk-or-"],
            authStyle: .bearer,
            note: "探测 /key 会返回该密钥的额度与限流信息，是判断额度最准的端点。"
        ),
        Provider(
            id: "moonshot",
            name: "Moonshot (Kimi)",
            envKeys: ["MOONSHOT_API_KEY"],
            baseURL: "https://api.moonshot.cn/v1",
            healthPath: "/models",
            consoleURL: "https://platform.moonshot.cn/console/api-keys",
            secretPrefixes: ["sk-"],
            authStyle: .bearer,
            note: "国内直连，无需代理即可探测。"
        ),
        Provider(
            id: "zhipu",
            name: "智谱 GLM",
            envKeys: ["ZHIPUAI_API_KEY"],
            baseURL: "https://open.bigmodel.cn/api/paas/v4",
            healthPath: "/models",
            consoleURL: "https://open.bigmodel.cn/usercenter/apikeys",
            secretPrefixes: [],
            authStyle: .bearer,
            note: "密钥形如 `id.secret` 两段式，长度较长，属正常现象。"
        ),
        Provider(
            id: "custom",
            name: "自定义 / 兼容网关",
            envKeys: ["CUSTOM_API_KEY"],
            baseURL: nil,
            healthPath: nil,
            consoleURL: nil,
            secretPrefixes: [],
            authStyle: .bearer,
            note: "反例：本项不做任何健康探测与格式预检，请自行确认鉴权方式；自建网关请用环境变量注入。"
        )
    ]
}

// MARK: - 注入落点目录

public struct TargetCatalog: Sendable {
    public private(set) var targets: [InjectionTarget]

    public init(targets: [InjectionTarget] = TargetCatalog.builtins) {
        self.targets = targets
    }

    public func target(id: String) -> InjectionTarget? {
        targets.first { $0.id == id }
    }

    /// 某厂商可用的落点（含通用落点）
    public func targets(forProvider providerID: String) -> [InjectionTarget] {
        targets.filter { $0.providerID == nil || $0.providerID == providerID }
    }

    public func merged(with extras: [InjectionTarget]) -> TargetCatalog {
        var list = targets
        for item in extras {
            if let idx = list.firstIndex(where: { $0.id == item.id }) {
                list[idx] = item
            } else {
                list.append(item)
            }
        }
        return TargetCatalog(targets: list)
    }

    /// 是否需要用户自行指定文件路径
    public static func requiresPath(_ t: InjectionTarget) -> Bool {
        t.format.writesFile && t.filePath.trimmingCharacters(in: .whitespaces).isEmpty
    }

    public static let builtins: [InjectionTarget] = [
        InjectionTarget(
            id: "dsh-desktop",
            name: "DSH 桌面端凭据 (YAML)",
            providerID: nil,
            format: .yaml,
            filePath: "~/Library/Application Support/com.yeagoo.dsh-desktop/harness/.credentials.yaml",
            section: "refs",
            itemKey: "MIDPRO_API_KEY",
            note: "定点写入 DSH 桌面端凭据（.credentials.yaml 的 refs 区块），支持官方与各类中转网关 Key。注入后重启 DSH 生效。注：DSH 真正读取的键名由 settings.yaml 的 llm-pi-ai.providers.*.apiKeyEnv 声明，本工具以宿主声明为准动态解析，此处仅是该落点无宿主配置时的回退值。"
        ),
        InjectionTarget(
            id: "codex-cli",
            name: "Codex 独立 Profile 凭证 (TOML)",
            providerID: nil,
            format: .toml,
            filePath: "~/.codex/company.config.toml",
            section: "env",
            itemKey: "OPENAI_API_KEY",
            note: "写入独立的 ~/.codex/company.config.toml，与官方 ChatGPT 登录态完全隔离，保证桌面端稳定启动不受影响。"
        )
    ]
}
