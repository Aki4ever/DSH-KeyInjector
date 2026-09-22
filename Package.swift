// swift-tools-version:5.9
// ==============================================================================
// KeyInjector — AI API Key 管理与配置注入器
//
// 工程约束与踩坑记录（本机实测）：
//   1. 刻意保持「零外部依赖」，全部基于系统自带 SDK，确保在仅安装
//      Command Line Tools（无完整 Xcode）的机器上也能直接构建；
//   2. **不可使用 SwiftUI**：本机 CLT 工具链未随附 SwiftUIMacros 插件，
//      而该 SDK 中 @State / @Binding 等为宏实现，编译必然失败
//      （报错：plugin for module 'SwiftUIMacros' not found）。
//      因此桌面界面采用 AppKit + WKWebView + 内置 HTML/CSS/JS 前端实现。
//   3. 测试层使用 swift-testing；本机 CLT 不含 XCTest。
// ==============================================================================
import PackageDescription

let package = Package(
    name: "KeyInjector",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "KeyInjectorCore", targets: ["KeyInjectorCore"]),
        .executable(name: "keyinject", targets: ["keyinject"]),
        .executable(name: "KeyInjectorApp", targets: ["KeyInjectorApp"])
    ],
    targets: [
        // 核心业务库：密钥仓库、注入引擎、健康探测、审计日志
        .target(
            name: "KeyInjectorCore",
            path: "Sources/KeyInjectorCore"
        ),
        // 命令行基座：供 DSH 会话经 bash 直接调用，全部子命令支持 --json
        .executableTarget(
            name: "keyinject",
            dependencies: ["KeyInjectorCore"],
            path: "Sources/keyinject"
        ),
        // 桌面应用：AppKit 外壳 + WKWebView 前端
        .executableTarget(
            name: "KeyInjectorApp",
            dependencies: ["KeyInjectorCore"],
            path: "Sources/KeyInjectorApp"
        ),
        .testTarget(
            name: "KeyInjectorCoreTests",
            dependencies: ["KeyInjectorCore"],
            path: "Tests/KeyInjectorCoreTests"
        )
    ]
)
