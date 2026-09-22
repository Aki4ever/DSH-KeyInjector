# KeyInjector · Key 注入器

> ### 🏷️ 版本信息
> - **当前实施版本**：`v1.0.0`
> - **交付形态**：macOS 原生应用（`.app` / `.dmg`）+ 命令行工具 `keyinject`
> - **最后更新**：2026-09-22
> - **状态**：`[Release 可用]`

一款面向 macOS 的 **AI API Key 统一管理与配置注入器**：把多家大模型厂商的密钥集中保管在本机，并**安全地注入**到各类 AI 工具（Claude Code、Codex CLI、Shell 启动脚本、项目 `.env` 等）的配置文件中，支持多 Key 轮换、有效性探测与一键回滚。

---

## 📌 解决什么问题

同时使用 DSH、Claude Code、Codex、Aider、各类兼容网关时，密钥散落在多个配置文件与环境变量里，切换模型要手工改多处，改错还容易把工具搞坏。本工具把这件事收敛为两步：**选中落点 → 核对差异 → 写入**，且每一步都可追溯、可回滚。

---

## 🚀 快速开始

### 方式一：直接安装 DMG

```bash
open dist/KeyInjector-1.0.0.dmg      # 挂载后把「Key注入器」拖入 Applications
```

> ⚠️ 本应用为 **ad-hoc 签名**（无 Apple 开发者证书）。首次打开若提示「无法验证开发者」，
> 请到「系统设置 → 隐私与安全性」点击「仍要打开」放行一次。

### 方式二：从源码构建

```bash
# 依赖：macOS 13+，Swift 6.x 工具链（本机为 Command Line Tools，无需完整 Xcode）
swift build                 # 编译核心库 + CLI + 桌面应用
./scripts/run_tests.sh      # 质量门禁：38 项自动化测试必须全绿
./scripts/build_app.sh      # 产出 dist/Key注入器.app
./scripts/build_dmg.sh      # 产出 dist/KeyInjector-1.0.0.dmg
```

### 方式三：仅用命令行

```bash
swift run keyinject --help
```

---

## 🖥️ 界面总览

应用由五个功能区组成，页面截图见 [`docs/page_ledger.md`](docs/page_ledger.md) 与 `docs/screenshots/`：

| 功能区 | 作用 |
| :--- | :--- |
| **密钥库** | 新增 / 启停 / 删除密钥，展示掩码、SHA-256 短指纹、优先级与探测状态 |
| **注入中心** | 选择落点与密钥 → 生成 dry-run 计划 → 核对差异 → 确认写入（自动备份）→ 一键回滚 |
| **健康探测** | 向厂商官方端点发起一次极小鉴权请求，判定「有效 / 无效 / 额度限流 / 网络不通」 |
| **审计日志** | 追加写入的完整操作史，可从中精确回滚任意一次注入 |
| **设置与说明** | 数据位置、密钥后端安全等级、可覆盖的配置模板与能力边界 |

---

## 🧱 架构

```text
┌──────────────────────────────┐   ┌──────────────────────────────┐
│  Key注入器.app               │   │  keyinject (CLI)             │
│  AppKit 外壳 + WKWebView     │   │  供 DSH 会话经 bash 调用      │
│  └─ web/ (HTML/CSS/JS)       │   │  └─ 全部子命令支持 --json     │
└───────────┬──────────────────┘   └───────────┬──────────────────┘
            │  JS ↔ Swift 桥接 (WKScriptMessageHandler)
            ▼                                  ▼
        ┌───────────────────────────────────────────────┐
        │           KeyInjectorCore (Swift 库)          │
        │  KeyVault · InjectionEngine · HealthChecker   │
        │  ContentPatcher · AtomicWriter · BackupStore  │
        │  AuditLog · ProviderCatalog · TargetCatalog   │
        └───────────────────────────────────────────────┘
```

* **界面与 CLI 共用同一套核心逻辑**，不存在「界面能做的事命令行做不了」的差异。
* **零外部依赖**：不引入任何第三方 Swift 包，仅使用系统 SDK（Foundation / AppKit / WebKit / CryptoKit / Security）。

### 目录结构

```text
.
├── Package.swift                 # SPM 工程定义（3 个 target + 1 个测试 target）
├── Sources/
│   ├── KeyInjectorCore/          # 核心库
│   │   ├── Models/               # 数据模型与厂商/落点预设目录
│   │   ├── Storage/              # 密钥后端（钥匙串/加密文件/内存）、仓库、审计日志
│   │   ├── Injector/             # 多格式定点补丁、原子写、备份、注入引擎
│   │   ├── Health/               # 健康探测与状态分类
│   │   └── Support/              # 指纹、掩码、路径、行差异、JSON 定点扫描器
│   ├── keyinject/                # 命令行工具
│   └── KeyInjectorApp/           # AppKit 外壳与 JS 桥接
├── Tests/KeyInjectorCoreTests/   # 38 项自动化测试（swift-testing）
├── web/                          # 界面（原生 HTML/CSS/JS，无构建链）
├── config/                       # 可覆盖的厂商与落点配置模板
├── scripts/                      # 测试、打包、图标生成脚本
├── assets/                       # 应用图标（PNG / icns）与生成脚本
├── docs/                         # 需求台账、架构、页面台账、截图
└── skills/keyinject/SKILL.md     # DSH Agent Skill 技能包
```

---

## 🔐 安全模型

| 措施 | 说明 |
| :--- | :--- |
| **明文不落盘** | 密钥明文存于 macOS 钥匙串；`vault.json` 只保存掩码与 SHA-256 短指纹 |
| **审计不含明文** | 审计日志只记录掩码与指纹，专项测试断言日志中绝不出现明文 |
| **默认只预览** | 界面与 CLI 的注入动作一律先生成 dry-run 计划，需显式确认才写入 |
| **写前必备份** | 每次写入前备份原文件（毫秒级时间戳 + 唯一后缀，不会互相覆盖） |
| **原子替换** | 同目录临时文件 → 落盘同步 → `replaceItemAt` 原子替换，绝不留半截文件 |
| **写后读回** | 写入后立即读回比对内容并计算指纹，不一致即判失败并保留备份 |
| **精确回滚** | 已有文件回滚即还原备份；当初新建的文件回滚即删除该文件 |
| **拒绝猜测** | 键路径缺失、格式不符、文件不可写、受管区块标记不成对 → 一律阻断报错 |
| **不自动联网** | 仅在显式点击「探测」时访问厂商官方域名，不向任何第三方上报 |

### 密钥后端三档（界面会如实显示当前档位）

| 后端 | 安全等级 | 适用场景 |
| :--- | :--- | :--- |
| **macOS 钥匙串**（默认） | 高，受系统加密与访问控制保护 | 日常使用 |
| **本地加密文件** | 中，主密钥与密文同机存放，仅防「误同步 / 被随手看到」 | 无头环境、自动化验证 |
| **内存** | 无持久化，进程退出即丢失 | 单元测试与演示 |

> 可用环境变量 `KEYINJECTOR_STORE=keychain|file|memory` 切换，数据目录由 `KEYINJECTOR_HOME` 指定。

---

## ⚠️ 能力边界与反例（务必知悉）

1. **YAML / TOML 采用定点行替换而非全量解析**：支持顶层或单个 `[section]` / `section:` 下的键值改写，
   **不支持**多层嵌套、流式写法（`{a: b}`）、内联表与数组表（`[[x]]`）。遇到这些结构请改用 JSON 落点或手工维护。
2. **JSON 只做定点替换，不新建键路径**：若目标键路径不存在，直接阻断并报错，避免破坏第三方配置文件结构。
3. **`plist` 只支持扁平键名**，不支持多级嵌套路径。
4. **Shell 落点仅适用于 sh / bash / zsh**：fish、csh 用户请改用自定义落点。
5. **第三方工具路径可能随版本变化**：内置预设保持保守，全部落点都带有反例说明；
   请始终先看 dry-run 差异。可用 `config/providers.json` 与 `config/targets.json` 覆盖预设，**无需重新编译**。
6. **健康探测结果只代表「此刻鉴权是否通过」**，不代表模型可用性或账户余额充足。

---

## 💻 命令行用法（DSH 会话联动）

```bash
keyinject info                          # 数据目录、密钥后端、审计文件位置
keyinject providers --json              # 厂商目录
keyinject targets --json                # 注入落点目录
keyinject keys --json                   # 密钥清单（仅掩码与指纹）

# 新增密钥：避免明文进入 shell 历史，推荐从标准输入读取
printf '%s' 'sk-xxxx' | keyinject keys add --provider deepseek --label 主力 --secret-stdin

# 注入：默认 dry-run，必须显式 --yes 才写入
keyinject inject --target shell-profile --key <id> --json
keyinject inject --target shell-profile --key <id> --yes

# 回滚
keyinject rollback --target shell-profile --file ~/.zshrc
keyinject audit --limit 20 --json
keyinject check --all --json
```

**约定**：`inject` 默认 dry-run；输出中的密钥一律掩码（`--show-secret` 才显示明文）；
退出码 `0` 成功 / `1` 失败 / `2` 被安全策略阻断。密钥明文永不进入会话上下文。

---

## 🧪 质量门禁

```bash
./scripts/run_tests.sh
```

38 项自动化测试覆盖：JSON 定点补丁（缩进与键序保持、缺失路径拒绝）、dotenv/shell 补丁（幂等、受管区块）、
YAML/TOML 区块替换与插入、行差异与脱敏、原子写入（权限保持、不留临时文件）、仓库事务（索引无明文、
更新一致性、优选策略）、注入端到端（真实文件 + 备份 + 回滚 + 新建文件回滚删除 + 脏数据阻断）、
备份重名回归、健康探测分类与鉴权头风格、预设目录完整性。

---

## 🧭 环境约束与踩坑记录（重要）

本机为 macOS 26.6.2 / arm64，**仅安装 Command Line Tools，无完整 Xcode**。实测结论：

1. **SwiftUI 不可用**：该工具链未随附 `SwiftUIMacros` 插件，而此 SDK 中 `@State`、`@Binding` 等均为宏实现，
   编译必然失败（`plugin for module 'SwiftUIMacros' not found`）。因此桌面界面改用
   **AppKit + WKWebView + 内置 HTML/CSS/JS 前端**，视觉效果与可维护性反而更好。
2. **XCTest 不可用**：工具链不含 `XCTest`，测试统一改用 **swift-testing**（`import Testing`）。
3. **SPM 增量编译会漏传测试宏插件路径**：第二次起报 `TestingMacros not found`。
   `scripts/run_tests.sh` 会动态探测插件目录并显式传入，保证重复运行稳定。
4. **`screencapture` 被系统隐私权限拒绝**（未授予屏幕录制），因此页面台账截图改用
   **应用内 `WKWebView.takeSnapshot`**，只捕获页面内容，无需系统权限，更适合作为交付基准图。

---

## 🤖 DSH 能力集成

按元规则第十八条「项目立项 DSH 优先与保底集成律」，本项目集成三项 DSH 宿主能力：

| 维度 | 落地方式 |
| :--- | :--- |
| **CLI 命令行基座** | 真实可执行的 `keyinject` 二进制，全部子命令支持 `--json`，可被 DSH `bash` 工具直接调用 |
| **Agent Skill 技能包** | 随仓库交付 [`skills/keyinject/SKILL.md`](skills/keyinject/SKILL.md)，DSH 可按需动态加载 |
| **多智能体协同** | 图标资产生成、文档编撰等独立子任务走 subagent 独立沙箱并行执行 |

---

## 📄 许可与声明

本工具仅在本机读写配置，不上传任何数据。请在遵守各模型服务商服务条款的前提下使用你的 API Key。
