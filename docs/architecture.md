# 架构说明 — KeyInjector · 账号管理器

> **实施版本**：`v2.0.0`　|　**更新日期**：2026-09-22
> **本版要点**：显示层改名为「账号管理器」（内部包名 / CLI 命令保持不变）；新增模型三维度（名称 / 剩余额度 / 更新时间）的数据通路；「模型清单」页并入「密钥」页。

---

## 一、分层设计

```text
┌──────────────────────── 表现层 ────────────────────────┐
│  账号管理器.app (AppKit 外壳)       keyinject (CLI)     │
│   ├─ AppDelegate 窗口与菜单          ├─ 参数解析          │
│   ├─ Bridge (JS ↔ Swift 桥接)        ├─ 人类可读输出      │
│   └─ WKWebView ← web/ 前端资源        └─ --json 结构化输出 │
└──────────────────────┬─────────────────────────────────┘
                       │ 均只依赖 KeyInjectorService 门面
┌──────────────────────▼───── 服务层 ────────────────────┐
│  KeyInjectorService                                     │
│   provider/target 查询 · 密钥增删改查 · 计划 · 应用      │
│   回滚 · 探测 · 审计查询 · 运行时信息                    │
│   ├─ EndpointProtocol：端点级鉴权适配（Gemini 兼容端点） │
│   └─ runDiscovery：模型段 + 额度段两段独立取证           │
└──────────────────────┬─────────────────────────────────┘
┌──────────────────────▼───── 领域层 ────────────────────┐
│  KeyVault       InjectionEngine      HealthChecker      │
│  AuditLog       ContentPatcher       ProviderCatalog    │
│  AtomicWriter   BackupStore          TargetCatalog      │
│  DshModelCatalog HostModelInventory  CodexCatalogStore   │
│  ModelDiscovery  ModelMetadata · BalanceInfo · 端点候选  │
└──────────────────────┬─────────────────────────────────┘
┌──────────────────────▼───── 基础层 ────────────────────┐
│  SecretStore 协议：Keychain / File(ChaChaPoly) / Memory │
│  JSONScanner · LineDiff · Fingerprint · PathKit         │
└────────────────────────────────────────────────────────┘
```

**关键约束：表现层不得直接触碰文件或钥匙串。** 界面与 CLI 都只通过 `KeyInjectorService` 门面调用领域层，
这保证了「界面能做的事命令行一定也能做」，也让测试可以完全绕开 GUI 验证全部业务逻辑。

---

## 二、核心流程

### 2.1 注入流程（两阶段，默认 dry-run）

```text
① plan 阶段（只读）
   ├─ 解析落点与密钥 → 校验密钥存在、启用、厂商匹配
   ├─ 读原文件（不存在则记为「将新建」）
   ├─ 按格式生成新内容（ContentPatcher）
   │    ├─ json  → JSONScanner 按字节区间定点替换，保持键序与缩进
   │    ├─ dotenv → 行替换，缺失则追加
   │    ├─ shell → 受管区块（# >>> KeyInjector managed block >>>）整体替换/追加
   │    ├─ yaml/toml → 区块内键行替换或插入
   │    └─ plist → PropertyListSerialization 扁平键改写
   ├─ 计算行差异（LCS），并对差异中的明文做掩码
   ├─ 安全闸门校验（标记成对性、路径可写性、键路径存在性）
   └─ 输出 InjectionPlan（含 blocked / blockedReason / warnings）

② apply 阶段（显式确认后）
   ├─ 二次读取原文件并校验「计划生成后未被他人修改」
   ├─ 备份原文件（毫秒时间戳 + 唯一后缀）
   ├─ AtomicWriter 原子替换（同目录临时文件 → replaceItemAt）
   ├─ 写后读回校验并计算指纹
   └─ 写审计日志（成功/失败均记录）
```

### 2.2 回滚流程

```text
审计条目定位（按审计 id 或 落点+路径 取最近一次）
   ├─ 该次注入前文件已存在 → 还原备份内容
   └─ 该次注入是新建文件   → 删除该文件
   └─ 写审计日志（action=rollback）
```

---

## 三、宿主模型清单与密钥供给（v1.4.0）

```text
读取（全部只读，绝不写入宿主配置）
  ├─ DSH：harness/settings.yaml
  │    ├─ 缩进敏感解析 llm-pi-ai.providers.<id> → apiKeyEnv / baseURL / models[].id
  │    └─ harness/.credentials.yaml → refs 键名占用情况（只读键名，不读明文）
  └─ Codex：~/.codex/codex-gateway-models.json（网关条目）
       └─ ~/.codex/config.toml → [model_providers.codex_gateway].base_url

归一
  └─ ModelIdentity.normalize：剥掉 ark/ ds/ openai/ google/ anthropic/ 等命名空间前缀
       → DS/DeepSeek V4.1 Flash ≡ ark/DeepSeek-V4.1-Flash（同一模型的两个别名）

绑定（密钥 → 模型，命中其一即绑定）
  ├─ 依据① 凭据键名：宿主 apiKeyEnv 命中密钥厂商环境变量名或落点键名
  └─ 依据② 端点同源：宿主 baseURL ≡ 密钥自定义 Base URL
       → 两条都不命中：如实显示「未绑定」，不做猜测

消费
  ├─ 密钥库：每张密钥卡内嵌「供给模型」区块（按宿主分组，默认折叠）
  ├─ 模型清单页：跨宿主总览 + Codex 网关条目写入管理区（虚线分区，与只读清单隔开）
  └─ CLI：keyinject hosts list | hosts keys | keys（均带供给模型）
```

**反例边界**：注入器不写 `settings.yaml`。该文件含 onboarding、权限预设、默认模型等
非本工具所有的字段，任何「顺手规范化 YAML」都会破坏用户既有配置，因此只读是硬约束。

---

### 3.4 单一事实源：网关配置 → 两个客户端（v1.6.0）

```
~/.config/codex-gateway/config.json     ← 唯一权威（网关自己写的，不是本工具写的）
        │  base_url + models: { 线路名: 上游模型名 }
        ▼
  GatewayConfig.load()                  ← 全部读取都经此，代码里不再出现任何模型名
        │
        ├─ HostConfigSync.patchDshModels()   → DSH settings.yaml 的 models: 列表
        ├─ HostConfigSync.syncCodexCatalog() → ~/.codex/codex-gateway-models.json
        └─ keyinject gateway switch           → ~/.codex/config.toml 的 model / model_provider
```

**为什么是网关配置而不是本工具的登记表**：模型清单的**生产者**是网关——线路名到上游模型的映射
写在网关自己的配置里，网关启动时读的就是它。任何在客户端侧另存一份名单的做法，
都注定要在网关变更后人工同步。因此本工具把「读网关配置」定为唯一入口。

**降级姿势（宁可什么都不做，也不要写错）**：
- 网关配置读不到 / 格式不识别 → `isUsable == false`，同步整体跳过并告警，**不猜测模型名**；
- 网关二进制找不到 → 按「已登记的 `auth.command` → `CODEX_GATEWAY_BIN` → 常见位置 → `PATH`」
  依次探测，全都拿不到就不做依赖它的写入。

**默认只增不减**：`MergeMode.merge`（默认）对既有 YAML 行零字节改写，只插入缺失条目；
`MergeMode.replace`（`keyinject sync --prune`）才会删除。这条边界不是洁癖——
实测按「以网关为准整体替换」会删掉本机 3 个在用模型。

**写入安全**：定点改写 + 每次写入前自动备份到
`~/Library/Application Support/KeyInjector/backups/<目标名>/<时间戳>-<文件名>`。

---

### 3.5 模型发现：从「这把 Key 能提供什么」到界面（v1.6.0）

用户要的是「密钥库里就能看出这把 key 有什么模型可用」。数据来源按可信度从高到低逐级兜底，
每一级都有明确的可信度标注，**任何一级都不猜测后当作事实**：

```
T1 端点探测   GET {baseURL}{probePath}/models        ← 优先该 Key 自定义 Base URL
      ↓ 失败（404 / 非 JSON / 超时 / 鉴权失败）
T2 端点变体   /models、/v1/models、去掉 /v1 的变体、厂商 healthPath
      ↓ 全部失败
T3 响应解析   OpenAI data[] · Gemini models[].name · Ollama models[].name · 裸数组 · 键值映射
      ↓ 解析不到任何模型
T4 宿主映射   HostModelInventory.bindings（凭据键名 + 端点同源）   ← 可信度：宿主声明
      ↓ 无绑定
T5 名称推断   仅当「供应商相符 / 端点同域 / 宿主完全未声明且无任何记录」才产出  ← 可信度：推断
      ↓
仍未识别     界面如实说明「端点探测未成功，且宿主没有声明绑定」并给出失败原因
```

**绑定规则的三条依据（T4 的安全护栏）**：① 凭据键名命中**且端点同源**；② 端点同源；
③ 凭据名出自该 Key 自身厂商**且**该模型端点在厂商官方域名下。

> 反例（实测踩坑）：仅凭「落点键名同名」就把跨厂商模型算到这把 Key 头上，
> 曾让 Gemini Key 声称「供给公司网关 5 个模型」——而它的端点与网关毫无关系。
> 这类误绑是**静默误导**：用户会以为「换这把 Key 也能用这些模型」。因此护栏不可放松。

**缓存与联网边界**：
- 结果存 `model-cache.json`（键为 key id，含指纹、来源、端点、HTTP 码、时间、模型列表），
  权限 0600，**不含明文**；key 删除时同步清理。
- 打开密钥库时**只读缓存、不联网**；真实请求只发生在显式点击「识别模型」或 CLI 调用时。
- `KeyRecord.modelBindings` 仍是派生字段（自定义 `CodingKeys` 排除），`vault.json` 结构零变更。

**前端消费口径**：分区视图直接消费后端 `keysGrouped`，与 CLI `keyinject keys --grouped` 同一份数据，
避免界面与命令行出现两套分组逻辑。

---

## 四、关键设计决策

| 决策 | 选择 | 理由 |
| :--- | :--- | :--- |
| 界面技术栈 | **AppKit + WKWebView + 原生 HTML/CSS/JS** | 本机 CLT 工具链缺 `SwiftUIMacros`，SwiftUI 无法编译（详见 README 踩坑记录）。此方案同时获得更好的视觉可控性与热改效率，且**不需要 Node 构建链** |
| 依赖策略 | **零外部依赖** | 保证在无网络、只有 CLT 的机器上可复现构建；也避免供应链风险 |
| 配置改写方式 | **定点补丁，而非全量解析后重写** | 全量重写会丢失注释、键序与格式风格，还可能破坏第三方工具配置；定点补丁只动需要动的字节 |
| JSON 缺键处理 | **拒绝并报错，绝不新建键路径** | 向不认识的配置里凭空造结构，是破坏用户工具的高风险行为 |
| 密钥存储默认 | **macOS 钥匙串** | 系统级加密与访问控制；加密文件后端如实标注为降级方案 |
| 明文暴露控制 | **掩码 + 指纹为默认，明文需显式开关** | 降低截屏、日志、会话上下文泄漏风险 |
| 备份命名 | **毫秒时间戳 + 冲突自增后缀** | 早期用秒级时间戳导致同秒连续备份互相覆盖（真实缺陷，已修复并加回归测试） |
| 配置可覆盖 | **数据目录 JSON 覆盖内置预设** | 第三方工具路径随版本变化，不能让用户等新版本发布 |
| 宿主模型清单 | **两个宿主各自读取，归一后汇总** | DSH 与 Codex 的模型来自两处完全不同的配置，不存在单一权威源；只读不写，避免破坏用户配置 |
| 落点键名 | **宿主声明优先，落点静态值仅回退** | DSH 落点曾硬编码 `DEEPSEEK_API_KEY` 而宿主实读 `MIDPRO_API_KEY`，造成「注入成功但宿主读不到」的静默失效 |
| 密钥↔模型绑定 | **两条依据（凭据键名 / 端点同源），都不命中即不猜** | 宁可如实显示「未绑定」，也不把模型硬塞给某个密钥而误导用户 |
| 派生数据落盘 | **`modelBindings` 排除在 Codable 之外** | 它由宿主配置实时算出，落盘会制造「配置改了但清单没更新」的脏数据；旧 `vault.json` 仍可解码 |

---

## 五、数据文件

数据根目录：`~/Library/Application Support/KeyInjector/`（可用环境变量 `KEYINJECTOR_HOME` 覆盖）

| 文件 | 内容 | 是否含明文 |
| :--- | :--- | :--- |
| `vault.json` | 密钥索引：id、厂商、别名、掩码、指纹、优先级、标签、启用状态、最近探测结果 | **否** |
| 系统钥匙串 | 密钥明文（服务名 `com.aki4ever.keyinjector`） | 是（系统加密保护） |
| `audit.jsonl` | 追加式审计日志，每行一条 JSON | **否** |
| `backups/<落点>/<时间戳>-<文件名>` | 注入前备份 | 视原文件而定 |
| `backups/<落点>/<时间戳>-<文件名>.meta.json` | 备份元信息（对应落点、原路径、指纹、审计 id） | **否** |
| `config/providers.json`、`config/targets.json` | 可选覆盖配置 | 否 |
| `settings.json` | 界面与后端偏好 | 否 |

---

## 六、安全闸门清单

以下情形一律**阻断写入并报错**，不做任何猜测性修复：

1. 受管区块起始/结束标记不成对（避免把文件切坏）；
2. JSON 目标键路径不存在；
3. 目标路径是目录，或父目录不可写；
4. 计划生成后原文件被外部修改（防止覆盖他人改动）；
5. 密钥不存在、已禁用或与落点厂商不匹配；
6. 落点需要路径但用户未提供。

---

## 七、测试策略

- **92 项测试 / 20 个测试套件**，全部为行为级测试，使用真实临时目录与真实文件读写，不使用 mock 文件系统。
- 唯一被替换的是网络层：`HTTPTransport` 协议 + 测试用 `MockTransport`，保证测试**绝不发出真实网络请求**。
- 门禁脚本 `scripts/run_tests.sh` 显式传入测试宏插件路径（否则 SPM 增量编译会漏传导致误报失败），
  并在结束后检查测试摘要存在且无失败标记，否则返回非零退出码。
- 所有环境隔离：测试使用 `KEYINJECTOR_HOME` 指向临时目录，**不触碰真实用户数据**。

---

## 八、已知技术债

| 编号 | 内容 | 影响 | 计划 |
| :--- | :--- | :--- | :--- |
| TD-001 | 16×16 图标笔画偏糊 | 观感，极小尺寸下可辨性下降 | 后续引入矢量绘制或手工调整小尺寸 |
| TD-002 | YAML/TOML 不支持多层嵌套与内联写法 | 复杂配置需改用 JSON 落点 | 视实际需求评估，保持零依赖前提下自研子集 |
| TD-003 | 界面无多语言 | 目前全中文 | 用户为中文使用者，暂不需要 |
| TD-004 | ad-hoc 签名需用户手动放行一次 | 首次打开多一步操作 | 需付费开发者账号方可公证 |
| TD-005 | 健康探测依赖厂商端点路径，可能随厂商调整而失效 | 探测结果可能失真 | 探测失败会明确报「未知」而非误判为「无效」，路径可由配置覆盖 |
