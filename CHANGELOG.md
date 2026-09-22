# 变更日志 — KeyInjector · 账号管理器

本文件遵循 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/) 结构，版本号语义遵循 [语义化版本](https://semver.org/lang/zh-CN/)。

> 版本号单一来源为仓库根目录 `VERSION` 文件；全工程一致性由 `scripts/check_version_sync.sh` 自动校验。

---

## [2.0.0] — 2026-09-22

本轮主题：**从「注入器」升级为「账号管理器」**——显示层改名、按官方协议调研补齐模型三维度、模型清单并入密钥页。

### 变更（破坏性：仅限界面结构与显示名）
- **显示层改名**：`Key 注入器` → **`账号管理器`**。涉及网页标题与品牌区、macOS 应用菜单（关于 / 隐藏 / 退出）、窗口标题、打包产物 `dist/账号管理器.app`、DMG 卷标与文件名。
  **刻意保留**：Swift 包名 `KeyInjector`、模块 `KeyInjectorCore`、可执行名 `keyinject`、环境变量 `KEYINJECTOR_HOME`、应用支持目录 —— 它们是技能包与既有脚本的接口，一并改名会造成静默破坏（REQ-023）。
- **「模型清单」页并入「密钥」页**：左侧导航由 6 项精简为 5 项。跨宿主总览（清单来源 / 网关事实源 / 条目明细 / Codex 目录管理）现在收在密钥页顶部的可折叠区，默认收起，摘要行常显「模型身份 N 个 · 已绑定密钥 M 把 · 同步状态」（REQ-025）。
  旧入口 `switchPage('models')` 与自动化钩子仍可用，会落到密钥页并自动展开总览。

### 新增
- **模型三维度展示（模型名称 / 剩余额度 / 更新日期）**，依据官方协议调研而非猜测（`docs/knowledge-account-protocols.md`）：
  - **更新日期**：解析 OpenAI 形状的 `created`（Unix 秒，另兼容毫秒与 ISO 字符串）为「发布时间」，并单独展示 `shutdown_date`（下线公告）。
  - **版本号**：Gemini 的 `version`（如 `001`）单独存为「版本」，**严禁当作更新时间**展示。
  - **剩余额度**：新增厂商预设字段 `balancePath`；DeepSeek 配置为 `GET /user/balance`，解析 `is_available`（布尔闸门）与分币种 `balance_infos`，**金额一律字符串原样保留**（避免 `110.00` 被浮点显示成 `110.0`）。其余厂商不发起任何余额请求，界面如实显示「该协议不提供」。
- **协议未提供的维度显式留白**：DeepSeek 模型行显示「更新时间：该协议不提供」，而不是显示空白或用本机时间冒充。
- **Gemini OpenAI 兼容端点自动改用 Bearer**：新增 `EndpointProtocol.authOverride`。实测该端点在缺少 `Authorization` 头时返回 **404**（伪装成「接口不存在」），补上头后立即改口 400「请传有效密钥」——过去这条 404 会被误读成「不支持模型列表」。
- **CLI 同步输出新维度**：`keyinject models probe --id <id> [--json]`、`key show`、`keys --grouped` 均输出 `balance` 块与每模型的 `publishedAt` / `versionTag` / `shutdownDate`，缺字段即缺席（不下发空值兜底）。

### 修复
- **旧缓存可继续读取**：`ModelDiscoveryResult` 与 `AvailableModel` 改为宽容解码（`decodeIfPresent`），v1.6.0 的 `model-cache.json`（无 `metadata` / `balance` 键）仍能反序列化，历史识别结果不会因升级而全部作废。
- **模型解析新增独立入口**：`parseModelEntries` 返回带元数据的条目，`parseModels` 签名保持不变（既有测试与调用点零改动）。

### 测试
- 新增 7 例：OpenAI `created` 解析、DeepSeek 无时间字段、Gemini `version` 不被当时间、旧缓存兼容解码、余额响应解析、DeepSeek 余额端到端（多候选命中 `/user/balance`）、非 DeepSeek 厂商不发起余额请求。
- 全量 **99 个测试通过**，既有 92 例零回归。

### 文档
- 新增 `docs/knowledge-account-protocols.md`（三家协议调研 + 三维度可用性总表 + 输入输出契约 + 简化需求文案）。
- 需求台账新增 REQ-023 ~ REQ-026 并登记第 5 轮需求确认。

---

## [1.6.0] — 2026-09-22

本轮主题：**消除全部手工维护点**。用户原话：「帮我处理掉所有需要我手动维护的地方」。

### 新增
- **网关成为唯一事实源（`GatewayConfig`）**：网关自己就在
  `~/.config/codex-gateway/config.json` 里声明了 `base_url` 与 `models` 路由表
  （`deepseek → ark/DeepSeek-V4.1-Flash` 这类）。本工具此前把这些信息**抄了四份死名单**，
  现在统一从网关读取。网关新增模型后，工具自然发现，**不需要任何人改代码**。
- **一键同步到两个客户端（`keyinject sync`）**：把网关声明的模型补齐到
  DSH `settings.yaml` 与 Codex 模型目录。默认 dry-run，确认后 `--yes` 落盘，
  每个目标写入前自动备份。
- **GUI「网关事实源」卡片**：模型清单页显示清单来源、路由表、两个客户端的差异与一键补齐按钮。
- **GUI 一键切换模型**：模型卡片上直接「切换到此模型」，把原本要在 Codex 菜单里
  点选并确认 provider 的操作压缩成一次点击。

### 修复
- **受管区块 END 标记累积**：`removeManagedBlock` 此前「遇到空行就停手」，
  而块尾的空行是 `split(omittingEmptySubsequences: false)` 的必然产物，
  于是 `# END` 被留在原地。反复切换模型时 END 不断累积（实测第二次调用就出现两个 END）。
  现在以 END 标记为显式终点收敛，并新增 `strippedOfManagedMarkers` 做「先剥干净再重建」，
  切换模型变为**幂等**（连续调用输出完全一致，已加回归测试）。
- **孤儿 BEGIN 会吞掉用户设置**：清理孤儿 `# BEGIN` 时只删除「标记行 + 紧跟的注释行」，
  绝不把后面的 `[marketplaces]` 等用户配置当作块内容删掉（已加回归测试）。
- **硬编码路径与地址全部移除**：`Injector.swift` 曾写死
  `/Users/linqiyu/Documents/ChatGPT/对接gemini/bin/codex-gateway` 与 `http://192.168.1.200:8080/v1`。
  现在二进制路径按「已登记的 auth.command → 环境变量 → 常见位置 → PATH」依次探测，
  地址取自网关配置；两者都拿不到时**跳过写入**而不是写一个猜出来的地址。
- **DSH 侧模型名单不再需要手写**：`llm-pi-ai.providers.<id>.models` 支持块式序列与
  `线路名: 上游模型名` 映射两种写法，两种都能正确解析。

### 安全设计（本轮最关键的取舍）
- **同步默认「只增不减」（merge）**：实测反例——本机 DSH 的 `models` 里有
  `gpt-6-astra`、`gpt-image-2.5`、`gpt-image-2.5-flare`，而网关配置只声明两条线路。
  若按「以网关为准整体替换」，这三个**用户正在用的模型会被静默删掉**。
  「消除手工维护」绝不能以破坏可用配置为代价，因此默认只补齐、不删除；
  需要完全对齐时显式使用 `--prune`。
- **纯插入改写**：merge 模式下对既有 YAML 行**一个字节都不重写**，
  实测 diff 只有新增的那几行；新条目的形状（是否带 `input:`）跟随既有条目，避免同一列表两种写法。
- **不做自动降级**：用户明确选择「只告警，不自动切」。额度耗尽时本工具不擅自改你的默认模型，
  但把「换模型」的代价降到一条命令 / 一次点击。
- **仍不改写 DSH 设置里非本工具所有的字段**：只动 `models:` 这一个列表。

### 密钥库分区、模型识别与详情（用户本轮新增诉求）

用户原话：「我现在密钥库里有 2 个 key，帮我在这里做好分区；要根据 key 的名称进行名字分区，
然后名字分区下列出该 key 可以获取的模型类型」「应该在密钥库这边可以识别出 key 有什么模型可以提供；
点进 key 进去可以查看详情」。

- **密钥库按 key 别名分区**：一把 key 一个分区，分区标题行给出别名、厂商、状态、
  模型计数与折叠箭头；页头新增搜索框（别名/厂商/模型名/端点/标签）与「仅看未探测/异常」筛选。
  分区数据直接复用后端 `keysGrouped`，与 CLI `keyinject keys --grouped` 同一口径，
  避免界面与命令行两套分组逻辑各自漂移。
- **从 key 自身端点识别可用模型（T1→T5 多级兜底）**：先 `GET {端点}/models` 实测，
  依次尝试 `/models`、`/v1/models`、去掉 `/v1` 的变体与厂商 `healthPath`；
  兼容 OpenAI / Gemini / Ollama / 裸数组 / 键值映射五种响应形态；
  全部失败时退回宿主声明映射，最后才给名称推断候选。**每一行都标注来源与依据**。
  实机实测：公司AI综合 key 从 `http://192.168.1.200:8080/v1/models` 读回 20 条原始条目、
  去重后 19 个模型身份（比宿主声明的 6 个多出一批此前完全不可见的模型）；
  Gemini key 探测返回 401（该凭据不是 API Key 形态），界面如实降级并展示原因，不伪造空列表。
- **key 详情视图**：点卡片标题或「详情」按钮进入全屏模态，五段信息——身份、健康探测、
  可提供的模型、注入落点、最近审计记录。「改为探测鉴权」与「重新探测模型」分开摆放，
  因为「这把 Key 通不通」和「这把 Key 有哪些模型」是两件事。
- **发现结果缓存与 CLI**：结果存 `model-cache.json`（0600，只含掩码/指纹/模型名/端点/时间，
  不含明文）；界面首帧**只读缓存不联网**，只有显式点击才发起真实请求。
  新增 `keyinject keys --grouped`、`keyinject key show --id`、`keyinject models probe --id|--all`。

### 修复（v1.6.0 开发期实测发现，均为「只在真实环境暴露」的缺陷）

- **跨厂商误绑**：Gemini key 曾被判成「供给公司网关 5 个模型」——仅仅因为 DSH 落点键名
  `MIDPRO_API_KEY` 与网关供应商的 `apiKeyEnv` 同名，而该 key 的端点
  （`generativelanguage.googleapis.com`）与网关端点毫无关系。这类误绑会让用户以为
  「换这把 Key 也能用这些模型」，属于静默误导。现在要求**端点同源**，或凭据名出自该 key
  自身厂商且端点属于该厂商官方域名；纯落点键名同名不再绑定（已加回归测试）。
- **推断噪声**：T5 名称推断此前对跨厂商记录也产出候选，等于把别人的模型贴到这把 key 上。
  现在只在「供应商相符 / 端点同域 / 宿主完全未声明且当前无任何记录」三者之一成立时才给候选。
- **详情弹窗导致整页白屏**：详情弹窗的 DOM 写在 `<script src="app.js">` 之后，
  脚本执行时 `$('#detail-close')` 为 null 并抛错，**顶层脚本连同后续赋值全部中断**，
  界面表现为「页面框架在、数据全空」。已把弹窗节点移到脚本之前。
- **顶层 try 包裹会吞掉全局变量**：曾用一个顶层 `try { … }` 包裹整个 `app.js` 做异常自曝，
  结果把全部 `const`/`let` 关进块级作用域，`state`、`call` 等全部消失。
  已移除该包裹，并在快照脚本里改为逐步记录 `STEP_ERR`。
  以上两条在 `jsc` 语法检查里**完全看不出来**，只有浏览器真实执行才暴露。

### 变更
- **`build_app.sh` 刷新 `~/.local/bin/keyinject`**：launchd 常驻守护每 10 秒执行的就是这个路径。
  它若不随构建更新，守护会一直用旧二进制而用户完全看不到这种「静默漂移」。
  跳过方式：`KEYINJECTOR_NO_CLI_LINK=1 bash scripts/build_app.sh`。

### 测试
- 测试从 60 项增至 **92 项 / 20 个套件**：在 76 项基础上新增「模型发现」测试组（9 例：
  五种响应形态解析、畸形 JSON、端点候选顺序、探测失败降级、缓存读写与明文安全、
  跨厂商不误绑、推断噪声护栏）与「密钥库分区与详情」测试组（分组口径、详情聚合内容）。

---

## [1.4.0] — 2026-09-22

### 新增
- **跨宿主模型清单（DSH + Codex 一并可见）**：新增 `HostModelCatalog.swift`。此前「模型清单」页只读
  `~/.codex/codex-gateway-models.json`，DSH 桌面端顶部菜单里的模型（写在
  `harness/settings.yaml` 的 `llm-pi-ai.providers.*.models`）在注入器里完全不可见，
  用户会以为模型「凭空多出来」。现在两个宿主的模型被读成同一形状并汇总展示。
- **模型身份归一（跨宿主去重）**：DSH 的 `DS/DeepSeek V4.1 Flash` 与 Codex 的
  `ark/DeepSeek-V4.1-Flash` 归一为同一模型，界面显示为「一个模型，两个宿主别名」，
  而不是两堆互不相关的条目。
- **密钥库内嵌「模型供给」区块**：每张密钥卡直接列出它供给的模型（按宿主分组，
  标注凭据键名、菜单可见性与绑定依据）。默认折叠为一行摘要，点击展开。
  CLI 对应：`keyinject hosts list`、`keyinject hosts keys`，`keyinject keys` 也带上了供给模型。
- **模型清单总览页重做**：改为跨宿主总览（含 DSH 设置路径与凭据占用、Codex 目录与路由状态、
  去重模型数、已挂上模型的密钥数），Codex 网关条目的写入操作收敛到底部虚线管理区。

### 修复
- **DSH 落点键名错配（静默失效）**：`dsh-desktop` 落点静态登记的是 `DEEPSEEK_API_KEY`，
  而 DSH 实际读取的是 `settings.yaml` 中 `apiKeyEnv` 声明的 `MIDPRO_API_KEY`。
  结果是「一键注入提示成功，但宿主读不到密钥」。现在键名**以宿主声明为唯一权威**动态解析
  （`resolvedTargetItemKey`），落点静态值只作回退；dry-run 会明确提示键名差异与写入结果。
- **YAML 定点改写不再制造假差异**：`KEY: sk-xxx` 与 `KEY: "sk-xxx"` 在 YAML 中同值，
  此前一律重写为带引号形式，造成「空操作注入」并产生无意义备份与差异行。现在同值直接不改写。
- **侧边栏「模型清单」计数徽标恒为空**：`index.html` 有 `#count-models`，但
  `renderNavCounts()` 从未赋值，导航上看起来像没有内容。现与总览页口径一致地补齐。

### 变更
- **派生字段不落盘**：`KeyRecord.modelBindings` 通过自定义 `CodingKeys` 排除在编解码之外。
  它由宿主配置实时算出，写进 `vault.json` 只会制造「配置改了但清单没更新」的脏数据；
  旧版 `vault.json` 仍可正常解码，无需迁移。

### 测试
- 测试从 49 项增至 **60 项 / 13 个套件**：新增 DSH 设置解析、凭据占用解析、模型身份归一、
  跨宿主聚合、网关 base_url 提取、端点同源判断、供给绑定两条依据（含「都不命中不猜测」）、
  概览计算、旧 `vault.json` 向后兼容，以及 YAML 幂等护栏。

---

## [1.3.0] — 2026-09-22

### 新增
- **模型清单页（可视化来源）**：新增「模型清单」页面，把 `~/.codex/codex-gateway-models.json` 里的条目逐条列出，
  标注来源（**公司网关** / **Codex 官方**）、slug、菜单可见性与说明；支持新增网关模型、
  一键切换「菜单可见 / 隐藏」、删除网关条目（官方条目不可删）。CLI 同步提供
  `keyinject models list|add|show|hide|rm`。
  此前这段模型清单只由 codex-gateway 与本工具的注入流程隐式写入，界面里看不到来源，现已全部可视化。
- **路由常驻守护（launchd 心跳）**：`keyinject gateway install-agent [--interval 10] [--home <CODEX_HOME>]`
  安装 `com.aki4ever.keyinjector.gateway-guard`，每 10 秒执行一次体检，发现 `model_provider`
  被桌面端改回官方 provider 就自动修复并写日志（`~/Library/Logs/keyinjector-gateway-guard.log`，
  仅在真正修复时写行）。`uninstall-agent` 一键卸载。CLI 复制到 `~/.local/bin/keyinject` 作为稳定路径。
- **模型清单页内置路由体检卡**：红/绿状态 + 「修复路由」按钮，手动兜底。

### 修复
- **孤儿受管标记清理**：Codex 桌面端重写 `config.toml` 时会吞掉 `# END CODEX-GATEWAY DESKTOP`
  这类注释行，导致修复后残留 `# BEGIN` / `# END` 孤儿标记（曾实测出现两个 BEGIN）。
  新增 `normalizeManagedBlock` 按状态机清理孤儿标记，且**路由正确时也会自动收敛**，
  不再需要人工修配置。
- **`CODEX_HOME` 支持**：`keyinject gateway check/repair` 与注入时的目录同步现在都会尊重
  `CODEX_HOME` 环境变量（此前硬编码 `~/.codex`），便于用沙箱目录做隔离验证。

### 变更
- 守护日志改为自行落盘（`--log`），不再依赖 launchd 的 stdout 重定向（此前因全缓冲导致日志为空）。
- 回归测试 46 → 49 项（新增孤儿标记清理、模型目录写入及当前门禁回归覆盖）。

## [1.2.0] — 2026-09-22

### 修复
- **Codex 桌面端切换公司网关模型后报 “model is not supported when using Codex with a ChatGPT account”**：
  - **根因**：桌面端顶部模型菜单把 `model` 改成 `ark/DeepSeek-V4.1-Flash` 或 `gemini-3.8-flash-high` 时，
    不会同步写 `model_provider`，`~/.codex/config.toml` 因此退回官方 `openai` provider，
    请求被发往 ChatGPT 后端，自定义模型名必然被拒（HTTP 400）。
  - **修复**：`InjectionEngine` 新增 provider 路由守护 `ensureCodexGatewayProviderRouting(_:catalogPath:)`，
    当 `model` 属公司网关模型而 `model_provider` 缺失或为 `openai` 时，自动补写受管区块
    `# BEGIN/END CODEX-GATEWAY DESKTOP`，把路由锁回 `codex_gateway`；只搬动 `model` 与
    `model_provider` 两个键，顶层其它设置（推理档位、沙箱、通知等）原样保留；
    用户显式指定的其它第三方 provider 不会被覆盖。
  - 注入落点命中 `~/.codex/config.toml` 时会自动执行该守护，杜绝再次静默失效。

### 新增
- **`keyinject gateway check|repair [--yes]`**：Codex 网关路由体检与一键修复（默认 dry-run，落盘前自动备份并写审计）。
- **回归测试 6 项**（`Codex 网关 provider 路由守护` 套件）：官方模型不动、缺 provider 补写、
  幂等、受管区块被改回 `openai` 时收敛、尊重第三方 provider、目录标记词识别。测试总数 40 → 46。

### 变更
- `model_reasoning_effort` 等顶层键不再受路由修复影响（修复只重排 `model` / `model_provider`）。

---

## [1.1.0] — 2026-09-22

### 新增
- **Codex 桌面端模型菜单无缝打通**：
  - 自动扩展生成 `~/.codex/codex-gateway-models.json`，将公司中间商网关所提供的 DeepSeek V4.1、Gemini 3.8 Flash 模型直接注册到 Codex 顶部下拉菜单中。
  - 保证 Codex 桌面端官方 ChatGPT OAuth 登录态与第三方网关模型完全兼容共存，绝不触发登录白屏报错。
- **本地高强度 AES-GCM 安全存储**：
  - 默认敏感数据存储切换为基于硬件随机主密钥的 AES-GCM 本地加密引擎，彻底杜绝 macOS 系统的钥匙串授权密码弹窗骚扰，实现全流程 0 弹窗无感操作。
- **极简「⚡ 一键注入生效」流转**：
  - 移除繁琐的多步操作，顶部直观大按钮一键完成自动择优匹配、Dry-run 校验、自动备份、原子写入与读回校验。
- **落点净化**：
  - 彻底清洗 8 个冗余干扰落点，精简为专为 DSH 桌面端与 Codex 打造的双宿主矩阵。

## [1.0.0] — 2026-09-22

首个可交付版本。对应 DSH 任务 `[D001][78分] 密钥注入器立项`。

### 新增

**密钥管理**
- 支持 8 家 AI 厂商预设：OpenAI、Anthropic (Claude)、DeepSeek、Google、OpenRouter、Moonshot、智谱、自定义
- 三档密钥后端：macOS 钥匙串（默认，系统加密）、本地加密文件（ChaChaPoly + 0600 权限主密钥，明确标注为降级方案）、内存（测试与演示用）
- 密钥索引仅保存掩码与 SHA-256 短指纹，明文不落明文文件
- 密钥别名、优先级、标签、备注、启用/禁用状态管理

**配置注入**
- 支持 6 种配置格式定点注入：dotenv、shell 启动脚本（受管区块）、JSON、YAML、TOML、plist
- JSON 采用 UTF-8 字节偏移定点扫描器，**保持原文件键序与缩进**；键路径缺失时拒绝而非新建
- 9 个内置注入落点：Shell 启动脚本、Claude Code、Codex CLI、项目 .env、自定义 JSON/YAML/TOML/plist、仅导出片段
- 全部落点附带反例说明（明确告知不适应场景）

**安全机制**
- 两阶段注入：先生成 dry-run 计划核对差异，显式确认后才写入
- 写入前自动备份（毫秒级时间戳 + 冲突自增后缀，同秒连续备份不互相覆盖）
- 原子替换：同目录临时文件 → `replaceItemAt`，保留原文件权限位，不留半截文件
- 写后读回校验内容并计算指纹，不一致即判失败
- 精确回滚：已有文件还原备份，当初新建的文件删除该文件
- 六类安全闸门：受管区块标记不成对、JSON 键路径缺失、路径不可写、文件被外部修改、密钥与落点不匹配、必填路径为空 —— 一律阻断报错
- 密钥明文永不进入日志、审计、JSON 输出与会话上下文

**健康探测**
- 按落点厂商配置鉴权头风格（`bearer` / `x-api-key`）
- 状态分类：有效(200) / 无效(401,403) / 额度限流(402,429) / 网络不通 / 未知
- 仅在用户显式触发时发起请求，不做后台轮询；测试使用 Mock 传输层，绝不发真实网络请求

**审计日志**
- JSONL 追加写入，永不改写历史
- 记录密钥增删启停、注入、回滚、探测；含时间戳、目标文件、备份路径、指纹
- 可从任意一条注入记录直接发起回滚

**界面**
- 桌面应用：AppKit 外壳 + WKWebView + 原生 HTML/CSS/JS 前端（无 Node 构建链）
- 五大功能区：密钥库、注入中心、健康探测、审计日志、设置与说明
- 差异视图、状态徽标、掩码显示与「显示明文」显式开关、深色/浅色自适应

**命令行**
- `keyinject` CLI：`info` / `providers` / `targets` / `keys` / `inject` / `rollback` / `check` / `audit` / `config`
- 全部子命令支持 `--json` 结构化输出，供 DSH 会话解析
- `keys add` 支持 `--secret-stdin` 从标准输入读入，避免明文进入 shell 历史
- 退出码约定：`0` 成功 / `1` 失败 / `2` 被安全策略阻断

**工程与交付**
- 零外部依赖，仅使用系统 SDK，可在仅装 Command Line Tools 的机器上构建
- 38 项自动化测试 / 10 个测试套件，含备份重名回归测试
- 质量门禁 `scripts/run_tests.sh`（动态注入 swift-testing 宏插件路径，保证重复运行稳定）
- 打包链路 `scripts/build_app.sh` + `scripts/build_dmg.sh`（ad-hoc 签名，`hdiutil verify` 通过）
- 版本一致性门禁 `scripts/check_version_sync.sh`
- 页面视觉台账 6 张（应用内 WKWebView 快照，四段式命名）
- 需求台账、架构说明、DSH 技能包 `skills/keyinject/SKILL.md`

### 修复

- **备份文件重名缺陷**：早期备份文件名使用秒级时间戳，同一秒内连续两次备份会导致
  `NSCocoaErrorDomain Code=516 文件已存在` 而注入失败。改为毫秒级时间戳
  （`yyyyMMdd-HHmmss-SSS`）并增加冲突自增后缀，同时补充回归测试
  「同秒内连续备份不互相覆盖」。
- 侧边栏计数徽标在数值为空时仍渲染出空胶囊的视觉缺陷（改为无值时隐藏）。
- 设置页要点符号与正文被键列拉开、符号悬空的排版缺陷（改用专用要点行样式）。
- 注入目标初始化参数顺序导致的 4 处编译错误（`isCustom` 须先于 `note`）。
- `Service.swift` 中一处不必要的可变变量声明告警。

### 已知限制

- YAML/TOML 为定点行替换，不支持多层嵌套、流式写法、内联表与数组表
- JSON 只做定点替换，不会新建键路径
- plist 仅支持扁平键名
- Shell 落点仅适用于 sh / bash / zsh，fish 与 csh 需自定义落点
- 应用为 ad-hoc 签名，首次打开需在「隐私与安全性」中手动放行一次
- 16×16 图标尺寸下笔画偏糊（纯标准库绘制所致）
- 健康探测结果仅代表「此刻鉴权是否通过」，不代表模型可用性或余额充足

### 环境适配说明

本机为 macOS 26.6.2 / arm64，**仅安装 Command Line Tools，无完整 Xcode**，实测调整如下：

- **SwiftUI 不可用**：工具链缺 `SwiftUIMacros` 插件，而该 SDK 中 `@State`/`@Binding` 等均为宏实现，
  编译必然失败。界面改用 AppKit + WKWebView + 原生前端。
- **XCTest 不可用**：工具链不含 XCTest，测试统一改用 swift-testing。
- **SPM 增量编译漏传测试宏插件路径**，导致第二次起误报 `TestingMacros not found`；
  门禁脚本动态探测插件目录并显式传入。
- **`screencapture` 被系统隐私权限拒绝**（未授予屏幕录制），页面台账改用应用内
  `WKWebView.takeSnapshot`，只捕获页面内容且无需系统权限。
