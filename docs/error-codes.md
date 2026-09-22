# 状态码与错误码对照表（中文说明）

> 建档：2026-09-22　|　适用：KeyInjector v1.3.0 / codex-gateway / Codex 桌面端
> 约定：**任何反馈中的数字状态码都必须带中文说明**；本文是唯一口径来源。

---

## 一、HTTP 状态码（网关、Codex 后端、厂商 API 通用）

| 状态码 | 中文含义 | 典型原因 | 处置建议 |
| :--- | :--- | :--- | :--- |
| **200** | 成功 | 请求被正常处理 | 无需动作 |
| **400** | 请求不合法 | 参数/模型名不被后端接受。例如 ChatGPT 后端收到非官方模型名，返回 `The '<model>' model is not supported when using Codex with a ChatGPT account.` | 检查 `~/.codex/config.toml` 的 `model_provider` 是否指向 `codex_gateway`；`keyinject gateway repair --yes` |
| **401** | 未授权 | API Key 错误、过期或未被网关接受 | 重新注入密钥；确认网关鉴权头风格（Bearer / x-api-key） |
| **402** | 需要付费/额度不足 | 上游账号欠费或套餐额度用尽 | 找上游管理员充值或换线路 |
| **403** | 拒绝访问 | 密钥无该模型权限，或来源 IP 被限制 | 确认密钥权限与网络出口 |
| **404** | 资源不存在 | 端点路径写错，或自定义 provider 未在 `config.toml` 注册 | 核对 Base URL 末尾是否带 `/v1`，核对 provider 区块 |
| **408** | 请求超时（服务端视角） | 上游处理过慢 | 重试；必要时下调推理档位 |
| **413** | 请求体过大 | 上下文或工具定义超出上游限制 | 精简会话或换上下文更大的模型 |
| **422** | 参数语义错误 | 字段类型/取值不合法 | 按返回信息修正字段 |
| **429** | 请求过多 / 配额耗尽 | 上游限流或额度用尽；本机实测 Gemini（Antigravity 线路）会返回 `Resource has been exhausted (e.g. check quota)` | 等待额度重置、降低并发，或改用另一条线路（如 DeepSeek） |
| **500** | 上游内部错误 | 网关或模型服务异常 | 重试；持续失败则反馈网关管理员 |
| **502** | 网关错误（上游不可达） | 反向代理拿到无效响应 | 确认网关进程与上游连通性 |
| **503** | 服务不可用 | 上游凭据池为空或维护中。本机实测网关会返回 `auth_unavailable: no auth available (providers=..., last upstream error: 429 RESOURCE_EXHAUSTED)` | 属**网关侧**问题：等待恢复或联系管理员轮换凭据 |
| **504** | 网关超时 | 上游在限定时间内无响应 | 重试；下调推理档位 |

## 二、本工具自有的非数字状态

| 取值 | 中文含义 | 出现位置 |
| :--- | :--- | :--- |
| `network-error` | 网络不可达（未拿到任何 HTTP 响应） | 健康探测、网关连通性检查 |
| `unchecked` / `未判定` | 尚未探测 | 密钥库、健康探测页 |
| `unreachable` | 目标不可达 | 健康探测结果分类 |
| `unknown` | 未知状态（端点变化或响应无法归类） | 健康探测结果分类 |
| `quota` | 额度/限流（对应 402、429） | 健康探测结果分类 |

## 三、keyinject CLI 退出码

| 退出码 | 中文含义 |
| :--- | :--- |
| **0** | 成功（含 dry-run 正常完成） |
| **1** | 业务失败：路径不存在、slug 未找到、探测未通过等 |
| **2** | 被安全策略阻断：受管区块标记不成对、JSON 键路径缺失、路径不可写、文件被外部修改等 |

## 四、Codex 网关路由体检的取值

| 字段 | 取值 | 中文含义 |
| :--- | :--- | :--- |
| `healthy` | `true` | 当前模型是网关模型且已路由到 `codex_gateway`，或当前模型不是网关模型 |
| `healthy` | `false` | 当前模型属公司网关，但 `model_provider` 缺失或为官方 `openai` —— 请求会被 ChatGPT 后端拒绝（400） |
| `gateway_model` | `true` / `false` | 该 slug 是否为公司网关模型（已知 slug 或目录里带「网关 / gateway」标记） |
| `exists` | `true` / `false` | 是否找到 `config.toml`（受 `CODEX_HOME` 影响） |

## 五、常见报错原文 → 中文速查

| 报错原文 | 中文含义 | 处置 |
| :--- | :--- | :--- |
| `The '<model>' model is not supported when using Codex with a ChatGPT account.` | 该模型名不被 ChatGPT 后端支持：请求被路由到了官方 provider | `keyinject gateway repair --yes`（守护已自动处理），随后**新开一轮对话或重启 Codex** |
| `auth_unavailable: no auth available (providers=..., last upstream error: 429 RESOURCE_EXHAUSTED)` | 网关上游凭据池无可用账号，且最后一次上游错误是额度耗尽 | 网关侧问题；改用 DeepSeek 线路或联系管理员 |
| `Resource has been exhausted (e.g. check quota).` | 上游额度耗尽（HTTP 429） | 等待额度重置 |
| `401 Invalid API key` | 网关拒绝 API Key | 重新注入密钥 |
| `exceeded retry limit, last status: 429 Too Many Requests` | 本地重试次数用尽，最后状态是限流 | 已把 provider 重试上限提到 6；仍失败说明上游持续限流 |
