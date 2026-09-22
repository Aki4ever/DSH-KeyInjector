---
name: keyinject
description: AI API Key 管理与配置注入技能包。当用户在 DSH 会话中需要新增/查看/删除大模型 API Key、把密钥注入到 Claude Code / Codex CLI / Shell 启动脚本 / 项目 .env 等第三方工具配置文件、探测密钥是否有效或额度是否耗尽、回滚一次注入、查看操作审计时使用本技能。
version: 1.3.0
---

# keyinject — AI API Key 管理与配置注入技能

## 一、何时使用本技能

在 DSH 会话中出现以下意图时，装载本技能：

- 「把这个 API Key 存起来 / 帮我管理几个大模型的 key / 我有多个 key 想轮换」
- 「把 key 配到 Claude Code / Codex / 我的 zshrc / 项目 .env 里」
- 「这个 key 还有效吗 / 额度用完了吗 / 帮我批量测一下」
- 「刚才那次注入改错了，恢复回去」
- 「看看我最近对配置做了哪些改动」

## 二、核心安全铁律（必须遵守）

1. **`inject` 默认是 dry-run**：不加 `--yes` 绝不写文件。先给用户看差异，再决定是否加 `--yes`。
2. **密钥明文绝不进入会话上下文**：永远不要用 `--show-secret`，也不要让用户把明文贴进对话。
   需要录入时让用户自己在应用界面操作，或用 `--secret-stdin` 从标准输入读取。
3. **输出一律掩码**：CLI 输出的密钥只有 `sk-d…7890` 形式与 8 位指纹，这是刻意设计，不要试图绕过。
4. **写入前必有备份**：每次写入都会自动备份，回滚有据可依。
5. **退出码即结论**：`0` 成功 / `1` 失败 / `2` 被安全策略阻断（阻断是保护，不要重试或绕过）。

## 三、工具位置

```bash
# 源码构建产物
.build/debug/keyinject          # 调试版
.build/release/keyinject        # 发布版

# 已安装的应用包内自带
/Applications/Key注入器.app/Contents/Resources/bin/keyinject
```

## 四、标准操作流程

### 4.1 先摸清现状

```bash
keyinject info --json                    # 数据目录、密钥后端、审计文件位置
keyinject keys --json                    # 现有密钥（仅掩码与指纹）
keyinject targets --json                 # 可注入落点清单与各自的反例说明
```

### 4.2 新增密钥（不暴露明文）

```bash
# 推荐：从标准输入读取，避免明文进入 shell 历史
printf '%s' "$SECRET" | keyinject keys add --provider deepseek --label "主力" --secret-stdin --json
```

> 若用户直接在对话中发了明文密钥，**不要**把它写进命令行（会进入历史与日志）。
> 应提示用户改用界面「新增密钥」，或由用户自行执行命令。

### 4.3 注入（两阶段）

```bash
# 第一阶段：只看计划，不写文件
keyinject inject --target shell-profile --key <密钥id> --json

# 核对返回中的 diff 字段确认无误后，第二阶段才写入
keyinject inject --target shell-profile --key <密钥id> --yes
```

**必须把第一阶段返回的 diff 呈现给用户确认**，不要跳过直接写入。

### 4.4 健康探测

```bash
keyinject check --id <密钥id> --json     # 单个
keyinject check --all --json             # 全部
```

状态语义：`valid` 有效 / `invalid` 无效 / `quota` 额度或限流 / `unreachable` 网络不通 / `unknown` 未知。
**`unknown` 不等于失效**，不要据此建议用户换 key。

### 4.5 回滚

```bash
keyinject rollback --target shell-profile --file ~/.zshrc --json    # 该落点最近一次
keyinject rollback --audit-id <审计id> --json                        # 精确回滚某一次
```

### 4.6 审计

```bash
keyinject audit --limit 20 --json
```

### 4.7 Codex 网关模型路由体检（v1.2.0 起）

Codex 桌面端切换公司网关模型后，`~/.codex/config.toml` 可能只剩 `model` 而缺 `model_provider`，
请求会退回官方 `openai` provider，被 ChatGPT 后端拒绝为
`The '<model>' model is not supported when using Codex with a ChatGPT account.`

```bash
keyinject gateway check --json            # 体检：路由是否指向 codex_gateway
keyinject gateway repair                  # dry-run 预览修复内容
keyinject gateway repair --yes            # 落盘修复（自动备份 + 写审计）
```

修复只搬动 `model` 与 `model_provider` 两个键，其余顶层设置原样保留；用户显式指定的第三方 provider 不会被覆盖。

常驻守护（自动收敛，避免每次换模型后复发）：

```bash
keyinject gateway install-agent --interval 10   # launchd 心跳，每 10 秒体检并自动修复
keyinject gateway uninstall-agent               # 卸载
```

### 4.8 模型清单（Codex 顶部菜单的来源）

```bash
keyinject models list            # 只看公司网关条目（含来源标签与菜单可见性）
keyinject models list --all      # 含 Codex 官方条目
keyinject models add --slug ark/DeepSeek-V4.1-Flash --name "DeepSeek V4.1（公司网关）" --yes
keyinject models show|hide --slug <模型名>
keyinject models rm --slug <模型名>
```

菜单条目全部来自 `~/.codex/codex-gateway-models.json`：官方条目由 Codex 自带目录生成，
公司网关条目由本工具注入流程或 codex-gateway 写入。应用内「模型清单」页提供同样的可视化操作。

## 五、落点选择建议

| 场景 | 推荐落点 | 说明 |
| :--- | :--- | :--- |
| 让所有终端工具都能用 | `shell-profile` | 写入 `~/.zshrc` 受管区块，幂等可重复执行 |
| Claude Code | `claude-code` | 写入 `~/.claude/settings.json` 的 `env.ANTHROPIC_API_KEY` |
| Codex CLI | `codex-cli` | 写入 `~/.codex/auth.json` |
| 单个项目隔离 | `dotenv-project` | 写入项目 `.env`，不影响全局 |
| 只想拿到片段自己贴 | `env-only` | **不写任何文件**，只输出片段，最安全 |

**不确定时优先 `env-only`**：零副作用。

## 六、典型失败与处置

| 现象 | 原因 | 处置 |
| :--- | :--- | :--- |
| 退出码 2，提示受管区块标记不成对 | 目标文件被手工改过，标记被破坏 | 让用户检查该文件中的 `# >>> KeyInjector managed block >>>` 与结束标记，修好后重试 |
| 退出码 1，提示键路径不存在 | JSON 落点的键路径在该文件中不存在 | **本工具刻意不新建键路径**。让用户确认该第三方工具是否已完成过一次初始化，或改用手工确认后的路径 |
| 提示文件不可写 | 权限或路径是目录 | 让用户确认路径与权限，不要用 sudo 绕过 |
| 探测返回 `unknown` | 厂商端点路径变化或网络受限 | 如实告知「未知」，而非判定失效；可在 `config/providers.json` 中覆盖端点 |
| YAML/TOML 落点报格式不支持 | 目标文件用了多层嵌套或内联写法 | 建议改用 JSON 落点，或由用户手工维护该文件 |
| Codex 报 `model is not supported when using Codex with a ChatGPT account` | 网关模型的请求被路由到官方 `openai` provider | `keyinject gateway check` 确认后执行 `keyinject gateway repair --yes`，再完全重启 Codex |
| Codex 报 `429 / 503 auth_unavailable`（含 `RESOURCE_EXHAUSTED`） | 网关上游额度耗尽或凭据抖动，**与本地配置无关** | 如实告知属于网关侧问题：改用另一条线路（如 DeepSeek）或联系网关管理员 |

## 七、能力边界（不要向用户夸大）

- YAML/TOML 是**定点行替换**，不支持多层嵌套、流式写法、内联表与数组表。
- JSON 只做定点替换，**不会新建键路径**。
- plist 只支持扁平键名。
- Shell 落点仅适用于 sh / bash / zsh，fish 与 csh 用户需自定义落点。
- 健康探测只代表「此刻鉴权是否通过」，不代表模型可用性或余额充足。
- 密钥后端若被切到「本地加密文件」，其安全性低于钥匙串（主密钥与密文同机），应如实说明。

## 八、与其他 DSH 能力配合

- 需要用户确认写入时，用界面截图或把 CLI 返回的 diff 字段格式化呈现，**不要**让用户自己猜。
- 涉及多个独立落点的批量注入时，逐个 dry-run 逐个确认，不要合并成一次盲写。
- 用户真实配置文件只应通过本工具改写（这样才有备份与审计）。**禁止**用 `sed`/重定向直接改配置文件。
