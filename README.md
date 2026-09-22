# Key 注入器 (KeyInjector)

macOS 原生架构的 AI API Key 安全管理与配置注入工具。

## 最新版本：v1.3.0

- **Codex 桌面端模型菜单无缝打通**：自动生成 `model_catalog_json`，将中间商网关的 DeepSeek V4.1、Gemini 3.8 Flash 模型直接注册到 Codex 顶部下拉菜单中，支持即选即用。
- **本地高强度加密引擎 (AES-GCM)**：全面取代系统钥匙串，彻底杜绝 macOS 登录密码弹窗骚扰，实现 100% 零阻断一键注入。
- **DSH 与 Codex 极简双宿主矩阵**：清洗 8 个冗余干扰落点，专注桌面端核心注入场景。
- **极简「⚡ 一键注入生效」**：毫秒级完成 Key 智能匹配、Dry-run 校验、自动时间戳备份与原子写入。
- **密钥可视化管理**：支持 Key 别名、Secret 明文与中转 Base URL 自定义修改。
