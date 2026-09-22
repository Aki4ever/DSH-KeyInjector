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
            consoleURL: "https://platform.deepseek.com/api_keys",
            secretPrefixes: ["sk-"],
            authStyle: .bearer,
            note: "OpenAI 兼容接口，DSH 宿主即读取 DEEPSEEK_API_KEY 环境变量。"
        ),
        Provider(
            id: "google",
            name: "Google Gemini",
            envKeys: ["GEMINI_API_KEY"],
            baseURL: "https://generativelanguage.googleapis.com/v1beta",
            healthPath: "/models",
            consoleURL: "https://aistudio.google.com/app/apikey",
            secretPrefixes: ["AIza"],
            authStyle: .queryKey,
            note: "Gemini 走 ?key= 查询参数鉴权，注意避免把含密钥的完整 URL 粘进聊天记录。"
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
            id: "shell-profile",
            name: "Shell 启动脚本（通用推荐）",
            providerID: nil,
            format: .shellExport,
            filePath: "~/.zshrc",
            itemKey: nil,
            note: "写入受管区块 `# >>> KeyInjector >>>`，幂等可重复执行。反例：fish / csh 用户无效，请改选自定义落点。"
        ),
        InjectionTarget(
            id: "claude-code",
            name: "Claude Code 设置",
            providerID: "anthropic",
            format: .json,
            filePath: "~/.claude/settings.json",
            jsonPath: ["env", "ANTHROPIC_API_KEY"],
            note: "定点替换 `env.ANTHROPIC_API_KEY`，保留原文件缩进与键序。反例：若该文件不存在或没有 env 对象，本工具会拒绝写入并报错，请改用 Shell 启动脚本落点。"
        ),
        InjectionTarget(
            id: "codex-cli",
            name: "Codex CLI 凭证",
            providerID: "openai",
            format: .json,
            filePath: "~/.codex/auth.json",
            jsonPath: ["OPENAI_API_KEY"],
            note: "定点替换顶层 `OPENAI_API_KEY`。反例：Codex 新版可能改用 `codex login` 的 OAuth 凭证，请先 dry-run 核对，避免与官方登录态互相覆盖。"
        ),
        InjectionTarget(
            id: "dotenv-project",
            name: "项目 .env（需指定路径）",
            providerID: nil,
            format: .dotenv,
            filePath: "",
            note: "适合把密钥写进具体项目的 .env。反例：不要把 .env 提交进 Git；请确认项目 .gitignore 已忽略它。"
        ),
        InjectionTarget(
            id: "custom-json",
            name: "自定义 JSON 落点",
            providerID: nil,
            format: .json,
            filePath: "",
            jsonPath: [],
            isCustom: true,
            note: "需填写文件路径与键路径（如 `env.MY_KEY`）。反例：不支持数组下标之外的复杂表达式。"
        ),
        InjectionTarget(
            id: "custom-yaml",
            name: "自定义 YAML 落点",
            providerID: nil,
            format: .yaml,
            filePath: "",
            section: nil,
            itemKey: nil,
            isCustom: true,
            note: "按「区块 + 键」做定点行替换，不重排注释。反例：多层嵌套或流式写法（`{a: b}`）不在支持范围内。"
        ),
        InjectionTarget(
            id: "custom-toml",
            name: "自定义 TOML 落点",
            providerID: nil,
            format: .toml,
            filePath: "",
            section: nil,
            itemKey: nil,
            isCustom: true,
            note: "定位 `[section]` 后替换 `key = value`。反例：内联表与数组表（`[[x]]`）不在支持范围内。"
        ),
        InjectionTarget(
            id: "custom-plist",
            name: "自定义 plist 落点",
            providerID: nil,
            format: .plist,
            filePath: "",
            jsonPath: [],
            isCustom: true,
            note: "经系统 PropertyListSerialization 读写，会重排格式但保留全部键值。"
        ),
        InjectionTarget(
            id: "env-only",
            name: "仅生成导出片段（不写文件）",
            providerID: nil,
            format: .none,
            note: "最安全选项：只输出 `export KEY=...` 片段供你自行粘贴，本工具不碰任何文件。"
        )
    ]
}
