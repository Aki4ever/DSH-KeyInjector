# KeyInjector 项目接手状态

> 记录编号：`R55`　|　现场日期：2026-09-22　|　版本：`v1.6.0`
> 本文是接手盘点快照；进程、磁盘、网关额度与 Codex 账户能力会随环境变化，使用前应重新读回。

---

# v2.0.0 快照：账号管理器（在 v1.6.0 之上的增量）

> 追加日期：2026-09-22　|　门禁：版本一致性通过、`99 tests / 20 suites` 全绿、应用与 DMG 已重建

## 本轮四件事

| # | 需求 | 状态 | 证据 |
| :--- | :--- | :--- | :--- |
| 1 | 项目更名（Key 注入器 → 账号管理器） | ✅ | 标题栏、菜单、窗口标题、产物名、DMG 卷标全部改名；实机确认标题为「账号管理器 v2.0.0」 |
| 2 | 展示三维度（模型名称 / 剩余额度 / 更新日期） | ✅ | 新增 `ModelMetadata` / `BalanceInfo`；实测 19 个模型中 16 条协议自带 `created` 已解析 |
| 3 | 模型清单与密钥库合并为「密钥」页（格式塔） | ✅ | 导航 6 → 5 项；跨宿主总览收进密钥页顶部 `<details>`，摘要行常显 |
| 4 | 通过密钥识别三维度 | ✅（受凭据形态限制） | 自定义网关密钥实测成功；Gemini 密钥因凭据形态返回 401，界面如实降级 |

## 改名边界（兼容性红线）

| 已改（用户可见） | 未改（接口，故意保留） |
| :--- | :--- |
| 网页标题与品牌区、应用菜单、窗口标题 | Swift 包名 `KeyInjector`、模块 `KeyInjectorCore` |
| 应用包 `dist/账号管理器.app` | 可执行名 `KeyInjectorApp` / `keyinject` |
| DMG 卷标与文件名 `账号管理器-2.0.0.dmg` | 环境变量 `KEYINJECTOR_HOME`、数据目录 `…/Application Support/KeyInjector/` |

理由：`keyinject` 已被技能包与既有脚本引用、`KEYINJECTOR_HOME` 已写进测试，一并改名会造成静默破坏。边界记入 REQ-023。

## 三维度实测数据（非推断）

| 维度 | 实测结果 |
| :--- | :--- |
| 模型名称 | 公司AI综合端点 20 条原始条目 → 去重 19 个模型身份 |
| 更新日期 | 16 条带 `created`（显示「更新时间 2026-09-22」）；3 条协议未给（显示「该协议不提供」） |
| 剩余额度 | 本机 2 把密钥（Google / 自定义网关）均无余额接口 → 显示「该协议不提供」，**未发起无谓请求** |

DeepSeek `GET /user/balance` 通路由 2 例单元测试覆盖（多候选命中、非 DeepSeek 不请求）；**本机无 DeepSeek 形态密钥，未做真机联网实测**。

## 遗留项

- **旧实例仍在运行**：一个 v1.6.0 实例（`dist/Key注入器.app`，目录已删但进程存活）窗口与新版本重叠，建议手动退出以免误看旧界面。
- **Git 未提交**：本轮约 20 个文件改动；仓库目录名仍为 `注入器以及key管理工具`。
- **台账截图待补**：现有 9 张为 v1.6.0 旧界面；新版默认态已人工确认，**展开态未出图**（本机未开「辅助访问」，无法脚本点击「识别模型」）。
- **Gemini 401**：本机凭据（`AQ.` 前缀）对两个端点均返回 401「需要 OAuth2 主体」，属凭据形态问题；改用 AI Studio 的 `AIza…` Key 即可。

## 复现命令

```bash
cd "/Users/linqiyu/Documents/DSH/注入器以及key管理工具"
swift test                      # 99 项测试
./scripts/check_version_sync.sh # 版本一致性门禁
keyinject models probe --all    # 真实识别（含三维度）
keyinject key show --id <keyID> --json   # publishedAt / versionTag / balance
```

---

## 当前结论（v1.6.0 归档）

- 项目可继续迭代。本轮之前 `v1.3.0` 已提交（HEAD `90ae7b0`），本轮改动（`v1.4.0`）尚未提交。
- 核心质量门禁通过：`92 tests / 20 suites` 全绿，`scripts/run_tests.sh` 退出码为 `0`。
- 版本与分发产物同步：`VERSION`、`Version.swift`、`README`、技能包、需求台账、架构说明、变更日志、`.app` Info.plist 均为 `1.4.0`；
  `codesign --verify --deep --strict` 通过；`dist/KeyInjector-1.6.0.dmg` 的 `hdiutil verify` 返回 `checksum ... is VALID`。
- 四条真实缺陷已修复：**DSH 落点键名错配**（静默失效）、**YAML 定点改写制造假差异**（v1.4.0），
  以及 v1.6.0 开发期新发现的两条 **前端整页白屏缺陷**（详情弹窗 DOM 晚于脚本、顶层 `try` 包裹吞掉全局变量）。
  前者用 dry-run 实测复现，后者用「快照脚本逐步记录 `STEP_ERR`」定位——`jsc` 语法检查对这两条完全不报错。
- v1.6.0 用户新增诉求（密钥库名字分区 / 模型识别 / key 详情）已全部实施：实机 2 把 key 渲染为 2 个分区，
  公司AI综合 key 实测从 `http://192.168.1.200:8080/v1/models` 读回 20 条原始条目、去重 19 个模型身份。

## 本轮（v1.4.0）解决的两个用户问题

### 问题 1：「注入器没有显示是 gemini3.8 以及 ds 4.1，为什么这边模型获取显示的是这两个模型」

归因（已用代码与磁盘实测确认，非推断）：

| 位置 | 真实数据源 | 实测内容 |
| :--- | :--- | :--- |
| DSH 桌面端模型菜单 | `harness/settings.yaml` 的 `llm-pi-ai.providers.midpro.models`（人工手写） | 5 条：`DS/DeepSeek V4.1 Flash`、`gpt-6-astra`、`gemini-3.8-flash-high`、`gpt-image-2.5`、`gpt-image-2.5-flare` |
| 「模型清单」页（v1.3.0） | `~/.codex/codex-gateway-models.json`，且只保留 `isGateway` 条目 | 11 条中网关子集 2 条：`gemini-3.8-flash-high`、`ark/DeepSeek-V4.1-Flash` |

两条独立缺口：① 注入器源码对 `settings.yaml` **零引用**，DSH 侧模型从未进入视野；
② 侧边栏 `#count-models` 徽标在 `renderNavCounts()` 中从未赋值，恒为空，视觉上像「没有内容」。

### 问题 2：「应该从注入器的密钥库中就能获取模型清单，把当前的模型清单和密钥库整合」

已按用户确认的方案实施：**并入密钥卡 + 保留总览页**；键名错配本轮一并修复；交付到「改代码 + 测试 + 重建产物」。
交互遵循格式塔原理：共同区域（模型区块用左侧强调线围入密钥卡）、接近性（列内 gap 6px < 卡片间距 12px）、
相似性（复用既有 chip/状态点）、闭合性（默认折叠，写操作收敛到底部虚线管理区）、图形—背景（模型为次级字号）。

## 已知风险与待办

1. **DSH 侧模型仍需人工维护**：本工具只读 `settings.yaml`，新增 DSH 模型要用户自己改该文件。这是刻意的反例边界（见 `docs/requirements.md` NOT-006），不是缺陷。
2. **Codex 侧路由仍会被桌面端改回**：用户每次在 Codex 顶部菜单换模型都可能丢失 `model_provider = codex_gateway`。目前靠 launchd 常驻守护（每 10 秒）与 `keyinject gateway repair --yes` 兜底。根因在 Codex 桌面端，本地无解。
3. **Gemini 上游额度不稳定**：`gemini-3.8-flash-high` 走 Antigravity 线路，同一 payload 连测会出现 200/429/503 交替。属网关运维项。
4. **测试编译仍有非阻塞警告**：`SecAccessCreate` 已弃用、`AppDelegate.swift` 隐式强引用捕获、本机 CLT 链接搜索路径提示。未导致失败，建议单独开修复任务。
5. **项目治理入口仍缺失**：`reconcile-project-standards` 报告项目级 `AGENTS.md`、标准化 requirements/problem-log/operations/CLI 索引与受管策略指纹均未建立。

## 建议的下一轮顺序

1. 提交本轮改动并推送；再补齐项目治理入口与唯一索引。
2. 每次改动后先跑 `bash scripts/check_version_sync.sh` 与 `bash scripts/run_tests.sh`，再做 `.app`/DMG 产物校验。
3. 网关模型切换后先 `keyinject gateway check`；异常时先 dry-run `keyinject gateway repair`，确认后才 `--yes`。
4. 不确定「某个模型由哪把 Key 供给」时用 `keyinject hosts keys`，不要凭 Key 别名猜。

## 本次验证入口

- `bash scripts/run_tests.sh`：通过，92 项测试、20 个套件（新增「模型发现」9 例与「密钥库分区与详情」2 例）。
- 单一事实源已落地（v1.6.0）：`keyinject sync` dry-run 实测「DSH 供应商 midpro：5 → 6 个模型」，
  落盘 diff 只有新增的 1 行；复跑报告「已一致」。
- `bash scripts/check_version_sync.sh`：通过，版本 `1.6.0`。
- `bash scripts/build_app.sh`：`.app` 组装与 ad-hoc 签名校验通过。
- `bash scripts/build_dmg.sh`：DMG 生成并通过 `hdiutil verify`。
- `codesign --verify --deep --strict dist/Key注入器.app`：通过。
- `keyinject hosts list` / `hosts keys` / `keys`：实测输出正确，跨宿主别名合并为 5 个模型 / 7 条记录。
- `keyinject inject --target dsh-desktop --key <id>`：dry-run 显示「注入键名: MIDPRO_API_KEY」且判定为空操作。
- 页面截图台账已刷新到 `docs/screenshots/`，共 9 张（新增 `Page_KeyInjector_Keys_Detail.png`）。
- 模型识别 CLI 实测（沙箱 `KEYINJECTOR_HOME` 指向临时目录，未触碰真实保险库）：
  `keyinject keys --grouped` 按别名分区输出；`models probe --id <公司AI综合>` 端点探测成功 20 条/去重 19 个；
  `models probe --id <Gemini>` 返回 HTTP 401 并如实降级为「未知」；`model-cache.json` 中 grep 明文为空。
