// ==============================================================================
// Codex 网关路由常驻守护（launchd）
//
// 背景：Codex 桌面端顶部菜单切换模型时只写 `model`、不写 `model_provider`，
// 请求会退回官方 openai provider 并被 ChatGPT 后端拒绝为
// "The '<model>' model is not supported when using Codex with a ChatGPT account."
// 一次修复会被下一次换模型覆盖，因此需要一个常驻守护持续体检并自动收敛。
//
// 设计：
//   · 只有一个常驻进程：`keyinject gateway watch --interval N`（自身循环，不通轮询无意义）
//   · CLI 复制到稳定路径 `~/.local/bin/keyinject`，避免仓库被移动/删除后守护失效
//   · NoneOfTheAbove：不读写任何密钥；日志只记录路由状态与修复动作
// ==============================================================================
import Foundation

public enum GatewayGuardAgent {
    public static let label = "com.aki4ever.keyinjector.gateway-guard"
    public static var plistPath: String {
        PathKit.expand("~/Library/LaunchAgents/\(label).plist")
    }
    public static var logPath: String {
        PathKit.expand("~/Library/Logs/keyinjector-gateway-guard.log")
    }
    public static var stableBinaryPath: String {
        PathKit.expand("~/.local/bin/keyinject")
    }

    /// 安装/覆盖 launchd 常驻守护
    /// - Parameter intervalSeconds: 体检间隔秒数（最小 5）
    /// - Returns: 便于 CLI 直接打印的键值摘要
    @discardableResult
    public static func install(intervalSeconds: Int = 15, binarySource: String? = nil, codexHome: String? = nil) throws -> [String: String] {
        let interval = max(5, intervalSeconds)
        let source = binarySource ?? CommandLine.arguments.first ?? ""
        let stable = stableBinaryPath
        let fm = FileManager.default
        try fm.createDirectory(atPath: (stable as NSString).deletingLastPathComponent,
                               withIntermediateDirectories: true)
        if !source.isEmpty, PathKit.expand(source) != stable, fm.isExecutableFile(atPath: PathKit.expand(source)) {
            if fm.fileExists(atPath: stable) { try? fm.removeItem(atPath: stable) }
            try fm.copyItem(atPath: PathKit.expand(source), toPath: stable)
        }
        guard fm.isExecutableFile(atPath: stable) else {
            throw AgentError.binaryUnavailable("找不到可用的 keyinject 可执行文件：\(stable)")
        }
        try fm.createDirectory(atPath: (logPath as NSString).deletingLastPathComponent,
                               withIntermediateDirectories: true)

        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key><string>\(label)</string>
            <key>ProgramArguments</key>
            <array>
                <string>\(stable)</string>
                <string>gateway</string>
                <string>repair</string>
                <string>--yes</string>
                <string>--quiet</string>
                <string>--log</string>
                <string>\(logPath)</string>
            </array>
            <key>RunAtLoad</key><true/>
            <key>StartInterval</key><integer>\(interval)</integer>
            <key>StandardOutPath</key><string>\(logPath)</string>
            <key>StandardErrorPath</key><string>\(logPath)</string>
            <key>ProcessType</key><string>Background</string>
            \(codexHome.map { "<key>EnvironmentVariables</key><dict><key>CODEX_HOME</key><string>\($0)</string></dict>" } ?? "")
        </dict>
        </plist>
        """
        try plist.write(toFile: plistPath, atomically: true, encoding: .utf8)

        // 先卸载旧实例再加载，保证 interval 等参数更新后立即生效
        _ = runLaunchctl(["bootout", "gui/\(getuid())/\(label)"])
        let load = runLaunchctl(["bootstrap", "gui/\(getuid())", plistPath])
        if load.status != 0 {
            // 兜底：老系统用 load -w
            let fallback = runLaunchctl(["load", "-w", plistPath])
            if fallback.status != 0 {
                throw AgentError.launchctlFailed(load.message.isEmpty ? fallback.message : load.message)
            }
        }
        return [
            "label": label,
            "intervalSeconds": "\(interval)",
            "plist": plistPath,
            "binary": stable,
            "log": logPath,
            "codexHome": codexHome ?? "(默认 ~/.codex)",
            "mode": "launchd 心跳（StartInterval=\(interval) 秒，每次执行一次修复；未改动时不写日志）",
            "status": "已加载（launchctl bootstrap gui/\(getuid())）"
        ]
    }

    /// 卸载常驻守护
    public static func uninstall() throws -> [String: String] {
        let fm = FileManager.default
        let bootout = runLaunchctl(["bootout", "gui/\(getuid())/\(label)"])
        var removed = false
        if fm.fileExists(atPath: plistPath) {
            try fm.removeItem(atPath: plistPath)
            removed = true
        }
        return [
            "label": label,
            "plist": plistPath,
            "plistRemoved": removed ? "是" : "否（本来就不存在）",
            "launchctl": bootout.status == 0 ? "已停止" : "未运行或已停止",
            "log": logPath,
            "note": "日志文件保留，可自行删除"
        ]
    }

    /// 守护是否正在运行（按 label 查询 launchctl）
    public static func isRunning() -> Bool {
        let result = runLaunchctl(["print", "gui/\(getuid())/\(label)"])
        return result.status == 0
    }

    @discardableResult
    static func runLaunchctl(_ arguments: [String]) -> (status: Int32, message: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do { try process.run() } catch { return (-1, "\(error)") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
    }

    public enum AgentError: Error, CustomStringConvertible {
        case binaryUnavailable(String)
        case launchctlFailed(String)

        public var description: String {
            switch self {
            case .binaryUnavailable(let message): return message
            case .launchctlFailed(let message): return "launchctl 加载失败：\(message)"
            }
        }
    }
}
