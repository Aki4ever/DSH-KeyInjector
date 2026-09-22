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


---

## 模型清单从哪来（v1.3.0 起可视化，v1.4.0 起覆盖两个宿主）

用户疑问：「注入器只写入了公司 AI 综合密钥，并没有细分到模型，这些模型从哪来的？」

**简短回答**：模型清单来自**两个宿主各自的配置**，注入器把密钥挂到模型上，而不是反过来。

| 宿主 | 模型写在哪 | 凭据如何关联 |
| --- | --- | --- |
| DSH 桌面端 | `harness/settings.yaml` 的 `llm-pi-ai.providers.<id>.models` | 同处 `apiKeyEnv: MIDPRO_API_KEY` → `.credentials.yaml` 的 `refs` 区块 |
| Codex 桌面端 | `~/.codex/codex-gateway-models.json`（由 `config.toml` 的 `model_catalog_json` 指向） | `[model_providers.codex_gateway].base_url` → 指向同一台网关的密钥 |

### v1.3.0 的口径缺口（已在本版修正）

v1.3.0 的「模型清单」页**只读** `codex-gateway-models.json`，因此 DSH 顶部菜单里的
`DS/DeepSeek V4.1 Flash`、`gpt-6-astra`、`gpt-image-2.5` 等条目在注入器里完全看不到，
用户自然会问「为什么这边显示的模型和我注入器里的对不上」。

更隐蔽的是键名错配：`dsh-desktop` 落点当时静态登记 `itemKey: DEEPSEEK_API_KEY`，
而 DSH 实际读取 `settings.yaml` 声明的 `MIDPRO_API_KEY`。注入器会「成功写入一个 DSH 根本不读的键名」，
表现为**静默失效**——不报错，但宿主拿不到密钥。

### v1.4.0 的修正

1. **跨宿主模型清单**：`HostModelCatalog.swift` 同时读取两个宿主的配置，把模型读成同一形状。
2. **模型身份归一**：`ModelIdentity.normalize` 剥掉 `ark/`、`ds/` 等命名空间前缀，
   于是 `DS/DeepSeek V4.1 Flash` 与 `ark/DeepSeek-V4.1-Flash` 被识别为同一个模型。
3. **密钥 ↔ 模型绑定**：两条依据（命中其一即绑定，都不命中则如实显示「未绑定」）：
   - 凭据键名：宿主声明的 `apiKeyEnv` 命中该密钥的厂商环境变量名或落点键名；
   - 端点地址：宿主的 `baseURL` 与该密钥自定义 Base URL 同源。
4. **键名以宿主声明为权威**：`resolvedTargetItemKey` 优先返回宿主声明的键名，
   落点目录的 `itemKey` 只作回退；dry-run 会明确提示差异。

### 自查命令

```bash
keyinject hosts list     # 两个宿主的模型总览，含凭据键名与端点
keyinject hosts keys     # 每个密钥供给了哪些模型、依据是什么
keyinject keys           # 密钥列表，同时显示供给的模型
keyinject inject --target dsh-desktop --key <id>   # dry-run 会打印实际写入的键名
```

> 反例边界：注入器**只读** `settings.yaml`，绝不改写它。该文件里还有 onboarding、
> 权限预设、默认模型等大量非本工具所有的字段，任何「顺手规范化 YAML」的行为都会破坏用户配置。

---

## 旧的 Codex 单宿主说明（v1.3.0）

Codex 顶部模型菜单的唯一数据源是 `~/.codex/codex-gateway-models.json`（由
`config.toml` 的 `model_catalog_json` 指向）。该文件里混合了两类条目：

| 来源 | 谁写入 | 例子 |
| --- | --- | --- |
| Codex 官方条目 | Codex 自带 `codex debug models --bundled`（本工具不改动） | 6 Astra、5.6 Sol / Terra / Luna |
| **公司网关条目** | 本工具的注入流程（`syncCodexModelCatalogIfAvailable`）与本机 codex-gateway（`write_model_catalog`） | DeepSeek V4.1（公司网关）、Gemini 3.8 Flash（公司网关） |

也就是说：**网关模型条目确实来自你的 key 注入器**（以及同机的 codex-gateway），只是此前没有界面能看见，
所以像「凭空多出来的模型」。v1.3.0 起在应用侧边栏新增「模型清单」页，v1.4.0 起扩展为跨宿主总览，
CLI 对应 `keyinject hosts list|keys` 与 `keyinject models list|add|show|hide|rm`。

## 常驻守护（自动修复图 1 的故障）

```bash
keyinject gateway install-agent --interval 10     # 安装（launchd 心跳，每 10 秒体检一次）
keyinject gateway uninstall-agent                 # 卸载
tail -f ~/Library/Logs/keyinjector-gateway-guard.log   # 仅在真正修复时写日志
```

实测（2026-09-22 18:07）：人为删掉真实 `config.toml` 的 `model_provider` 后，**第 8 秒**被守护自动修复，
日志留下 `已自动修复：ark/DeepSeek-V4.1-Flash → provider=codex_gateway 备份=...`。

## 状态码中文说明

所有状态码（200 / 400 / 401 / 429 / 503 …）的中文口径见 `docs/error-codes.md`。
