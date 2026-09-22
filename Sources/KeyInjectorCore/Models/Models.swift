// ==============================================================================
// 核心数据模型：厂商、密钥记录、注入目标、审计条目
// ==============================================================================
import Foundation

// MARK: - 厂商 (Provider)

/// 一家大模型服务商。仅描述「如何取用密钥」，**不保存任何密钥明文**。
public struct Provider: Codable, Hashable, Identifiable, Sendable {
    /// 稳定标识，如 `openai`、`deepseek`
    public var id: String
    /// 中文显示名
    public var name: String
    /// 该厂商约定的环境变量名，第一个为「主变量名」
    public var envKeys: [String]
    /// 默认 API 基址
    public var baseURL: String?
    /// 健康探测路径（相对 baseURL），nil 表示该厂商不支持探测
    public var healthPath: String?
    /// 密钥申请控制台地址
    public var consoleURL: String?
    /// 已知密钥前缀，用于录入时的格式预检（如 `sk-`）
    public var secretPrefixes: [String]
    /// 认证方式
    public var authStyle: AuthStyle
    /// 探测时需附带的额外请求头（如 Anthropic 的 `anthropic-version`）
    public var extraHeaders: [String: String]
    /// 注意事项与反例边界
    public var note: String

    public init(
        id: String,
        name: String,
        envKeys: [String],
        baseURL: String? = nil,
        healthPath: String? = nil,
        consoleURL: String? = nil,
        secretPrefixes: [String] = [],
        authStyle: AuthStyle = .bearer,
        extraHeaders: [String: String] = [:],
        note: String = ""
    ) {
        self.id = id
        self.name = name
        self.envKeys = envKeys
        self.baseURL = baseURL
        self.healthPath = healthPath
        self.consoleURL = consoleURL
        self.secretPrefixes = secretPrefixes
        self.authStyle = authStyle
        self.extraHeaders = extraHeaders
        self.note = note
    }

    /// 主环境变量名
    public var primaryEnvKey: String { envKeys.first ?? "API_KEY" }
}

/// 认证头风格
public enum AuthStyle: String, Codable, Sendable {
    /// `Authorization: Bearer <key>`
    case bearer
    /// `x-api-key: <key>`
    case headerKey
    /// 以查询参数 `?key=<key>` 传递
    case queryKey
    /// 无需认证头的前缀式（部分兼容网关）
    case bearerAPIKey
}

// MARK: - 密钥记录 (KeyRecord)

/// 密钥的**元数据**记录。密钥明文存放于系统钥匙串或加密文件，
/// 本结构只在磁盘上保留掩码提示与指纹，杜绝明文落盘。
public struct KeyRecord: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    /// 所属厂商 id
    public var providerID: String
    /// 用户可读别名，如「主力 Key」「备用-额度包」
    public var label: String
    /// 密钥掩码提示，如 `sk-…a1b2`（不可还原明文）
    public var hint: String
    /// SHA-256 前 8 位指纹，用于校验与去重
    public var fingerprint: String
    /// 是否启用（禁用的 Key 不会被注入器选用）
    public var enabled: Bool
    /// 优先级，数值越小越优先
    public var priority: Int
    public var tags: [String]
    public var note: String
    /// 自定义 API 基址（中转商 / 代理网关地址；nil 则使用厂商默认 baseURL）
    public var baseURL: String?
    public var createdAt: Date
    public var updatedAt: Date
    /// 最近一次健康探测结果
    public var lastCheck: CheckSummary?

    public init(
        id: String = UUID().uuidString,
        providerID: String,
        label: String,
        hint: String,
        fingerprint: String,
        enabled: Bool = true,
        priority: Int = 100,
        tags: [String] = [],
        note: String = "",
        baseURL: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        lastCheck: CheckSummary? = nil
    ) {
        self.id = id
        self.providerID = providerID
        self.label = label
        self.hint = hint
        self.fingerprint = fingerprint
        self.enabled = enabled
        self.priority = priority
        self.tags = tags
        self.note = note
        self.baseURL = baseURL
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.lastCheck = lastCheck
    }
}

// MARK: - 健康探测结果

public struct CheckSummary: Codable, Hashable, Sendable {
    public var status: CheckStatus
    public var httpStatus: Int?
    public var latencyMS: Int?
    public var checkedAt: Date
    public var message: String

    public init(status: CheckStatus, httpStatus: Int? = nil, latencyMS: Int? = nil, checkedAt: Date = Date(), message: String = "") {
        self.status = status
        self.httpStatus = httpStatus
        self.latencyMS = latencyMS
        self.checkedAt = checkedAt
        self.message = message
    }
}

public enum CheckStatus: String, Codable, Sendable {
    /// 密钥有效
    case valid
    /// 密钥无效或被吊销
    case invalid
    /// 额度耗尽 / 触发限流
    case quota
    /// 网络不可达
    case unreachable
    /// 无法判定
    case unknown
    /// 尚未探测
    case unchecked

    public var label: String {
        switch self {
        case .valid: return "有效"
        case .invalid: return "无效"
        case .quota: return "额度/限流"
        case .unreachable: return "网络不通"
        case .unknown: return "未判定"
        case .unchecked: return "未探测"
        }
    }

    /// SF Symbols 图标名（GUI 使用）
    public var symbolName: String {
        switch self {
        case .valid: return "checkmark.seal.fill"
        case .invalid: return "xmark.seal.fill"
        case .quota: return "exclamationmark.triangle.fill"
        case .unreachable: return "wifi.slash"
        case .unknown: return "questionmark.circle"
        case .unchecked: return "circle.dashed"
        }
    }
}

// MARK: - 注入目标 (InjectionTarget)

/// 配置文件的写入格式
public enum InjectionFormat: String, Codable, CaseIterable, Sendable {
    /// `KEY=value` 形式的 .env 文件
    case dotenv
    /// `export KEY="value"` 形式的 shell 启动脚本（使用受管区块，便于幂等与回滚）
    case shellExport
    /// JSON 文件（按键路径定点替换，保留原有缩进与键序）
    case json
    /// YAML 文件（区块 + 键的定点行替换）
    case yaml
    /// TOML 文件（`[section]` + `key = value` 定点行替换）
    case toml
    /// macOS plist（经 PropertyListSerialization 读写）
    case plist
    /// 不写任何文件，仅生成导出片段供人工复制
    case none

    public var label: String {
        switch self {
        case .dotenv: return "dotenv"
        case .shellExport: return "shell 导出"
        case .json: return "JSON"
        case .yaml: return "YAML"
        case .toml: return "TOML"
        case .plist: return "plist"
        case .none: return "仅生成片段"
        }
    }

    /// 该格式是否会真实写入磁盘
    public var writesFile: Bool { self != .none }
}

/// 一个可被注入的落点：某个工具/框架的某个配置文件。
public struct InjectionTarget: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var name: String
    /// 绑定厂商；nil 表示任意厂商均可使用
    public var providerID: String?
    public var format: InjectionFormat
    /// 目标文件路径，支持 `~` 展开；`.none` 格式可留空
    public var filePath: String
    /// JSON 专用：键路径，如 `["env", "ANTHROPIC_API_KEY"]`
    public var jsonPath: [String]
    /// YAML / TOML 专用：区块名
    public var section: String?
    /// YAML / TOML / dotenv / shell 专用：键名；nil 时取厂商的主环境变量名
    public var itemKey: String?
    /// 是否为「自定义」落点（路径与键名由用户填写）
    public var isCustom: Bool
    /// 该落点的用途与**反例边界**说明
    public var note: String

    public init(
        id: String,
        name: String,
        providerID: String? = nil,
        format: InjectionFormat,
        filePath: String = "",
        jsonPath: [String] = [],
        section: String? = nil,
        itemKey: String? = nil,
        isCustom: Bool = false,
        note: String = ""
    ) {
        self.id = id
        self.name = name
        self.providerID = providerID
        self.format = format
        self.filePath = filePath
        self.jsonPath = jsonPath
        self.section = section
        self.itemKey = itemKey
        self.isCustom = isCustom
        self.note = note
    }

    /// 结合厂商解析出最终环境变量/键名
    public func resolvedItemKey(for provider: Provider) -> String {
        if let k = itemKey, !k.isEmpty { return k }
        if let last = jsonPath.last, !last.isEmpty { return last }
        return provider.primaryEnvKey
    }
}

// MARK: - 审计条目 (AuditEntry)

public enum AuditAction: String, Codable, Sendable {
    case createKey
    case updateKey
    case deleteKey
    case enableKey
    case disableKey
    case inject
    case rollback
    case healthCheck

    public var label: String {
        switch self {
        case .createKey: return "新增密钥"
        case .updateKey: return "更新密钥"
        case .deleteKey: return "删除密钥"
        case .enableKey: return "启用密钥"
        case .disableKey: return "禁用密钥"
        case .inject: return "执行注入"
        case .rollback: return "回滚配置"
        case .healthCheck: return "健康探测"
        }
    }
}

public struct AuditEntry: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var timestamp: Date
    public var action: AuditAction
    /// 结果：success / dryRun / failure
    public var result: String
    public var message: String
    public var targetID: String?
    public var filePath: String?
    public var keyID: String?
    public var providerID: String?
    /// 仅记录指纹，绝不记录明文
    public var fingerprint: String?
    public var backupPath: String?

    public init(
        id: String = UUID().uuidString,
        timestamp: Date = Date(),
        action: AuditAction,
        result: String,
        message: String,
        targetID: String? = nil,
        filePath: String? = nil,
        keyID: String? = nil,
        providerID: String? = nil,
        fingerprint: String? = nil,
        backupPath: String? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.action = action
        self.result = result
        self.message = message
        self.targetID = targetID
        self.filePath = filePath
        self.keyID = keyID
        self.providerID = providerID
        self.fingerprint = fingerprint
        self.backupPath = backupPath
    }
}
