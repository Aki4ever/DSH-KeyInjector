// ==============================================================================
// keyinject 命令行工具
//
// 设计原则：
//   1. **默认只预览不写入**：`inject` 默认走 dry-run，必须显式加 `--yes` 才落盘；
//   2. **默认不打印明文**：差异与片段中的密钥一律掩码，需 `--show-secret` 才显示；
//   3. **全部子命令支持 --json**：便于 DSH 会话经 bash 调用后解析结构化结果；
//   4. 退出码语义：0 成功 / 1 业务失败 / 2 被安全策略阻断。
// ==============================================================================
import Foundation
import KeyInjectorCore

// MARK: - 输出工具

enum Out {
    static var jsonMode = false

    static func info(_ s: String) { if !jsonMode { print(s) } }
    static func warn(_ s: String) { if !jsonMode { FileHandle.standardError.write(Data(("⚠️  " + s + "\n").utf8)) } }
    static func error(_ s: String) { if !jsonMode { FileHandle.standardError.write(Data(("❌ " + s + "\n").utf8)) } }

    static func json(_ object: [String: Any]) {
        if let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) {
            print(String(decoding: data, as: UTF8.self))
        }
    }

    static func box(_ title: String) {
        guard !jsonMode else { return }
        print("")
        print("─ \(title) " + String(repeating: "─", count: max(0, 46 - title.count)))
    }
}

func iso(_ date: Date) -> String { ISO8601DateFormatter().string(from: date) }

func fail(_ message: String, code: Int32 = 1) -> Never {
    Out.error(message)
    if Out.jsonMode { Out.json(["ok": false, "error": message]) }
    exit(code)
}

// MARK: - 参数解析

struct Args {
    private var flags: Set<String> = []
    private var values: [String: String] = [:]
    private var positionals: [String] = []

    init(_ raw: [String]) {
        var i = 0
        while i < raw.count {
            let token = raw[i]
            if token.hasPrefix("--") {
                let name = String(token.dropFirst(2))
                if let eq = name.firstIndex(of: "=") {
                    let key = String(name[name.startIndex..<eq])
                    let value = String(name[name.index(after: eq)...])
                    values[key] = value
                } else if i + 1 < raw.count && !raw[i + 1].hasPrefix("--") {
                    values[name] = raw[i + 1]
                    i += 1
                } else {
                    flags.insert(name)
                }
            } else {
                positionals.append(token)
            }
            i += 1
        }
    }

    func flag(_ name: String) -> Bool { flags.contains(name) }
    func value(_ name: String) -> String? { values[name] }
    var rest: [String] { positionals }

    func intValue(_ name: String, default def: Int) -> Int {
        if let s = values[name], let v = Int(s) { return v }
        return def
    }
}

// MARK: - 主程序

@main
struct KeyInjectCLI {

    static let helpText = """
    keyinject — AI API Key 管理与配置注入器（KeyInjector CLI）

    用法：
      keyinject <子命令> [参数...]

    子命令：
      info                              显示数据目录、密钥后端与审计文件位置
      providers                         列出内置厂商目录
      targets                           列出可注入落点
      keys                              列出已保存的密钥（仅掩码与指纹）
      keys add                          新增密钥
          --provider <厂商id> --label <别名> (--secret <明文> | --secret-stdin | --secret-env <变量名>)
          [--priority <数值>] [--tags a,b] [--note <备注>]
      keys rm --id <密钥id>             删除密钥（同时清除钥匙串明文）
      keys enable|disable --id <密钥id> 启用 / 禁用密钥
      inject                            生成注入计划（**默认只预览**）
          --target <落点id> --key <密钥id> [--file <路径>] [--json-path a.b.c]
          [--section <区块>] [--item-key <键名>] [--yes] [--show-secret]
      rollback                          回滚一次注入
          (--audit-id <审计id> | --target <落点id> --file <路径>)
      check                             健康探测（--id <密钥id> 单个 / --all 全部）
      audit [--limit N]                 查看审计日志
      config dump                       导出可编辑的厂商与落点配置模板
      gateway check                     体检 Codex 网关模型是否被正确路由到 codex_gateway
      gateway repair [--yes]            修复路由（默认 dry-run，--yes 才落盘，写入前自动备份）
      gateway watch [--interval 10]     常驻守护：定期体检并自动修复路由（Ctrl-C 退出）
      gateway install-agent [--interval 10]   安装 launchd 常驻守护（开机自启，可 uninstall-agent 卸载）
      gateway uninstall-agent           卸载 launchd 常驻守护
      models list [--all]               列出模型目录条目（默认只看公司网关模型，含来源与菜单可见性）
      models add --slug <模型名> --name <菜单显示名> [--desc <说明>] [--hidden] [--yes]
      models show|hide --slug <模型名>   在 Codex 顶部菜单中显示 / 隐藏该模型
      models rm --slug <模型名>          从目录删除公司网关模型（官方条目不可删）

    通用参数：
      --json                            以 JSON 输出（便于 DSH 会话解析）
      --help                            显示本帮助

    安全约定：
      · inject 默认 dry-run，必须显式 --yes 才会真正写入文件；
      · 输出中的密钥一律掩码，除非显式 --show-secret；
      · 写入前自动备份原文件，可用 rollback 一键还原。
    """

    static func main() async {
        var rawArgs = Array(CommandLine.arguments.dropFirst())
        if rawArgs.contains("--json") { Out.jsonMode = true }
        rawArgs.removeAll { $0 == "--json" }

        guard let command = rawArgs.first else {
            print(helpText)
            exit(0)
        }
        let args = Args(Array(rawArgs.dropFirst()))

        if command == "--help" || command == "-h" || command == "help" {
            print(helpText)
            exit(0)
        }
        if command == "version" || command == "--version" {
            if Out.jsonMode { Out.json(["ok": true, "name": AppVersion.productName, "version": AppVersion.current]) }
            else { print("KeyInjector CLI v\(AppVersion.current)") }
            exit(0)
        }

        let service: KeyInjectorService
        do {
            service = try KeyInjectorService()
        } catch {
            fail("初始化失败：\(error)")
        }

        switch command {
        case "info":                runInfo(service)
        case "providers":           runProviders(service)
        case "targets":             runTargets(service)
        case "keys":                runKeys(service, args)
        case "inject":              runInject(service, args)
        case "rollback":            runRollback(service, args)
        case "check":               await runCheck(service, args)
        case "audit":               runAudit(service, args)
        case "config":              runConfig(service, args)
        case "gateway":             runGateway(service, args)
        case "models":              runModels(service, args)
        default:
            fail("未知子命令：\(command)（运行 keyinject --help 查看用法）")
        }
    }

    // MARK: info

    static func runInfo(_ service: KeyInjectorService) {
        let info = service.runtimeInfo()
        if Out.jsonMode {
            var out: [String: Any] = ["ok": true]
            for (k, v) in info { out[k] = v }
            out["bootWarnings"] = service.bootWarnings
            Out.json(out)
            return
        }
        Out.box("运行时信息")
        print("数据目录    : \(info["root"] ?? "-")")
        print("密钥后端    : \(info["storeBackend"] ?? "-")")
        print("审计文件    : \(info["auditFile"] ?? "-")")
        print("厂商数量    : \(info["providerCount"] ?? "-")")
        print("落点数量    : \(info["targetCount"] ?? "-")")
        for w in service.bootWarnings { Out.warn(w) }
    }

    // MARK: providers / targets

    static func runProviders(_ service: KeyInjectorService) {
        if Out.jsonMode {
            let list = service.providers.providers.map { p -> [String: Any] in
                ["id": p.id, "name": p.name, "envKeys": p.envKeys, "baseURL": p.baseURL ?? "",
                 "healthPath": p.healthPath ?? "", "consoleURL": p.consoleURL ?? "", "note": p.note]
            }
            Out.json(["ok": true, "providers": list])
            return
        }
        Out.box("厂商目录（\(service.providers.providers.count) 项）")
        for p in service.providers.providers {
            print("• \(p.id.padding(toLength: 12, withPad: " ", startingAt: 0)) \(p.name)")
            print("    环境变量: \(p.envKeys.joined(separator: ", "))")
            if let b = p.baseURL { print("    API 基址: \(b)") }
            if !p.note.isEmpty { print("    说明    : \(p.note)") }
        }
    }

    static func runTargets(_ service: KeyInjectorService) {
        if Out.jsonMode {
            let list = service.targets.targets.map { t -> [String: Any] in
                ["id": t.id, "name": t.name, "format": t.format.rawValue, "filePath": t.filePath,
                 "jsonPath": t.jsonPath, "section": t.section ?? "", "itemKey": t.itemKey ?? "",
                 "providerID": t.providerID ?? "", "requiresPath": TargetCatalog.requiresPath(t), "note": t.note]
            }
            Out.json(["ok": true, "targets": list])
            return
        }
        Out.box("注入落点（\(service.targets.targets.count) 项）")
        for t in service.targets.targets {
            let needs = TargetCatalog.requiresPath(t) ? "（需指定路径）" : ""
            print("• \(t.id.padding(toLength: 16, withPad: " ", startingAt: 0)) \(t.name)\(needs)")
            print("    格式: \(t.format.label)    路径: \(t.filePath.isEmpty ? "—" : t.filePath)")
            if !t.jsonPath.isEmpty { print("    键路径: \(t.jsonPath.joined(separator: "."))") }
            if !t.note.isEmpty { print("    说明: \(t.note)") }
        }
    }

    // MARK: keys

    static func runKeys(_ service: KeyInjectorService, _ args: Args) {
        let sub = args.rest.first

        switch sub {
        case "add":
            guard let providerID = args.value("provider") else { fail("缺少 --provider 参数") }
            guard let label = args.value("label") else { fail("缺少 --label 参数") }

            var secret: String?
            if let s = args.value("secret") {
                secret = s
            } else if args.flag("secret-stdin") || args.value("secret") == "-" {
                let data = FileHandle.standardInput.readDataToEndOfFile()
                secret = String(decoding: data, as: UTF8.self)
            } else if let envName = args.value("secret-env") {
                secret = ProcessInfo.processInfo.environment[envName]
                if secret == nil { fail("环境变量 \(envName) 为空或不存在") }
            }
            guard let secretValue = secret, !secretValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                fail("缺少密钥明文：请用 --secret <值>、--secret-stdin 或 --secret-env <变量名>")
            }

            let tags = (args.value("tags") ?? "").split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            do {
                let record = try service.addKey(
                    providerID: providerID,
                    label: label,
                    secret: secretValue,
                    priority: args.intValue("priority", default: 100),
                    tags: tags,
                    note: args.value("note") ?? ""
                )
                let warnings = SecretValidator.warnings(secret: secretValue, provider: service.provider(id: providerID) ?? Provider(id: providerID, name: providerID, envKeys: []))
                if Out.jsonMode {
                    Out.json(["ok": true, "id": record.id, "providerID": record.providerID, "label": record.label,
                              "hint": record.hint, "fingerprint": record.fingerprint, "warnings": warnings])
                } else {
                    print("✅ 已保存密钥「\(record.label)」")
                    print("   记录 id : \(record.id)")
                    print("   掩码    : \(record.hint)")
                    print("   指纹    : \(record.fingerprint)")
                    print("   存储后端: \(service.vault.backendName)")
                    for w in warnings { Out.warn(w) }
                }
            } catch {
                fail("\(error)")
            }

        case "rm", "remove", "delete":
            guard let id = args.value("id") else { fail("缺少 --id 参数") }
            do {
                let record = try service.removeKey(id: id)
                if Out.jsonMode { Out.json(["ok": true, "removed": record.id]) }
                else { print("🗑️  已删除密钥「\(record.label)」（记录 id \(record.id)）") }
            } catch { fail("\(error)") }

        case "enable", "disable":
            guard let id = args.value("id") else { fail("缺少 --id 参数") }
            do {
                let record = try service.setEnabled(id: id, enabled: sub == "enable")
                if Out.jsonMode { Out.json(["ok": true, "id": record.id, "enabled": record.enabled]) }
                else { print("✅ 密钥「\(record.label)」已\(record.enabled ? "启用" : "禁用")") }
            } catch { fail("\(error)") }

        default:
            do {
                let keys = try service.listKeys()
                if Out.jsonMode {
                    let list = keys.map { k -> [String: Any] in
                        ["id": k.id, "providerID": k.providerID, "providerName": service.providers.name(of: k.providerID),
                         "label": k.label, "hint": k.hint, "fingerprint": k.fingerprint, "enabled": k.enabled,
                         "priority": k.priority, "tags": k.tags, "note": k.note,
                         "createdAt": iso(k.createdAt), "updatedAt": iso(k.updatedAt),
                         "lastCheck": k.lastCheck.map { ["status": $0.status.rawValue, "label": $0.status.label, "message": $0.message, "checkedAt": iso($0.checkedAt), "httpStatus": $0.httpStatus ?? 0, "latencyMS": $0.latencyMS ?? 0] } as Any]
                    }
                    Out.json(["ok": true, "count": keys.count, "storeBackend": service.vault.backendName, "keys": list])
                    return
                }
                Out.box("密钥库（\(keys.count) 条 · 后端：\(service.vault.backendName)）")
                if keys.isEmpty { print("（空。用 `keyinject keys add --provider deepseek --label 主力 --secret-stdin` 添加）") }
                for k in keys {
                    let status = k.lastCheck?.status.label ?? "未探测"
                    print("• [\(k.enabled ? "启用" : "禁用")] \(k.label)  ·  \(service.providers.name(of: k.providerID))")
                    print("    id: \(k.id)")
                    print("    掩码 \(k.hint)  指纹 \(k.fingerprint)  优先级 \(k.priority)  探测: \(status)")
                }
            } catch { fail("\(error)") }
        }
    }

    // MARK: inject

    static func runInject(_ service: KeyInjectorService, _ args: Args) {
        guard let targetID = args.value("target") else { fail("缺少 --target 参数") }
        guard let keyID = args.value("key") else { fail("缺少 --key 参数") }

        let jsonPath = args.value("json-path").map { $0.split(separator: ".").map(String.init) }
        let assumeYes = args.flag("yes")
        let showSecret = args.flag("show-secret")

        do {
            let plan = try service.planInjection(
                targetID: targetID,
                keyID: keyID,
                overridePath: args.value("file"),
                jsonPathOverride: jsonPath,
                sectionOverride: args.value("section"),
                itemKeyOverride: args.value("item-key")
            )

            var payload: [String: Any] = [
                "ok": !plan.blocked,
                "dryRun": !assumeYes,
                "target": plan.target.id,
                "targetName": plan.target.name,
                "provider": plan.provider.id,
                "keyLabel": plan.keyRecord.label,
                "keyFingerprint": plan.keyRecord.fingerprint,
                "itemKey": plan.itemKey,
                "filePath": plan.resolvedPath ?? "",
                "existedBefore": plan.existedBefore,
                "blocked": plan.blocked,
                "blockedReason": plan.blockedReason ?? "",
                "warnings": plan.warnings
            ]

            if plan.blocked {
                if Out.jsonMode {
                    payload["diff"] = []
                    Out.json(payload)
                } else {
                    Out.box("注入计划（已阻断）")
                    Out.error(plan.blockedReason ?? "未知原因")
                    for w in plan.warnings { Out.warn(w) }
                }
                exit(2)
            }

            let secret = try service.secret(for: keyID)
            let diffLines = showSecret ? plan.diff : plan.redactedDiff(secret: secret)

            if Out.jsonMode {
                payload["diff"] = diffLines.map { ["kind": $0.kind.rawValue, "text": $0.text] }
                payload["snippet"] = showSecret ? plan.snippet : plan.redactedSnippet(secret: secret)
            } else {
                Out.box("注入计划：\(plan.target.name)\(assumeYes ? "（将真实写入）" : "（dry-run 预览）")")
                print("目标文件  : \(plan.resolvedPath ?? "—")\(plan.existedBefore ? "" : "  ⚠️ 尚不存在，将新建")")
                print("注入键名  : \(plan.itemKey)")
                print("使用密钥  : \(plan.keyRecord.label)  掩码 \(plan.keyRecord.hint)  指纹 \(plan.keyRecord.fingerprint)")
                print("")
                for line in diffLines { print("  " + line.rendered) }
                if plan.target.format == .none {
                    print("")
                    print("导出片段（请自行粘贴到你的环境）：")
                    print("  " + (showSecret ? plan.snippet : plan.redactedSnippet(secret: secret)))
                }
                for w in plan.warnings { Out.warn(w) }
            }

            guard assumeYes else {
                if Out.jsonMode {
                    payload["applied"] = false
                    Out.json(payload)
                } else {
                    Out.info("")
                    Out.info("ℹ️  当前为 dry-run，未写入任何文件。确认无误后追加 --yes 执行真实注入。")
                }
                exit(0)
            }

            let outcome = try service.applyInjection(plan)
            if Out.jsonMode {
                payload["applied"] = outcome.success
                payload["message"] = outcome.message
                payload["backupPath"] = outcome.backupPath ?? ""
                payload["verifiedFingerprint"] = outcome.verifiedFingerprint ?? ""
                Out.json(payload)
                exit(outcome.success ? 0 : 1)
            }
            if outcome.success {
                print("")
                print("✅ \(outcome.message)")
                if let b = outcome.backupPath { print("   备份: \(b)") }
                if let fp = outcome.verifiedFingerprint { print("   写后读回指纹: \(fp)") }
                print("   如需撤销：keyinject rollback --target \(plan.target.id) --file \(plan.resolvedPath ?? "")")
            } else {
                Out.error(outcome.message)
                if let b = outcome.backupPath { Out.info("   备份仍在：\(b)") }
                exit(1)
            }
        } catch {
            fail("\(error)")
        }
    }

    // MARK: rollback

    static func runRollback(_ service: KeyInjectorService, _ args: Args) {
        var entry: AuditEntry?
        if let auditID = args.value("audit-id") {
            entry = service.audit.all().last { $0.id == auditID }
            if entry == nil { fail("未找到审计条目 \(auditID)") }
        } else if let targetID = args.value("target") {
            let path = args.value("file").map { PathKit.expand($0) }
            let candidates = service.audit.all().filter {
                $0.action == .inject && $0.targetID == targetID && (path == nil || $0.filePath == path)
            }
            entry = candidates.last
            if entry == nil { fail("未找到落点 \(targetID) 的注入记录，无可回滚内容") }
        } else {
            fail("请指定 --audit-id 或 --target（可配合 --file）")
        }

        do {
            let outcome = try service.rollback(entry: entry!)
            if Out.jsonMode {
                Out.json(["ok": outcome.success, "message": outcome.message, "filePath": outcome.filePath ?? ""])
                exit(outcome.success ? 0 : 1)
            }
            print(outcome.success ? "✅ \(outcome.message)" : "❌ \(outcome.message)")
            if let p = outcome.filePath { print("   文件: \(p)") }
            exit(outcome.success ? 0 : 1)
        } catch { fail("\(error)") }
    }

    // MARK: check

    static func runCheck(_ service: KeyInjectorService, _ args: Args) async {
        do {
            if let id = args.value("id") {
                let summary = try await service.checkKey(id: id)
                if Out.jsonMode {
                    Out.json(["ok": summary.status == .valid, "status": summary.status.rawValue, "label": summary.status.label,
                              "httpStatus": summary.httpStatus ?? 0, "latencyMS": summary.latencyMS ?? 0, "message": summary.message])
                    exit(summary.status == .valid ? 0 : 1)
                }
                Out.box("探测结果")
                print("状态: \(summary.status.label)")
                if let code = summary.httpStatus { print("HTTP: \(code)") }
                if let ms = summary.latencyMS { print("耗时: \(ms) ms") }
                print("说明: \(summary.message)")
                exit(summary.status == .valid ? 0 : 1)
            }

            if args.flag("all") {
                let results = try await service.checkAllKeys()
                if Out.jsonMode {
                    let list = results.map { ["id": $0.key, "status": $0.value.status.rawValue, "label": $0.value.status.label, "message": $0.value.message] }
                    Out.json(["ok": true, "results": list])
                    return
                }
                Out.box("批量探测结果（\(results.count) 个）")
                for (id, s) in results.sorted(by: { $0.key < $1.key }) {
                    print("• \(id.prefix(8))…  \(s.status.label)  \(s.message)")
                }
                return
            }

            let keys = try service.listKeys()
            print("请指定 --id <密钥id> 或 --all。当前密钥：")
            for k in keys { print("  \(k.id)  \(k.label)  (\(service.providers.name(of: k.providerID)))") }
        } catch { fail("\(error)") }
    }

    // MARK: audit

    static func runAudit(_ service: KeyInjectorService, _ args: Args) {
        let limit = args.intValue("limit", default: 30)
        let entries = service.recentAudit(limit)
        if Out.jsonMode {
            let list = entries.map { e -> [String: Any] in
                ["id": e.id, "timestamp": iso(e.timestamp), "action": e.action.rawValue, "actionLabel": e.action.label,
                 "result": e.result, "message": e.message, "targetID": e.targetID ?? "", "filePath": e.filePath ?? "",
                 "keyID": e.keyID ?? "", "providerID": e.providerID ?? "", "fingerprint": e.fingerprint ?? "",
                 "backupPath": e.backupPath ?? ""]
            }
            Out.json(["ok": true, "count": entries.count, "file": service.audit.path, "entries": list])
            return
        }
        Out.box("审计日志（最近 \(entries.count) 条）")
        print("文件: \(service.audit.path)")
        for e in entries {
            let mark = e.result == "success" ? "✅" : (e.result == "dryRun" ? "👁️" : "⚠️")
            print("\(mark) [\(iso(e.timestamp))] \(e.action.label) — \(e.message)")
            if let f = e.filePath { print("     文件: \(f)") }
            if let b = e.backupPath { print("     备份: \(b)") }
        }
    }

    // MARK: config

    static func runConfig(_ service: KeyInjectorService, _ args: Args) {
        guard args.rest.first == "dump" else {
            fail("用法：keyinject config dump（导出可编辑的厂商与落点配置模板）")
        }
        do {
            let written = try service.exportConfigTemplates()
            if Out.jsonMode { Out.json(["ok": true, "written": written, "root": service.root.path]); return }
            if written.isEmpty {
                print("ℹ️  配置模板已存在，未覆盖：\(service.root.appendingPathComponent("config").path)")
            } else {
                print("✅ 已导出配置模板：")
                for p in written { print("   \(p)") }
            }
            print("   编辑后重启本工具即可生效（同 id 覆盖内置项，新 id 追加）。")
        } catch { fail("\(error)") }
    }

    // MARK: gateway watch（常驻体检）

    /// 常驻守护：定期体检路由，发现被改回官方 provider 就自动修复。
    /// 刻意不打印密钥，只打印时间戳、模型、provider 与修复动作。
    static func runGatewayWatch(_ service: KeyInjectorService, configPath: String?, interval: Double, logPath: String?) {
        // 刻意不用 print：stdout 被 launchd 重定向时是全缓冲，进程被杀会丢日志
        emit("守护启动：每 \(Int(interval)) 秒体检一次 Codex 网关路由（Ctrl-C 退出）", to: logPath)
        var repairs = 0
        while true {
            let status = service.checkCodexGatewayRouting(configPath: configPath)
            if !status.exists {
                emit("未找到 Codex 配置（\(configPath ?? "~/.codex/config.toml")），跳过本轮", to: logPath)
            } else if status.healthy {
                emit("路由正常：model=\(status.model ?? "-") → provider=\(status.provider ?? "-")", to: logPath)
            }
            if status.exists, !status.healthy {
                do {
                    let result = try service.repairCodexGatewayRouting(configPath: configPath, dryRun: false)
                    repairs += 1
                    emit("已自动修复第 \(repairs) 次：model=\(result.status.model ?? "-") → provider=\(result.status.provider ?? "-") 备份=\(result.backupPath ?? "无")", to: logPath)
                } catch {
                    emit("修复失败：\(error)", to: logPath)
                }
            }
            Thread.sleep(forTimeInterval: interval)
        }
    }

    /// 输出一行日志：给了 --log 就追加到文件（守护模式），否则打到终端
    static func emit(_ message: String, to logPath: String?) {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let line = "[\(f.string(from: Date()))] \(message)\n"
        guard let logPath, !logPath.isEmpty else { print(line, terminator: ""); return }
        let url = URL(fileURLWithPath: PathKit.expand(logPath))
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(line.utf8))
        } else {
            try? line.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    // MARK: models（Codex 模型目录）

    static func runModels(_ service: KeyInjectorService, _ args: Args) {
        let action = args.rest.first ?? "list"
        do {
            switch action {
            case "list":
                let includeOfficial = args.flag("all")
                let entries = service.codexCatalogEntries(includeOfficial: includeOfficial)
                let overview = service.codexCatalogOverview()
                if Out.jsonMode {
                    Out.json([
                        "ok": true,
                        "overview": overview,
                        "models": entries.map { entry in
                            ["slug": entry.slug, "displayName": entry.displayName, "source": entry.sourceLabel,
                             "inPicker": entry.inPicker, "description": entry.description]
                        }
                    ])
                    return
                }
                Out.box("Codex 模型目录（\(includeOfficial ? "全部" : "公司网关") \(entries.count) 项）")
                print("目录文件: \(overview["catalogPath"] ?? "")")
                print("已注册到 config.toml: \((overview["registeredInConfig"] as? Bool ?? false) ? "是" : "否")")
                print("当前默认模型: \(overview["configModel"] ?? "(未设置)") → provider \(overview["configProvider"] ?? "(未设置)")")
                print("")
                for entry in entries {
                    let mark = entry.inPicker ? "菜单可见" : "已隐藏"
                    print("• [\(entry.sourceLabel)] \(entry.slug)  — \(entry.displayName)  （\(mark)）")
                }
                if !includeOfficial { print("\n提示：加 --all 可查看 Codex 官方条目。") }

            case "add":
                guard let slug = args.value("slug"), let name = args.value("name") else {
                    fail("用法：keyinject models add --slug <模型名> --name <菜单显示名> [--desc <说明>] [--hidden] [--yes]")
                }
                let inPicker = !args.flag("hidden")
                if !args.flag("yes") {
                    Out.box("模型目录写入预览（dry-run）")
                    print("将新增: \(slug) — \(name)（\(inPicker ? "菜单可见" : "先隐藏")）")
                    print("目录文件: \(CodexCatalogStore.defaultPath)")
                    print("确认后加 --yes 落盘。")
                    return
                }
                let added = try service.addCodexGatewayModel(slug: slug, displayName: name,
                                                             description: args.value("desc") ?? "", inPicker: inPicker)
                if Out.jsonMode { Out.json(["ok": true, "added": added, "slug": slug]); return }
                print(added ? "✅ 已新增 \(slug)（重启 Codex 后出现在顶部菜单）" : "ℹ️ 该 slug 已存在，未重复添加：\(slug)")

            case "show", "hide":
                guard let slug = args.value("slug") else { fail("用法：keyinject models \(action) --slug <模型名>") }
                let inPicker = (action == "show")
                let changed = try service.setCodexModelInPicker(slug: slug, inPicker: inPicker)
                if Out.jsonMode { Out.json(["ok": changed, "slug": slug, "inPicker": inPicker]); return }
                print(changed ? "✅ 已把 \(slug) 设为「\(inPicker ? "菜单可见" : "隐藏")」（重启 Codex 后生效）" : "❌ 目录中没有该 slug：\(slug)")

            case "rm":
                guard let slug = args.value("slug") else { fail("用法：keyinject models rm --slug <模型名>") }
                let removed = try service.removeCodexGatewayModel(slug: slug)
                if Out.jsonMode { Out.json(["ok": removed, "slug": slug]); return }
                print(removed ? "✅ 已从目录删除 \(slug)" : "❌ 未删除（不是公司网关条目或不存在）：\(slug)")

            default:
                fail("用法：keyinject models [list [--all] | add | show | hide | rm]")
            }
        } catch { fail("\(error)") }
    }

    // MARK: gateway（Codex 网关路由守护）

    static func runGateway(_ service: KeyInjectorService, _ args: Args) {
        let action = args.rest.first ?? "check"
        let configPath = args.value("config")
        switch action {
        case "check":
            let status = service.checkCodexGatewayRouting(configPath: configPath)
            if Out.jsonMode {
                Out.json(["ok": status.healthy, "configPath": status.configPath, "model": status.model ?? "",
                          "provider": status.provider ?? "", "exists": status.exists, "summary": status.summary])
                exit(status.healthy ? 0 : 1)
            }
            Out.box("Codex 网关路由体检")
            print(status.summary)
            if !status.healthy {
                print("   修复：keyinject gateway repair --yes")
            }
            exit(status.healthy ? 0 : 1)

        case "repair":
            let dryRun = !args.flag("yes")
            let quiet = args.flag("quiet")
            let logPath = args.value("log")
            do {
                let result = try service.repairCodexGatewayRouting(configPath: configPath, dryRun: dryRun)
                // 心跳模式下：只在真正修复时写日志，避免每 N 秒刷一行噪音
                if quiet, !dryRun {
                    if result.changed {
                        emit("已自动修复：\(result.status.model ?? "-") → provider=\(result.status.provider ?? "-") 备份=\(result.backupPath ?? "无")", to: logPath)
                    }
                    return
                }
                if Out.jsonMode {
                    Out.json(["ok": true, "changed": result.changed, "dryRun": result.dryRun,
                              "backupPath": result.backupPath ?? "", "configPath": result.status.configPath,
                              "model": result.status.model ?? "", "provider": result.status.provider ?? "",
                              "summary": result.status.summary])
                    return
                }
                Out.box("Codex 网关路由修复")
                print(result.status.summary)
                if !result.changed {
                    print("✅ 无需修复，配置已是网关路由。")
                } else if result.dryRun {
                    print("（dry-run，未写入。确认后加 --yes 落盘）")
                    if let preview = result.preview { print(preview) }
                } else {
                    print("✅ 已写入修复结果；原文件已备份：\(result.backupPath ?? "(无备份)")")
                    print("   完全退出并重新打开 Codex 后生效。")
                }
            } catch { fail("\(error)") }

        case "watch":
            let interval = Double(args.value("interval") ?? "10") ?? 10
            runGatewayWatch(service, configPath: configPath, interval: max(2, interval), logPath: args.value("log"))

        case "install-agent":
            let interval = Int(args.value("interval") ?? "15") ?? 15
            do {
                let result = try GatewayGuardAgent.install(intervalSeconds: max(5, interval), codexHome: args.value("home"))
                if Out.jsonMode { Out.json(["ok": true].merging(result) { _, new in new }); return }
                Out.box("已安装 launchd 常驻守护")
                for (key, value) in result.sorted(by: { $0.key < $1.key }) { print("\(key): \(value)") }
                print("查看日志: \(result["log"] ?? "")")
                print("卸载: keyinject gateway uninstall-agent")
            } catch { fail("\(error)") }

        case "uninstall-agent":
            do {
                let result = try GatewayGuardAgent.uninstall()
                if Out.jsonMode { Out.json(["ok": true].merging(result) { _, new in new }); return }
                Out.box("已卸载 launchd 常驻守护")
                for (key, value) in result.sorted(by: { $0.key < $1.key }) { print("\(key): \(value)") }
            } catch { fail("\(error)") }

        default:
            fail("用法：keyinject gateway [check | repair [--yes] | watch | install-agent | uninstall-agent] [--config <config.toml 路径>]")
        }
    }
}
