# 需求台账 — KeyInjector · 账号管理器

> **实施版本**：`v2.0.0`　|　**建档日期**：2026-09-22　|　**最后更新**：2026-09-22
> **需求来源**：用户口述需求「项目初始化」+ 五轮澄清（注入器语义、交付形态、模型清单归并、显示层改名与三维度展示）
> **合规依据**：元规则第一条（需求登记）、第八条（骨架优先与目录规范）、第九条（原子性与交付）

---

## 一、需求确认过程

| 轮次 | 待确认事项 | 用户选择 | 对方案的影响 |
| :--- | :--- | :--- | :--- |
| 1 | 「注入器」的确切语义 | **AI API Key 注入器** | 确定为「集中保管密钥 + 注入第三方工具配置文件」，含多 Key 轮换与额度/失效探测 |
| 2 | 交付形态 | **桌面可视化工具，打包成 dmg** | 必须产出可双击运行的 `.app` 与可分发的 `.dmg`，而非仅 CLI |
| 3 | 远程仓库地址 | **由我创建** | 需独立建仓并推送，遵守元规则第二十条「一项目一仓库」 |
| 4 | 模型清单与密钥库的关系（v1.4.0） | **并入密钥卡 + 保留总览页**；键名错配一并修复；改代码+测试+重建产物 | 需要新增跨宿主模型源读取与「密钥↔模型」绑定；DSH 落点键名改为以宿主声明为权威 |
| 5 | 项目改名与三维度展示（v2.0.0） | **显示层改名「账号管理器」**（内部标识符保留以保兼容）；密钥页按知识库展示**模型名称 / 剩余额度 / 更新日期**；模型清单**并入**密钥标签页 | 改名只动用户可见文本与产物名，不动 Swift 包名/可执行名/环境变量；核心层需新增模型时间字段与额度探测；界面由 7 个标签页精简为 6 个 |

---

## 二、需求清单

状态图例：`✅ 已实施并验证`　`🟡 部分实施`　`⛔ 明确不做（含理由）`

### REQ-001 · 密钥集中保管

| 项 | 内容 |
| :--- | :--- |
| **状态** | ✅ 已实施并验证 |
| **实施版本** | v1.0.0 |
| **需求描述** | 支持录入多家 AI 厂商的 API Key，密钥明文不落明文文件，列表仅显示掩码与指纹 |
| **验收断言** | ① 明文存于 macOS 钥匙串，`vault.json` 仅含掩码与 SHA-256 短指纹；② 专项测试断言 `vault.json` 与 `audit.jsonl` 全文不含明文；③ 界面默认显示 `sk-d…7890` 形式掩码 |
| **验证证据** | `Tests/KeyInjectorCoreTests` 密钥仓库测试组；`docs/screenshots/Page_KeyInjector_Keys_Default.png` |

### REQ-002 · 多厂商预设目录

| 项 | 内容 |
| :--- | :--- |
| **状态** | ✅ 已实施并验证 |
| **实施版本** | v1.0.0 |
| **需求描述** | 内置常见大模型厂商预设（鉴权头风格、环境变量名、API 基址、申请入口） |
| **验收断言** | ① 内置 8 家厂商：OpenAI / Anthropic / DeepSeek / Google / OpenRouter / Moonshot / 智谱 / 自定义；② 每家均带可编辑说明与反例提示；③ 厂商目录完整性测试全绿 |
| **验证证据** | `config/providers.json`（8 条）；`Sources/KeyInjectorCore/Models/Catalogs.swift` |

### REQ-003 · 多格式配置注入

| 项 | 内容 |
| :--- | :--- |
| **状态** | ✅ 已实施并验证 |
| **实施版本** | v1.0.0 |
| **需求描述** | 将密钥写入第三方工具配置文件，覆盖 dotenv / shell 启动脚本 / JSON / YAML / TOML / plist 六种格式 |
| **验收断言** | ① 六种格式均有定点补丁实现；② JSON 补丁保持原键序与缩进，缺失键路径直接拒绝而非新建；③ shell 补丁使用受管区块且重复执行幂等；④ 专项测试覆盖全部格式 |
| **验证证据** | `Sources/KeyInjectorCore/Injector/Injector.swift` `ContentPatcher`；注入器测试组 |

### REQ-004 · 默认预览、显式写入

| 项 | 内容 |
| :--- | :--- |
| **状态** | ✅ 已实施并验证 |
| **实施版本** | v1.0.0 |
| **需求描述** | 任何写入动作都必须先给出差异预览，且需显式确认才落盘 |
| **验收断言** | ① CLI `inject` 不加 `--yes` 只输出计划；② 界面必须点「生成注入计划」后「确认写入」按钮才出现；③ 实测对用户真实 `~/.zshrc` 执行 dry-run 后文件修改时间与内容均未变化 |
| **验证证据** | 实测记录：`~/.zshrc` mtime 保持 `Jul 15 19:42:53 2026`，无受管区块 |

### REQ-005 · 备份与一键回滚

| 项 | 内容 |
| :--- | :--- |
| **状态** | ✅ 已实施并验证 |
| **实施版本** | v1.0.0 |
| **需求描述** | 写入前自动备份，支持从界面或 CLI 精确回滚任意一次注入 |
| **验收断言** | ① 备份文件名含毫秒时间戳，同秒内连续备份不互相覆盖（回归测试覆盖）；② 已有文件回滚即还原备份内容；③ 当初新建的文件回滚即删除该文件；④ 回滚动作本身写入审计日志 |
| **验证证据** | 回归测试「同秒内连续备份不互相覆盖」；端到端测试组 |

### REQ-006 · 写入安全（原子性与校验）

| 项 | 内容 |
| :--- | :--- |
| **状态** | ✅ 已实施并验证 |
| **实施版本** | v1.0.0 |
| **需求描述** | 写入不得产生半截文件，且必须验证写入结果正确 |
| **验收断言** | ① 同目录临时文件 → `replaceItemAt` 原子替换；② 保留原文件权限位；③ 写后立即读回比对并输出指纹；④ 脏数据（受管区块标记不成对）直接阻断 |
| **验证证据** | 原子写入测试组（权限保持、无临时文件残留）；`AtomicWriter` |

### REQ-007 · 密钥有效性探测

| 项 | 内容 |
| :--- | :--- |
| **状态** | ✅ 已实施并验证 |
| **实施版本** | v1.0.0 |
| **需求描述** | 一键探测密钥是否有效，区分「无效 / 额度限流 / 网络不通」，支持批量探测 |
| **验收断言** | ① 200 → 有效；401/403 → 无效；402/429 → 额度限流；404 及其他 → 未知；② 支持 `bearer` 与 `x-api-key` 两种鉴权头风格；③ 仅在显式点击时发起请求，不做后台轮询 |
| **验证证据** | 健康探测测试组（MockTransport 分类与鉴权头断言） |

### REQ-008 · 审计日志

| 项 | 内容 |
| :--- | :--- |
| **状态** | ✅ 已实施并验证 |
| **实施版本** | v1.0.0 |
| **需求描述** | 记录密钥新增/删除/启停、注入、回滚、探测等全部操作，可追溯 |
| **验收断言** | ① JSONL 追加写入，永不改写历史；② 每条含时间戳、动作、结果、目标文件、备份路径、指纹；③ 绝不记录明文 |
| **验证证据** | 审计测试组；`docs/screenshots/Page_KeyInjector_Audit_Default.png` |

### REQ-009 · 桌面可视化界面

| 项 | 内容 |
| :--- | :--- |
| **状态** | ✅ 已实施并验证 |
| **实施版本** | v1.0.0 |
| **需求描述** | 提供图形界面完成密钥管理与注入操作，无需命令行 |
| **验收断言** | ① 五大功能区（密钥库/注入中心/健康探测/审计日志/设置）均可交互；② 页面截图 6 张已入账；③ 打包后的 `.app` 能从 bundle 内加载前端资源并正常渲染 |
| **验证证据** | `docs/screenshots/` 6 张页面台账截图；打包应用实测启动并出图 |

### REQ-010 · DMG 分发

| 项 | 内容 |
| :--- | :--- |
| **状态** | ✅ 已实施并验证 |
| **实施版本** | v1.0.0 |
| **需求描述** | 打包成可分发安装的 dmg 镜像 |
| **验收断言** | ① 产出 `dist/KeyInjector-1.0.0.dmg`；② `hdiutil verify` 校验通过；③ 挂载后含应用本体与 `/Applications` 快捷方式；④ 镜像内应用签名校验通过 |
| **验证证据** | 实测挂载输出；`hdiutil verify` 通过 |

### REQ-011 · 命令行基座（DSH 联动）

| 项 | 内容 |
| :--- | :--- |
| **状态** | ✅ 已实施并验证 |
| **实施版本** | v1.0.0 |
| **需求描述** | 提供可被 DSH 会话直接调用的命令行工具，与界面共用核心逻辑 |
| **验收断言** | ① 子命令 `info/providers/targets/keys/inject/rollback/check/audit/config` 全部可用；② 全部支持 `--json`；③ 退出码 0/1/2 语义明确；④ 应用包内一并内置该 CLI |
| **验证证据** | `keyinject --help` 实测输出；`dist/Key注入器.app/Contents/Resources/bin/keyinject` 可执行 |

### REQ-012 · 配置可覆盖（免重编译）

| 项 | 内容 |
| :--- | :--- |
| **状态** | ✅ 已实施并验证 |
| **实施版本** | v1.0.0 |
| **需求描述** | 第三方工具路径随版本变化时，用户应能自行调整而无需重新编译 |
| **验收断言** | ① 数据目录下 `config/providers.json`、`config/targets.json` 可覆盖内置预设（同 id 覆盖，新 id 追加）；② 界面提供「导出配置模板」按钮 |
| **验证证据** | `config/` 模板（8 厂商 + 9 落点）；`ConfigStore.merged(with:)` |

### REQ-013 · 自动化测试质量门禁

| 项 | 内容 |
| :--- | :--- |
| **状态** | ✅ 已实施并验证 |
| **实施版本** | v1.0.0 |
| **需求描述** | 核心逻辑必须有自动化测试覆盖，且提供可重复运行的门禁脚本 |
| **验收断言** | ① 当前门禁实测 80 项测试分 18 个测试套件；② `scripts/run_tests.sh` 重复运行稳定全绿；③ 出现任何失败或错误即返回非零退出码 |
| **验证证据** | 连续 3 次全绿运行记录；`reports/test-report.log` |

### REQ-014 · 桌面应用图标

| 项 | 内容 |
| :--- | :--- |
| **状态** | 🟡 部分实施 |
| **实施版本** | v1.0.0 |
| **需求描述** | 提供符合 macOS 规范的应用图标 |
| **验收断言** | ① 1024×1024 PNG 与 `.icns`（10 种尺寸）已生成并打入应用包；② 使用系统 `sips` + `iconutil` 标准流程 |
| **未达成部分** | 16×16 极小尺寸下笔画偏糊（无 Pillow，纯标准库 SDF 绘制所致）。不影响实际使用观感，已在 README 如实说明。 |
| **验证证据** | `assets/AppIcon.icns`（356,745 字节）；`scripts/gen_icon.py` |

### REQ-015 · 与 DSH 宿主深度集成

| 项 | 内容 |
| :--- | :--- |
| **状态** | ✅ 已实施并验证 |
| **实施版本** | v1.0.0 |
| **需求描述** | 按元规则第十八条，项目须至少集成一项真实可验证的 DSH 能力 |
| **验收断言** | ① CLI 基座可被 DSH `bash` 工具调用并返回结构化 JSON；② 交付 Agent Skill 技能包；③ 多智能体协同用于独立子任务 |
| **验证证据** | `skills/keyinject/SKILL.md`；CLI `--json` 实测输出 |

### REQ-016 · 跨宿主模型清单与密钥库整合

| 项 | 内容 |
| :--- | :--- |
| **状态** | ✅ 已实施并验证 |
| **实施版本** | v1.4.0 |
| **需求描述** | 用户反馈「注入器没有显示 gemini3.8 与 ds 4.1，为什么这边模型获取显示的是这两个模型」，并要求「应该从注入器的密钥库中就能获取模型清单，把当前的模型清单和密钥库整合」 |
| **归因结论** | 两处模型名来自**两个互不相通的数据源**：DSH 桌面端读 `harness/settings.yaml` 的 `llm-pi-ai.providers.*.models`（5 条，人工手写）；「模型清单」页此前只读 `~/.codex/codex-gateway-models.json` 且只保留网关条目（2 条）。注入器源码对 `settings.yaml` 零引用，因此 DSH 侧的模型从未进入视野；另外侧边栏 `#count-models` 徽标在 `renderNavCounts()` 中从未赋值，恒为空 |
| **验收断言** | ① `HostModelInventory.all()` 同时读到 DSH 与 Codex 两个宿主的模型记录；② `ModelIdentity.normalize` 使 `DS/DeepSeek V4.1 Flash` 与 `ark/DeepSeek-V4.1-Flash` 归一到同一身份，总览页显示为「跨宿主同一模型」；③ 密钥卡内嵌「供给模型」区块，按宿主分组并标注凭据键名与绑定依据；④ 绑定依据只有「凭据键名」与「端点同源」两条，都不命中时如实显示「未绑定」而非猜测；⑤ 注入器只读 `settings.yaml`，绝不写入 |
| **验证证据** | `Sources/KeyInjectorCore/Models/HostModelCatalog.swift`；`keyinject hosts list` / `hosts keys` 实测输出；`docs/screenshots/Page_KeyInjector_Keys_ModelsExpanded.png`、`..._Models_Default.png` |

### REQ-017 · 落点键名以宿主声明为权威

| 项 | 内容 |
| :--- | :--- |
| **状态** | ✅ 已实施并验证 |
| **实施版本** | v1.4.0 |
| **需求描述** | 修复 DSH 落点键名错配导致的静默失效，并消除 YAML 幂等缺口 |
| **缺陷描述** | ① `dsh-desktop` 落点静态登记 `itemKey: DEEPSEEK_API_KEY`，而 DSH 实际读取 `settings.yaml` 中 `apiKeyEnv` 声明的 `MIDPRO_API_KEY`——注入器「成功写入一个宿主不读的键名」，不报错但宿主拿不到密钥；② `patchYAML` 对 `KEY: sk-xxx` 与 `KEY: "sk-xxx"` 一律重写为带引号形式，产生「空操作注入」与无意义备份、假差异行 |
| **验收断言** | ① `resolvedTargetItemKey` 优先返回宿主声明的键名，落点静态值仅作回退；② dry-run 在真正发生键名变更时提示差异，空操作时不再吓唬用户；③ YAML 同值（忽略引号差异）时原样返回，测试断言 `patchYAML(...) == original`；④ `KeyRecord.modelBindings` 经自定义 `CodingKeys` 排除在编解码之外，旧 `vault.json` 仍可解码 |
| **验证证据** | `Service.resolvedTargetItemKey` / `targetKeyMismatch`；`ContentPatcher.patchYAML` 幂等护栏；`keyinject inject --target dsh-desktop` dry-run 实测显示「注入键名: MIDPRO_API_KEY」 |

---

### REQ-018 · 模型清单以网关为唯一事实源

| 项 | 内容 |
| :--- | :--- |
| **状态** | ✅ 已实施并验证 |
| **实施版本** | v1.6.0 |
| **需求描述** | 工具不得内置任何模型名单与上游地址；模型清单与网关地址一律从网关自己的配置读取，并据此把差异同步到 DSH 与 Codex 两个客户端 |
| **缺陷描述** | 同一份模型名单此前在 `GatewayCatalog.swift`、`Injector.swift` 与已删除的 Python 兜底脚本里各存一份，上游地址写死 `http://192.168.1.200:8080/v1`、网关二进制写死 `/Users/linqiyu/Documents/ChatGPT/对接gemini/bin/codex-gateway`。网关新增模型后必须有人改代码并重新构建——这是最典型的「需要人工维护的地方」 |
| **事实源** | `~/.config/codex-gateway/config.json`（`CODEX_GATEWAY_HOME` 可覆盖）。网关自身即以该文件作为 `base_url` 与线路表的权威，`codex-gateway doctor --json` 与 `state --json` 读的也是它 |
| **验收断言** | ① 沙箱网关配置里新增一条线路后，`keyinject sync` 零代码改动即可发现并补齐差异；② 网关配置缺失时整体跳过同步并如实告警，不猜测任何模型名；③ DSH 侧默认只增不减，不得删除用户自建模型；④ merge 模式对既有行零字节改写（diff 只含新增行）；⑤ 重复执行同步报告「已一致」 |
| **反例保护** | 默认 `merge`（只增不减）。实测本机 DSH 声明 5 个模型而网关只声明 2 条线路，若按「以网关为准整体替换」将静默删除 3 个在用模型。`.replace` 仅在显式传入 `--prune` 时启用 |
| **验证证据** | `GatewayConfig.load` / `declaredModels` / `binaryPath`；`HostConfigSync.patchDshModels` / `syncCodexCatalog`；`keyinject sync`（dry-run 默认、`--yes` 落盘、写入前自动备份）；GUI「网关事实源」卡片 |

---

### REQ-019 · 密钥库按 key 别名分区

| 项 | 内容 |
| :--- | :--- |
| **状态** | ✅ 已实施并验证 |
| **实施版本** | v1.6.0 |
| **需求描述** | 用户反馈「我现在密钥库里有 2 个 key，麻烦帮我在这里做好分区；要根据 key 的名称进行名字分区，然后名字分区下列出该 key 可以获取的模型类型」 |
| **交互规则** | ① 以 key 别名（`label`）为分区名，一把 key 一个分区；② 分区标题行 = 折叠箭头 + 状态点 + 别名 + 厂商 chip + 「模型 N 个」计数 + 详情/识别模型按钮；③ 分区默认展开，折叠状态在会话内记忆；④ 分区内保留原有单卡布局与操作（编辑/探测/启停/删除）；⑤ 页头提供搜索框（按别名、厂商、模型名、端点、标签匹配）与「仅看未探测/异常」筛选 |
| **验收断言** | ① 实机 2 把 key 渲染为 2 个分区；② 折叠/展开不发起网络请求；③ 搜索一个词只留匹配分区，标题计数同步；④ 空库仍显示原空状态引导 |
| **实现要点** | 前端不再自己分组，而是直接消费后端 `keysGrouped`（与 CLI `keys --grouped` 同一口径），避免界面与命令行两套分组逻辑漂移；桥接不可用时退化为按别名就地分组 |
| **验证证据** | `Service.keyGroups()`；`web/app.js` `renderKeys` / `renderGroupHead`；`docs/screenshots/Page_KeyInjector_Keys_Default.png`；CLI `keyinject keys` 实测输出 `▸ Gemini( tftiphone@gmail.com )` / `▸ 公司AI综合` |

---

### REQ-020 · 从 key 自身端点识别可用模型（多级兜底）

| 项 | 内容 |
| :--- | :--- |
| **状态** | ✅ 已实施并验证 |
| **实施版本** | v1.6.0 |
| **需求描述** | 用户反馈「应该在密钥库这边可以识别出 key 有什么模型可以提供」，并选择实现方式为「探测该 key 的 /models 接口，并保留宿主映射作为兜底，如果没有检测出 key 请给出其他可以映射出模型的方案」 |
| **探测层级** | **T1 端点探测**：`GET {baseURL}{probePath}/models`，优先该 key 自定义 `baseURL`，否则厂商预设 `baseURL`；**T2 端点变体**：`/models`、`/v1/models`、去掉 `/v1` 的变体、厂商 `healthPath` 依次尝试；**T3 响应解析**：兼容 OpenAI `{"data":[{"id"}]}`、Gemini `{"models":[{"name"}]}`、Ollama `{"models":[{"name"}]}`、裸数组、以及键值映射五种形态，剥离 `models/` 前缀后去重；**T4 宿主映射兜底**：退回 `HostModelInventory.bindings`（凭据键名 + 端点同源）；**T5 名称推断兜底**：仅当供应商名相符、或端点同域、或宿主完全未标注且当前一条记录都没有时才给候选，一律标注「推断」 |
| **验收断言** | ① 公司AI综合 key 探测 `http://192.168.1.200:8080/v1/models` 成功，实测读回 20 条原始条目、去重后 19 个模型身份，来源标注「端点探测」；② Gemini key 探测返回 HTTP 401（该凭据不是 API Key 形态），来源自动降级并如实展示失败原因，列表不伪造；③ 五种响应形态各有单元测试（含畸形 JSON 不崩溃）；④ 探测是**显式动作**（按钮或 CLI），不做后台轮询；⑤ 不写任何宿主配置文件；⑥ 模型标识归一化后去重（`ark/DeepSeek-V4.1-Flash` 与 `DS/DeepSeek V4.1 Flash` 归为同一身份） |
| **无探测端点时的方案** | 详情页在无可探测端点时显式提示「这把 Key 目前没有可探测端点」，仍展示 T4/T5 结果并标注来源，不做静默空白 |
| **反例保护（实测踩坑）** | ① 曾出现「Gemini key 声称供给公司网关 5 个模型」的误绑：仅凭 DSH 落点键名 `MIDPRO_API_KEY` 与网关供应商 `apiKeyEnv` 同名就绑定，而该 key 端点与网关端点毫无关系。已改为**仅在端点同源、或凭据名出自该 key 自身厂商且端点属于该厂商官方域名时**才绑定，纯落点键名同名不再绑定；② T5 推断曾对跨厂商记录也产出候选（噪声），已收紧为必须有信号（供应商相符 / 端点同域 / 宿主完全未声明且无任何记录） |
| **验证证据** | `Models/ModelDiscovery.swift`（`ModelDiscovery.discover`、`ModelEndpointProbe.candidates/parseModels`）、`Models/HostModelCatalog.swift`（`bindings` 三条依据 + `endpointBelongsToProvider`）；`Tests/` 模型发现测试组 9 例 + 绑定安全护栏回归；CLI `keyinject models probe --id <id>` 实测；沙箱实测 `model-cache.json` 不含明文（仅掩码/指纹/模型名/端点/时间） |

---

### REQ-021 · key 详情视图

| 项 | 内容 |
| :--- | :--- |
| **状态** | ✅ 已实施并验证 |
| **实施版本** | v1.6.0 |
| **需求描述** | 用户反馈「点进 key 进去可以查看详情」 |
| **信息架构** | 全屏模态五段：① **身份**（别名、厂商、端点、掩码、指纹、优先级、启用状态、标签、备注、创建/更新时间）；② **健康探测**（状态、HTTP 码、延迟、探测时间、消息，并显式标注「只代表此刻鉴权是否通过，不代表额度与模型可用性」）；③ **可提供的模型**（来源标签 + 数量 + 识别说明 + 全量列表，逐条带依据）；④ **注入落点**（目标名、落点 ID、键名、文件路径、最近注入时间，来自审计的成功写入记录）；⑤ **最近审计记录**（该 key 相关的动作与说明） |
| **交互规则** | 卡片标题、卡片「详情」按钮、分区标题「详情」按钮三处均可进入；`Esc`、右上 ✕、底部「关闭」、点遮罩四种方式退出；模型行可一键复制模型 ID；底部「改为探测鉴权」与「重新探测模型」把两类动作分开展示，避免把「本 Key 通不通」与「本 Key 有哪些模型」混为一谈 |
| **验收断言** | ① 任一 key 均可进入详情，详情内模型数与分区摘要一致（实机同为 6 个）；② 详情内重新探测后列表与状态同步刷新；③ 详情不允许改写任何宿主配置（写入仍只收敛在注入中心与模型清单管理区） |
| **验证证据** | `Service.keyDetail(id:auditLimit:hostRecords:)`；`web/app.js` `openKeyDetail` / `renderKeyDetail`；`docs/screenshots/Page_KeyInjector_Keys_Detail.png`；CLI `keyinject key show --id <id>` |

---

### REQ-022 · 发现的缓存、CLI 与兼容

| 项 | 内容 |
| :--- | :--- |
| **状态** | ✅ 已实施并验证 |
| **实施版本** | v1.6.0 |
| **需求描述** | 让模型发现结果可复现、可脚本消费，且不破坏既有数据文件与既有命令行用法 |
| **缓存落盘** | 探测结果单独存于应用支持目录 `model-cache.json`（键为 key id，值为 `{fingerprint, probed, source, endpoint, httpStatus, fetchedAt, models[], note}`，权限 0600）；`KeyRecord.modelBindings` 仍为**不落盘的派生字段**（自定义 `CodingKeys` 排除），`vault.json` 结构零变更、旧文件可直接解码；key 被删除时同步清理其缓存条目 |
| **界面首帧只用缓存** | 打开密钥库只读缓存（`availableModels`），**不联网**；只有点「识别模型」/「全部识别模型」/详情内「重新探测模型」才发起真实请求（对应 NOT-008） |
| **新 CLI** | `keyinject keys --grouped`（按别名分区输出，含每把 key 的模型摘要）、`keyinject key show --id <id> [--probe]`（元数据 + 模型 + 落点 + 审计摘要）、`keyinject models probe (--id <id> \| --all)`（执行 T1–T5 并输出来源、端点、数量与依据） |
| **验收断言** | ① 三个子命令可用且输出可被脚本消费；② 缓存文件 grep 明文必为空；③ 旧 `vault.json` 无需迁移；④ `scripts/run_tests.sh` 与 `scripts/check_version_sync.sh` 通过 |
| **验证证据** | `Models/ModelDiscovery.swift` `DiscoveryCache`；`Sources/keyinject/CLI.swift` `runKeys` / `runKey` / `runModels`；CLI 沙箱实测（`KEYINJECTOR_HOME` 指向临时目录，`keys --grouped`、`models probe --id`、`key show --id` 全部通过） |

### REQ-023 · 项目改名：Key 注入器 → 账号管理器

| 项 | 内容 |
| :--- | :--- |
| **状态** | ✅ 已实施并验证 |
| **实施版本** | v2.0.0 |
| **需求描述** | 用户要求「项目更名，从 key 注入器改成账号管理器」 |
| **改名范围（已定）** | **只改显示层与交付物名**。需改：网页 `<title>` 与品牌标题、前端桥接报错文案、macOS 应用菜单项（关于 / 隐藏 / 退出）、窗口标题、`build_app.sh` 的 `APP_NAME` 与 CFBundleName/CFBundleDisplayName、`build_dmg.sh` 的卷名、`check_version_sync.sh` 内的产物路径校验、README 与需求台账标题。**保持不变**：Swift 包名 `KeyInjector`、模块 `KeyInjectorCore`、可执行名 `KeyInjectorApp` / `keyinject`、CLI 命令 `keyinject` 及其全部子命令、环境变量 `KEYINJECTOR_HOME`、应用支持目录、DMG 内部文件前缀 |
| **为何这样切** | 本工具的功能面已从「注入」扩到密钥库 / 模型识别 / 额度展示 / 审计，原标题名不副实；但 `keyinject` 命令已被技能包与既有脚本引用，`KEYINJECTOR_HOME` 已写进文档与测试，一并改名会造成静默破坏。故**对外改名、对内保兼容**，并在文档中如实标注这条边界 |
| **验收断言** | ① 界面标题、菜单、窗口标题显示「账号管理器」；② 打包产物为 `dist/账号管理器.app`，其 `Info.plist` 的 CFBundleName/DisplayName 为「账号管理器」；③ `scripts/check_version_sync.sh` 通过；④ `keyinject` 命令、`KEYINJECTOR_HOME` 环境变量行为零变化（旧脚本仍可用） |
| **验证证据** | `web/index.html`、`web/app.js`、`Sources/KeyInjectorApp/AppDelegate.swift`、`scripts/build_app.sh`、`scripts/build_dmg.sh`、`scripts/check_version_sync.sh` |

### REQ-024 · 模型三维度展示（名称 / 剩余额度 / 更新日期）

| 项 | 内容 |
| :--- | :--- |
| **状态** | ✅ 已实施并验证 |
| **实施版本** | v2.0.0 |
| **需求描述** | 用户要求「必须展示模型名称、模型剩余额度、模型更新日期」。**数据依据**：`docs/knowledge-account-protocols.md` 的官方协议调研（模型名三家都有；余额仅 DeepSeek 有 `/user/balance`；时间仅 OpenAI 有 `created` + `shutdown_date`） |
| **模型更新时间** | `AvailableModel` 新增 `identityTime: Date?`、`identityTimeSource: String`、`shutdownDate: String?`、`versionTag: String?`。`parseModels` 改为解析完整对象：OpenAI 形状取 `created`（秒级 Unix 时间戳）→ `identityTime`，来源标注「协议 · created」；另取 `shutdown_date` 为下线公告（字符串原样，不做日期解析）。DeepSeek 形状无时间字段 → 留空并标注「该协议不提供」。**Gemini `version` 只写入 `versionTag` 并在界面显示为「版本」，严禁当作更新时间** |
| **剩余额度** | 新增账号级 `BalanceInfo`（`isAvailable: Bool?`、`balances: [BalanceEntry]`（`currency` / `total` / `granted` / `toppedUp`，金额**字符串原样**）、`endpoint`、`httpStatus`、`note`、`fetchedAt`），存入 `ModelDiscoveryResult.balance?`。**仅当 provider 适配器判定为 DeepSeek 时**请求 `GET /user/balance`（含 T1/T2 端点变体），其余厂商直接跳过并把来源标为「该协议不提供」；429/402 时来源标为「错误码推断」 |
| **验收断言** | ① 每个模型行都展示名称 + 来源 + 更新时间（或「该协议不提供」）；② DeepSeek key 额外展示余额块（分币种、金额原样、含 `is_available` 布尔闸门）；③ 非 DeepSeek key 的额度位显示「该协议不提供」并给指路（Gemini → AI Studio / Cloud Console；OpenAI → 无余额端点）；④ 余额请求失败不影响模型清单展示；⑤ 单元测试覆盖：带 `created` 的 OpenAI 响应、无时间字段的 DeepSeek 响应、`created` 缺失、Gemini `version` 不被当时间 |
| **验证证据** | `Models/ModelDiscovery.swift`（`AvailableModel`、`ModelDiscoveryResult`、`parseModels`、`parseBalance`、`balanceEndpointCandidates`）；`Tests/KeyInjectorCoreTests` 三维度解析测试组 |

### REQ-025 · 密钥库与模型清单合并为「密钥」标签页（格式塔）

| 项 | 内容 |
| :--- | :--- |
| **状态** | ✅ 已实施并验证 |
| **实施版本** | v2.0.0 |
| **需求描述** | 用户要求「把模型清单和密钥库合并成密钥 tab，要遵循格式塔交互原理」 |
| **合并方式** | 左侧导航去掉「模型清单」页与页内「← 回到密钥库」按钮，只留一个「密钥」页：顶部为跨宿主总览折叠区（含网关同步操作），下方为按 key 别名分区的密钥卡列表，每张卡内联其模型清单 |
| **格式塔依据** | **邻近性**：一把 key 的模型紧贴该 key，不再跨页跳转；**相似性**：分区标题行与卡片标题行用同一套状态点 / chip / 徽标视觉语言；**共同区域**：分区用背景与圆角包裹，明确「同一 key 的东西在一个容器里」；**闭合性**：卡片默认折叠成摘要（名称 + 状态 + 模型数 + 额度摘要），需要细节时才展开；**连续性**：同一分区始终保持「标题 → 卡片 → 模型行」的纵向秩序；**图形-背景**：密钥身份信息（前景）与来源标注 / 时间（背景，弱色小字）分层，不抢主信息 |
| **验收断言** | ① 导航项不含「模型清单」，`switchPage('models')` 有兼容兜底；② 分区数据仍与 `keyinject keys --grouped` 同口径；③ 展开状态按 key id 记忆，搜索与筛选不丢状态；④ 密钥卡内模型行展示 REQ-024 的三维度 |
| **验证证据** | `web/index.html`（导航与页面骨架）、`web/app.js`（`renderKeys` / `renderKeyModels` / `renderModelsOverview` 合并）、`web/app.css` |

### REQ-026 · 通过密钥识别模型的三个维度

| 项 | 内容 |
| :--- | :--- |
| **状态** | ✅ 已实施并验证 |
| **实施版本** | v2.0.0 |
| **需求描述** | 用户要求「通过密钥可以识别出模型的名称、模型剩余额度、模型更新日期」——即点一把 key 的「识别模型」，应当同时拿到模型身份、时间维度与该账户的额度维度 |
| **实现要点** | `discover` 流程改为两段取证：① **模型段**（T1–T5，沿用既有五级兜底）解析名称与时间字段；② **额度段**（仅 DeepSeek 适配器）请求 `/user/balance`；两段的端点、HTTP 状态、失败原因**分别记录**，互不污染——模型段成功、额度段失败时，界面仍显示模型清单并单独标注额度不可得 |
| **验收断言** | ① DeepSeek 真 key：识别后可同时看到模型清单与账户余额；② 非 DeepSeek key：只做模型段，额度位如实标注；③ 额度段超时/失败不影响 `probed` 与模型列表；④ 缓存 `model-cache.json` 仍只含掩码、指纹、模型名、端点、时间与额度数值，**不含明文**（余额字段同样不落明文凭据） |
| **验证证据** | `Service.discoverModels` / `runDiscovery`；`Models/ModelDiscovery.swift`；CLI `keyinject models probe --id <id>` 输出含额度段小结 |


---

## 三、明确不做的事

| 编号 | 事项 | 为何不做 |
| :--- | :--- | :--- |
| NOT-001 | 全量 YAML/TOML 解析器 | 会引入外部依赖或大量自研代码，与「零依赖」原则冲突；本场景只需键值行替换，且定点替换更安全（不动其它内容） |
| NOT-002 | 自动联网同步密钥到云端 | 用户未要求，且会显著扩大攻击面；本工具定位为纯本机 |
| NOT-003 | 后台定时轮询密钥状态 | 会产生不可预期的网络请求；改为仅在用户显式点击时探测 |
| NOT-004 | 自动探测并改写未在内置预设中的第三方工具路径 | 未经核实就写别人的配置风险高；改为内置保守预设 + 用户可自填路径 + 配置模板覆盖 |
| NOT-005 | 应用公证（notarization）与开发者签名 | 需要付费 Apple 开发者账号，超出本次范围；已用 ad-hoc 签名并如实告知首次打开需手动放行 |
| NOT-006 | 改写 DSH 的 `settings.yaml`（增删模型、规范化 YAML） | 该文件含 onboarding、权限预设、默认模型等大量非本工具所有的字段，任何「顺手规范化」都会破坏用户既有配置；模型清单只读是硬约束 |
| NOT-007 | 依据模型探测结果自动改写 DSH `settings.yaml` 或 Codex 模型目录 | 沿用 REQ-018 的只读边界；自动增删他人配置会破坏用户既有设置。发现结果只用于展示与诊断 |
| NOT-008 | 后台定时轮询各 key 的 `/models` | 与「只在用户显式触发时联网」的既定边界（NOT-003）冲突，且网关侧可能计费或限流。首帧只读缓存，联网只在点击时 |
| NOT-009 | 内置硬编码的模型名单 | 与 REQ-018「模型清单以网关为唯一事实源」直接冲突；模型一律来自端点探测或宿主声明 |
| NOT-010 | 把推断结果（T5）当作事实展示 | 推断可能出错，必须以「推断」标签降权显示，且只在该记录确有信号时才产出候选，避免噪声误导用户 |

---

## 四、需求追踪矩阵

| 需求编号 | 实现位置 | 测试覆盖 | 界面入口 | 截图证据 |
| :--- | :--- | :--- | :--- | :--- |
| REQ-001 | `Storage/Storage.swift` | ✅ 仓库测试组 | 密钥库 | `..._Keys_Default.png` |
| REQ-002 | `Models/Catalogs.swift` | ✅ 目录完整性 | 新增密钥弹窗 | `..._Keys_AddDialog.png` |
| REQ-003 | `Injector/Injector.swift` | ✅ 注入器测试组 | 注入中心 | `..._Inject_DryRun.png` |
| REQ-004 | `InjectionEngine.plan` | ✅ 计划测试 | 注入中心 | `..._Inject_DryRun.png` |
| REQ-005 | `InjectionEngine.rollback` | ✅ 回滚测试组 | 注入中心 / 审计日志 | `..._Audit_Default.png` |
| REQ-006 | `Support/Support.swift` | ✅ 原子写入测试组 | — | — |
| REQ-007 | `Health/Health.swift` | ✅ 探测测试组 | 健康探测 | `..._Health_Default.png` |
| REQ-008 | `Storage/AuditLog` | ✅ 审计测试组 | 审计日志 | `..._Audit_Default.png` |
| REQ-009 | `Sources/KeyInjectorApp` + `web/` | 打包实测 | 全部 | 9 张截图 |
| REQ-010 | `scripts/build_dmg.sh` | `hdiutil verify` | — | — |
| REQ-011 | `Sources/keyinject` | CLI 实测 | — | — |
| REQ-012 | `ConfigStore` | ✅ 覆盖测试 | 设置与说明 | `..._Settings_Default.png` |
| REQ-013 | `Tests/` + `scripts/run_tests.sh` | — | — | — |
| REQ-014 | `scripts/gen_icon.py` | 图标实测 | — | — |
| REQ-015 | `skills/keyinject/SKILL.md` | CLI 实测 | — | — |
| REQ-016 | `Models/HostModelCatalog.swift` | ✅ 跨宿主清单测试组 | 密钥库（模型区块）/ 模型清单 | `..._Keys_ModelsExpanded.png`、`..._Models_Default.png` |
| REQ-017 | `Service.swift` / `ContentPatcher.patchYAML` | ✅ 键名解析测试组 | 注入中心 Dry-Run | `..._Inject_DryRun.png` |
| REQ-018 | `GatewayConfig` / `HostConfigSync` / `keyinject sync` | ✅ 网关配置与同步测试组 | 模型清单（网关事实源卡片） | `..._Models_Default.png` |
| REQ-019 | `Service.keyGroups()` / `web/app.js` `renderKeys` | ✅ 密钥库分区与详情测试组 | 密钥库（分区标题行、搜索、筛选、折叠） | `..._Keys_Default.png` |
| REQ-020 | `Models/ModelDiscovery.swift` / `HostModelCatalog.bindings` | ✅ 模型发现测试组（9 例）+ 绑定护栏回归 | 密钥库（识别模型按钮）/ 详情（重新探测模型） | `..._Keys_ModelsExpanded.png`、`..._Keys_Detail.png` |
| REQ-021 | `Service.keyDetail` / `web/app.js` `renderKeyDetail` | ✅ 密钥库分区与详情测试组 | 密钥库（卡片标题 / 详情按钮 / 分区详情按钮） | `..._Keys_Detail.png` |
| REQ-022 | `DiscoveryCache` / `Sources/keyinject/CLI.swift` | ✅ 模型发现测试组 | — | — |
