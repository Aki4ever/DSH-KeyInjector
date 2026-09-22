# 变更日志 — KeyInjector · Key 注入器

本文件遵循 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/) 结构，版本号语义遵循 [语义化版本](https://semver.org/lang/zh-CN/)。

> 版本号单一来源为仓库根目录 `VERSION` 文件；全工程一致性由 `scripts/check_version_sync.sh` 自动校验。

---

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
