# 排障记录：Codex 使用公司网关模型（DeepSeek / Gemini）报错

> 建档：2026-09-22　|　实施版本：`v1.2.0`　|　状态：**主因已修复并验证**

---

## 一句话结论

`~/.codex/config.toml` 里只有 `model = "<公司网关模型>"`，却**没有** `model_provider = "codex_gateway"`，
Codex 于是把请求发给了官方 `openai` provider（ChatGPT 后端），而该后端只认官方模型名，
必然返回 400：

```
The 'ark/DeepSeek-V4.1-Flash' model is not supported when using Codex with a ChatGPT account.
The 'gemini-3.8-flash-high' model is not supported when using Codex with a ChatGPT account.
```

这不是模型或密钥的问题，而是**路由配置缺失**。

---

## 两类报错的完整归因

### 错误 A：`... model is not supported when using Codex with a ChatGPT account`（HTTP 400）

| 环节 | 事实 |
| --- | --- |
| 触发动作 | 在 Codex 桌面端顶部模型菜单把模型切成 `DeepSeek（公司网关）` 或 `Gemini（公司网关）` |
| 桌面端行为 | 只把 `model` 写进 `~/.codex/config.toml` 与本地状态，**不写 `model_provider`** |
| 结果 | 缺失 `model_provider` → 回退默认 provider `openai` → 请求发往 `chatgpt.com/backend-api/codex` |
| ChatGPT 后端 | 只接受官方模型 slug（`gpt-5.6-luna` 等），自定义 slug 一律 400 |

复现证据（`/Applications/ChatGPT.app/Contents/Resources/codex exec`）：

```
model: gemini-3.8-flash-high
provider: openai                      ← 本应是 codex_gateway
ERROR: {"type":"error","status":400,"error":{"message":"The 'gemini-3.8-flash-high' model is not supported when using Codex with a ChatGPT account."}}
```

会话元数据同样留痕：`~/.codex/sessions/.../rollout-*.jsonl` 中 `"model_provider": "openai"`。

### 错误 B：`429 / 503 auth_unavailable`（上游额度）

修好路由后再跑 Gemini，会看到另一条**与模型无关**的报错：

```
503 {"error":{"message":"auth_unavailable: no auth available (providers=antigravity, model=gemini-3.8-flash-high;
     last upstream error: {\"error\":{\"code\":429,\"message\":\"Resource has been exhausted (e.g. check quota).\",\"status\":\"RESOURCE_EXHAUSTED\"}})"}}
```

这是**公司网关侧 Gemini（Antigravity 路线）账号额度耗尽/凭据抖动**，DeepSeek 线路同时刻完全正常。
属于网关运维项，本地配置怎么改都无效。

---

## 已做的修复

1. **`~/.codex/config.toml`**（已备份为 `config.toml.before-gateway-provider-fix-20260922T174141+0800.bak`）
   - 补回受管区块，锁定路由：
     ```toml
     # BEGIN CODEX-GATEWAY DESKTOP
     model = "gemini-3.8-flash-high"
     model_provider = "codex_gateway"
     # END CODEX-GATEWAY DESKTOP
     ```
   - `model_providers.codex_gateway` 的重试上限 2 → 6，用于吸收上游偶发 429/503 抖动。

2. **KeyInjector 内置守护（v1.2.0）**
   - `InjectionEngine.ensureCodexGatewayProviderRouting(_:catalogPath:)`：只要发现「网关模型 + provider 不是 `codex_gateway`」，
     就自动补写受管区块；只搬动 `model` / `model_provider`，其它顶层设置原样保留；
     用户显式指定的第三方 provider 不动。
   - 新增 CLI：`keyinject gateway check` / `keyinject gateway repair [--yes]`（默认 dry-run，落盘前自动备份 + 审计）。
   - 6 项回归测试，测试总数 46 项全绿。

---

## 验证记录（2026-09-22 17:40 前后）

| 检查项 | 命令 | 结果 |
| --- | --- | --- |
| 网关可达 | `curl /v1/models` | 200，返回模型列表 |
| DeepSeek 直连 | `curl /v1/responses` `ark/DeepSeek-V4.1-Flash` | 200，正常出 token |
| DeepSeek 经 Codex | `codex exec -m ark/DeepSeek-V4.1-Flash` | `provider: codex_gateway`，正常返回 |
| Gemini 直连 | `curl /v1/responses` `gemini-3.8-flash-high` | 时好时坏：200 / 429 / 503 |
| Gemini 经 Codex | `codex exec -m gemini-3.8-flash-high` | 路由已修正为 `codex_gateway`，但被上游额度挡下 |
| 路由体检 | `keyinject gateway check` | 通过 |

---

## 使用与复现要点

```bash
# 体检
keyinject gateway check

# 修复（dry-run 预览）
keyinject gateway repair

# 真正落盘
keyinject gateway repair --yes

# 命令行直连（不依赖桌面端下拉菜单）
codex --profile gateway-deepseek
codex --profile gateway-gemini

# CLI 单次覆盖
codex exec -m "ark/DeepSeek-V4.1-Flash" -c 'model_provider="codex_gateway"'
```

> 每次在桌面端下拉菜单**换模型**后，先跑一次 `keyinject gateway check`；
> 若报“路由异常”，执行 `keyinject gateway repair --yes`，然后完全退出并重开 Codex。
> 注入流程命中 `~/.codex/config.toml` 时守护会自动执行，通常不需要手动介入。

---

## 待办 / 需要网关侧处理

- **Gemini 线路额度**：请网关管理员确认 `gemini-3.8-flash-high`（Antigravity 上游）的配额与凭据轮换状态。
  在额度恢复前，建议把默认模型设为 DeepSeek。
- 桌面端模型切换若能一并写 `model_provider`（或 Codex 支持按模型绑定 provider），即可从根上消除错误 A；
  当前用本仓库的守护 + CLI 兜底。

---

## 双侧守护（2026-09-22 实施）

路由守护现在**两侧都有**，任一侧触发都能把 `model_provider` 拉回 `codex_gateway`：

| 位置 | 入口 | 说明 |
| --- | --- | --- |
| KeyInjector v1.2.0 | `keyinject gateway check` / `keyinject gateway repair [--yes]` | 与应用「一键注入」流程共用；注入命中 `~/.codex/config.toml` 时自动执行 |
| codex-gateway | `bin/codex-gateway route` / `route --fix`、`doctor` 的 `codex.desktop_routing`、管理页「桌面端路由」卡片与 `POST /api/route/fix` | 网关侧独立兜底，`route --fix` 写前备份为 `config.toml.before-desktop-routing-fix.bak` |

两侧的共同约束：只搬动 `model` / `model_provider`，其余顶层设置原样保留；当前模型不是网关模型、或用户显式指定了其它第三方 provider 时不动。

### Gemini 线路复测记录（2026-09-22 17:50 前后）

| 请求形态 | 结果 |
| --- | --- |
| `curl` 最简 input | 200（多次成功） |
| `curl` + tools / + instructions + reasoning | 200 |
| 同一 payload 连测 5 次 | 200 / 429 / 503 交替出现 |
| Codex agent 真实请求（`codex exec -m gemini-3.8-flash-high`） | 稳定 429 |

结论：**Antigravity 上游凭据池不稳定 + 额度受限**，与 Codex 配置无关；同一时刻 DeepSeek 线路连续多次 200。
网关自检 `bin/codex-gateway --json test gemini --protocol responses` 此刻返回 200，但不足以支撑 Codex 单轮多请求的 agent 负载。
