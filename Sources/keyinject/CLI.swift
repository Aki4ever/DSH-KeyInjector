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

/// 只到日期（模型发布时间精确到天即可，展示到秒属虚假精度）
func shortDate(_ date: Date) -> String {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd"
    return f.string(from: date)
}

/// 模型三维度里的时间维度：只在协议真的给了字段时才输出，缺席即缺席
func metadataJSON(_ meta: ModelMetadata?) -> [String: Any] {
    guard let meta else { return [:] }
    var out: [String: Any] = [:]
    if let published = meta.publishedAt { out["publishedAt"] = iso(published) }
    if let source = meta.publishedSource { out["publishedSource"] = source }
    if let tag = meta.versionTag { out["versionTag"] = tag }
    if let shutdown = meta.shutdownDate { out["shutdownDate"] = shutdown }
    return out
}

/// 模型三维度里的额度维度：**只有协议提供时才有值**（当前实测仅 DeepSeek）
///
/// `supported = false` 与 `null` 语义不同：
/// - `null`：该厂商预设里没有余额端点，本工具**没有发起**请求；
/// - `supported = false`：发了但明确不可得／未配置。
/// 界面与脚本据此区分「不提供」和「取不到」，不会把缺数据误读成余额为零。
func balanceJSON(_ balance: BalanceInfo?) -> Any {
    guard let balance else { return NSNull() }
    return [
        "supported": balance.supported,
        "available": balance.isAvailable.map { $0 as Any } ?? NSNull(),
        "summary": balance.summary,
        "endpoint": balance.endpoint,
        "httpStatus": balance.httpStatus,
        "note": balance.note,
        "fetchedAt": iso(balance.fetchedAt),
        "entries": balance.entries.map { ["currency": $0.currency, "total": $0.total,
                                          "granted": $0.granted, "toppedUp": $0.toppedUp] }
    ]
}

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
    keyinject — AI API Key 账号管理器（KeyInjector CLI）

    用法：
      keyinject <子命令> [参数...]

    子命令：
      info                              显示数据目录、密钥后端与审计文件位置
      providers                         列出内置厂商目录
      targets                           列出可注入落点
      keys                              按 key 别名分区列出密钥（可用模型优先取缓存，不联网）
      keys --grouped [--json]           显式要求分区输出（含分区计数，便于脚本消费）
      keys add                          新增密钥
          --provider <厂商id> --label <别名> (--secret <明文> | --secret-stdin | --secret-env <变量名>)
          [--priority <数值>] [--tags a,b] [--note <备注>]
      keys rm --id <密钥id>             删除密钥（同时清除钥匙串明文）
      keys enable|disable --id <密钥id> 启用 / 禁用密钥
      key show --id <密钥id> [--probe]  单把密钥详情：可用模型 + 注入落点 + 审计摘要（--probe 先联网实测）
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
      gateway switch --model <模型名> [--yes]
                                        一键切换 Codex 当前使用的网关模型（默认 dry-run）
      models list [--all]               列出模型目录条目（默认只看公司网关模型，含来源与菜单可见性）
      models probe --id <密钥id>        识别该密钥可提供的模型：优先探测其端点 /models，失败自动降级
      models probe --all                对所有密钥执行一次模型识别（显式联网动作，不做后台轮询）
      models add --slug <模型名> --name <菜单显示名> [--desc <说明>] [--hidden] [--yes]
      models show|hide --slug <模型名>   在 Codex 顶部菜单中显示 / 隐藏该模型
      models rm --slug <模型名>          从目录删除公司网关模型（官方条目不可删）
      hosts list                        跨宿主模型清单总览（DSH 设置文件 + Codex 网关目录，按模型身份去重）
      hosts keys                        列出每个密钥供给了哪些宿主模型（凭据键名 / 端点两种依据）
      sync                              把网关声明的模型清单同步到 DSH 与 Codex（默认 dry-run）
      sync --yes                        落盘同步（每个目标写入前自动备份）
      sync 可覆盖路径：--gateway-config <路径> --dsh-settings <路径> --codex-catalog <路径>

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
            else { print("\(AppVersion.productName) CLI v\(AppVersion.current)") }
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
        case "key":                 await runKey(service, args)
        case "inject":              runInject(service, args)
        case "rollback":            runRollback(service, args)
        case "check":               await runCheck(service, args)
        case "audit":               runAudit(service, args)
        case "config":              runConfig(service, args)
        case "gateway":             runGateway(service, args)
        case "models":              await runModels(service, args)
        case "hosts":               runHosts(service, args)
        case "sync":                runSync(service, args)
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
                // 用 listKeysWithModels：密钥列表同时回答「这个 Key 供给了哪些宿主模型」。
                // --grouped 时再按 key 别名分区，并附上已缓存的「可提供模型」（只读，不联网）。
                let grouped = args.flag("grouped")
                let keys = try service.listKeysWithModels()
                func cachedModelsJSON(_ k: KeyRecord) -> Any {
                    guard let cached = service.cachedDiscovery(for: k) else { return NSNull() }
                    return ["probed": cached.probed, "endpoint": cached.endpoint, "note": cached.note,
                            "sourceLabel": cached.sourceLabel, "fetchedAt": iso(cached.fetchedAt),
                            // REQ-024：额度与时间两个维度随缓存的识别结果一起返回
                            "balance": balanceJSON(cached.balance),
                            "models": cached.normalizedModels.map { m -> [String: Any] in
                                var item: [String: Any] = ["modelID": m.modelID, "source": m.source.rawValue,
                                                           "sourceLabel": m.source.label,
                                                           "confidence": m.source.confidence, "evidence": m.evidence,
                                                           "host": m.host?.rawValue ?? ""]
                                item.merge(metadataJSON(m.metadata)) { _, new in new }
                                return item
                            }]
                }
                if Out.jsonMode {
                    let list = keys.map { k -> [String: Any] in
                        ["id": k.id, "providerID": k.providerID, "providerName": service.providers.name(of: k.providerID),
                         "label": k.label, "hint": k.hint, "fingerprint": k.fingerprint, "enabled": k.enabled,
                         "priority": k.priority, "tags": k.tags, "note": k.note,
                         "modelBindings": k.modelBindings.map { ["modelID": $0.modelID, "displayName": $0.displayName,
                                                                    "host": $0.host.rawValue, "owner": $0.owner,
                                                                    "credentialKey": $0.credentialKey,
                                                                    "endpoint": $0.endpoint, "matchedBy": $0.matchedBy,
                                                                    "inMenu": $0.inMenu] },
                         "discovery": cachedModelsJSON(k),
                         "createdAt": iso(k.createdAt), "updatedAt": iso(k.updatedAt),
                         "lastCheck": k.lastCheck.map { ["status": $0.status.rawValue, "label": $0.status.label, "message": $0.message, "checkedAt": iso($0.checkedAt), "httpStatus": $0.httpStatus ?? 0, "latencyMS": $0.latencyMS ?? 0] } as Any]
                    }
                    var payload: [String: Any] = ["ok": true, "count": keys.count,
                                                  "storeBackend": service.vault.backendName, "keys": list]
                    if grouped {
                        payload["groups"] = try service.keyGroups().map { group -> [String: Any] in
                            ["label": group.label, "modelCount": group.modelCount,
                             "keyIDs": group.records.map { $0.id }]
                        }
                    }
                    Out.json(payload)
                    return
                }
                Out.box("密钥库（\(keys.count) 条 · 后端：\(service.vault.backendName)）")
                if keys.isEmpty { print("（空。用 `keyinject keys add --provider deepseek --label 主力 --secret-stdin` 添加）") }
                let groups = try service.keyGroups()
                for group in groups {
                    for k in group.records {
                        let status = k.lastCheck?.status.label ?? "未探测"
                        // 分区标题 = key 别名（一把 key 一个分区）
                        print("▸ \(group.label)\(group.records.count > 1 ? "（\(group.records.count) 把）" : "")")
                        print("• [\(k.enabled ? "启用" : "禁用")] \(service.providers.name(of: k.providerID))")
                        print("    id: \(k.id)")
                        print("    掩码 \(k.hint)  指纹 \(k.fingerprint)  优先级 \(k.priority)  探测: \(status)")
                        if let cached = service.cachedDiscovery(for: k) {
                            let models = cached.normalizedModels
                            print("    可提供模型 \(models.count) 个（来源：\(cached.sourceLabel)）：")
                            for m in models.prefix(12) {
                                var line = "      - \(m.modelID)  [\(m.source.label)] \(m.evidence)"
                                if let published = m.metadata?.publishedAt {
                                    line += "  更新时间 \(shortDate(published))"
                                }
                                print(line)
                            }
                            if models.count > 12 { print("      … 其余 \(models.count - 12) 个见 `keyinject key show <id>`") }
                            if let balance = cached.balance {
                                print("    账户额度: \(balance.supported ? balance.summary : "该协议不提供（\(balance.note)）")")
                            }
                        } else if !k.modelBindings.isEmpty {
                            let models = k.modelBindings.map { "\($0.host.label)/\($0.modelID)" }.joined(separator: "、")
                            print("    供给模型（宿主映射，未探测）: \(models)")
                            print("    提示: 运行 `keyinject models probe --id \(k.id)` 从该 Key 端点实测")
                        } else {
                            print("    尚无模型信息：可运行 `keyinject models probe --id \(k.id)`")
                        }
                    }
                }
            } catch { fail("\(error)") }
        }
    }

    // MARK: key show（单把密钥详情）

    static func runKey(_ service: KeyInjectorService, _ args: Args) async {
        let action = args.rest.first ?? "show"
        guard action == "show" else {
            fail("用法：keyinject key show --id <密钥id> [--probe] [--json]")
        }
        guard let id = args.value("id") else { fail("缺少 --id 参数") }

        do {
            if args.flag("probe") {
                let result = try await service.discoverModels(forKeyID: id)
                if !Out.jsonMode {
                    Out.box("模型发现")
                    print("来源: \(result.sourceLabel)   端点: \(result.endpoint.isEmpty ? "—" : result.endpoint)")
                    print("说明: \(result.note)")
                }
            }
            let detail = try service.keyDetail(id: id)
            let models = detail.availableModels
            if Out.jsonMode {
                var out: [String: Any] = [
                    "ok": true,
                    "id": detail.record.id,
                    "label": detail.record.label,
                    "providerID": detail.record.providerID,
                    "enabled": detail.record.enabled,
                    "priority": detail.record.priority,
                    "hint": detail.record.hint,
                    "fingerprint": detail.record.fingerprint,
                    "baseURL": detail.record.baseURL ?? "",
                    "probeable": detail.probeable,
                    "availableModels": models.map { m -> [String: Any] in
                        var item: [String: Any] = ["modelID": m.modelID, "displayName": m.displayName,
                                                   "source": m.source.rawValue,
                                                   "sourceLabel": m.source.label, "confidence": m.source.confidence,
                                                   "evidence": m.evidence, "host": m.host?.rawValue ?? "",
                                                   "owner": m.owner, "inMenu": m.inMenu,
                                                   "credentialKey": m.credentialKey, "endpoint": m.endpoint]
                        item.merge(metadataJSON(m.metadata)) { _, new in new }
                        return item
                    },
                    "locations": detail.locations.map { l -> [String: Any] in
                        ["targetID": l.targetID, "targetName": l.targetName, "filePath": l.filePath,
                         "itemKey": l.itemKey, "lastInjectedAt": iso(l.lastInjectedAt)]
                    },
                    "audit": detail.auditEntries.map { ["id": $0.id, "action": $0.action.rawValue,
                                                         "actionLabel": $0.action.label, "result": $0.result,
                                                         "message": $0.message, "timestamp": iso($0.timestamp)] }
                ]
                if let d = detail.discovery {
                    // 与 GUI / keys --grouped 保持同一口径：modelCount 是去重后的数量
                    out["discovery"] = ["probed": d.probed, "endpoint": d.endpoint, "note": d.note,
                                        "sourceLabel": d.sourceLabel, "fetchedAt": iso(d.fetchedAt),
                                        "httpStatus": d.httpStatus, "modelCount": d.modelCount,
                                        "balance": balanceJSON(d.balance),
                                        "models": d.normalizedModels.map { m -> [String: Any] in
                                            var item: [String: Any] = ["modelID": m.modelID, "displayName": m.displayName,
                                                                       "source": m.source.rawValue, "sourceLabel": m.source.label,
                                                                       "confidence": m.source.confidence, "evidence": m.evidence,
                                                                       "host": m.host?.rawValue ?? "", "owner": m.owner,
                                                                       "inMenu": m.inMenu, "credentialKey": m.credentialKey,
                                                                       "endpoint": m.endpoint]
                                            item.merge(metadataJSON(m.metadata)) { _, new in new }
                                            return item
                                        }]
                } else {
                    out["discovery"] = NSNull()
                }
                Out.json(out)
                return
            }
            Out.box("密钥详情：\(detail.record.label)")
            print("厂商      : \(service.providers.name(of: detail.record.providerID))")
            print("状态      : \(detail.record.enabled ? "启用" : "禁用")   优先级 \(detail.record.priority)")
            print("掩码/指纹 : \(detail.record.hint)  \(detail.record.fingerprint)")
            print("端点      : \(detail.record.baseURL ?? "（厂商默认）")")
            print("探测能力  : \(detail.probeable ? "具备（可拉取 /models）" : "无端点，无法探测")")
            if let d = detail.discovery {
                print("模型来源  : \(d.sourceLabel)   更新于 \(iso(d.fetchedAt))")
                print("发现说明  : \(d.note)")
                if let balance = d.balance {
                    print("账户额度  : \(balance.supported ? balance.summary : "该协议不提供（\(balance.note)）")")
                }
            } else {
                print("模型来源  : 尚未探测（运行 keyinject models probe --id \(detail.record.id)）")
            }
            print("")
            print("可提供模型（\(models.count) 个）：")
            for m in models {
                let host = m.host.map { " \($0.label)" } ?? ""
                print("  [\(m.source.label)] \(m.modelID)\(host)  — \(m.evidence)")
                if let meta = m.metadata {
                    var bits: [String] = []
                    if let published = meta.publishedAt { bits.append("更新时间 \(shortDate(published))") }
                    if let tag = meta.versionTag { bits.append("版本 \(tag)") }
                    if let shutdown = meta.shutdownDate { bits.append("下线 \(shutdown)") }
                    if !bits.isEmpty { print("      " + bits.joined(separator: " · ")) }
                }
            }
            if models.isEmpty { print("  （暂无。端点未探测成功且宿主未声明绑定该 Key 的模型）") }
            print("")
            print("注入落点（\(detail.locations.count) 个）：")
            for l in detail.locations {
                print("  · \(l.targetName)（\(l.targetID)）键名 \(l.itemKey)  最近 \(iso(l.lastInjectedAt))")
                print("    \(l.filePath)")
            }
            if detail.locations.isEmpty { print("  （尚未注入到任何落点）") }
        } catch { fail("\(error)") }
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
                if !plan.suppliedModels.isEmpty {
                    // dry-run 阶段就把「这个 Key 供给了哪些宿主模型」摆出来，
                    // 避免出现「注入成功但宿主菜单里对不上」的困惑。
                    let summary = plan.suppliedModels.map { "\($0.host.label):\($0.modelID)" }.joined(separator: "、")
                    print("供给模型  : \(summary)")
                }
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

    // MARK: hosts（跨宿主模型清单 + 密钥供给关系）

    /// 列出 DSH 与 Codex 两个宿主的模型清单，并显示每个模型由哪个密钥供给。
    ///
    /// 与 `keyinject models` 的分工：`models` 面向 Codex 目录的**写入**（add/show/hide/rm），
    /// `hosts` 面向两个宿主的**只读总览**，回答「这些模型是从哪来的、是谁在供」。
    static func runHosts(_ service: KeyInjectorService, _ args: Args) {
        let action = args.rest.first ?? "list"

        switch action {
        case "list":
            let groups = service.hostModelGroups()
            let overview = service.hostModelOverview()
            if Out.jsonMode {
                Out.json([
                    "ok": true,
                    "overview": overview,
                    "models": groups.map { group in
                        [
                            "normalizedID": group.normalizedID,
                            "displayName": group.displayName,
                            "aliases": group.aliases,
                            "hosts": group.hosts.map { $0.rawValue },
                            "records": group.records.map { record in
                                ["id": record.id, "host": record.host.rawValue, "owner": record.owner,
                                 "credentialKey": record.credentialKey, "endpoint": record.endpoint,
                                 "inMenu": record.inMenu]
                            }
                        ] as [String: Any]
                    }
                ])
                return
            }
            Out.box("宿主模型清单总览（去重后 \(groups.count) 个模型 / 共 \(overview["total"] ?? 0) 条记录）")
            print("DSH 宿主设置 : \(overview["dshSettingsPath"] ?? "-")")
            print("             存在=\((overview["dshSettingsExists"] as? Bool ?? false) ? "是" : "否")  声明模型=\(overview["dshCount"] ?? 0)  凭据已配置=\(overview["dshCredentialConfigured"] ?? 0)/\(overview["dshDeclared"] ?? 0)")
            print("Codex 目录   : \(overview["codexCatalogPath"] ?? "-")")
            print("             网关条目=\(overview["codexGatewayCount"] ?? 0)  官方条目=\(overview["codexOfficialCount"] ?? 0)")
            print("Codex 网关端点: \(overview["codexEndpoint"] ?? "(未声明)")")
            print("Codex 当前路由: model=\(overview["codexConfigModel"] ?? "(未设置)") → provider=\(overview["codexConfigProvider"] ?? "(未设置)")  \(((overview["codexRoutingHealthy"] as? Bool) ?? true) ? "正常" : "⚠️ 异常")")
            print("")
            for group in groups {
                let hosts = group.hosts.map { $0.label }.joined(separator: " + ")
                print("• \(group.displayName)  [\(hosts)]")
                for record in group.records {
                    let cred = record.credentialKey.isEmpty ? "凭据=网关自持" : "凭据键=\(record.credentialKey)"
                    print("    - \(record.host.label): \(record.id)  (\(cred)\(record.endpoint.isEmpty ? "" : "  端点=\(record.endpoint)"))")
                }
            }
            print("\n提示：`keyinject hosts keys` 查看每个密钥供给了哪些模型。")

        case "keys":
            let records = (try? service.listKeysWithModels()) ?? []
            if Out.jsonMode {
                Out.json([
                    "ok": true,
                    "keys": records.map { record in
                        ["id": record.id, "label": record.label, "providerID": record.providerID,
                         "models": record.modelBindings.map { ["modelID": $0.modelID, "host": $0.host.rawValue,
                                                                  "displayName": $0.displayName, "matchedBy": $0.matchedBy] }]
                    }
                ])
                return
            }
            Out.box("密钥 → 模型 供给关系")
            if records.isEmpty { print("密钥库为空。"); return }
            for record in records {
                let models = record.modelBindings
                print("• \(record.label)  [\(record.providerID)]")
                if models.isEmpty {
                    print("    （未绑定任何宿主模型：凭据键名与端点都没命中宿主声明）")
                }
                for binding in models {
                    let menu = binding.inMenu ? "菜单可见" : "已隐藏"
                    print("    - \(binding.host.label) · \(binding.modelID)  (\(menu)，依据：\(binding.matchedBy))")
                }
            }

        default:
            fail("用法：keyinject hosts [list | keys | gateway]")
        }
    }

    // MARK: sync（网关清单 → 两个客户端）

    /// 把网关声明的模型清单同步到 DSH 与 Codex 客户端配置。
    ///
    /// 默认 dry-run（只出差异，不落盘）：与注入流程同一条原则——先看再写。
    static func runSync(_ service: KeyInjectorService, _ args: Args) {
        let apply = args.flag("yes") || args.flag("apply")
        let gatewayPath = args.value("gateway-config") ?? GatewayConfig.defaultPath
        let dshPath = args.value("dsh-settings") ?? DshModelCatalog.defaultSettingsPath
        let codexPath = args.value("codex-catalog") ?? CodexCatalogStore.defaultPath
        // 默认 merge（只增不减）。--prune 才改为完全对齐网关声明，
        // 避免「网关只声明了两条线路」时把用户自己在宿主里加的模型删掉。
        let mode: HostConfigSync.MergeMode = args.flag("prune") ? .replace : .merge

        let plan = apply
            ? service.applyHostConfigSync(gatewayPath: gatewayPath, dshSettingsPath: dshPath, codexCatalogPath: codexPath, mergeMode: mode)
            : service.planHostConfigSync(gatewayPath: gatewayPath, dshSettingsPath: dshPath, codexCatalogPath: codexPath, mergeMode: mode)

        if Out.jsonMode {
            Out.json([
                "ok": plan.dsh.succeeded && plan.codex.succeeded,
                "applied": apply,
                "mergeMode": mode.rawValue,
                "gateway": [
                    "sourcePath": plan.gateway.sourcePath,
                    "baseURL": plan.gateway.baseURL,
                    "models": plan.gateway.upstreamModels,
                    "routes": plan.gateway.routes.map { ["route": $0.route, "upstreamModel": $0.upstreamModel] }
                ],
                "targets": [
                    SyncJSON.target(plan.dsh),
                    SyncJSON.target(plan.codex)
                ]
            ])
            return
        }

        Out.box(apply ? "同步网关清单 → 客户端（已落盘）" : "同步网关清单 → 客户端（dry-run，未写入）")
        print("网关事实源 : \(plan.gateway.sourcePath)")
        if plan.gateway.isUsable {
            print("             地址=\(plan.gateway.baseURL)  声明模型=\(plan.gateway.upstreamModels.count)")
            for route in plan.gateway.routes {
                print("             · \(route.route) → \(route.upstreamModel)")
            }
        } else {
            print("             ⚠️ 读不到网关声明的模型清单，已跳过全部同步")
        }
        print("")
        SyncJSON.printTarget("DSH 设置", plan.dsh)
        SyncJSON.printTarget("Codex 目录", plan.codex)

        if !apply, plan.anyChanged {
            print("\n提示：确认无误后执行 `keyinject sync --yes` 落盘（每个目标写入前自动备份）。")
        } else if apply {
            let backups = [plan.dsh.backupPath, plan.codex.backupPath].compactMap { $0 }
            if !backups.isEmpty { print("\n已备份：") ; backups.forEach { print("  \($0)") } }
            if plan.allConsistent { print("\n两个客户端均已与网关一致，未写入任何内容。") }
        } else {
            print("\n两个客户端均已与网关一致，未写入任何内容。")
        }
    }

    enum SyncJSON {
        static func target(_ result: HostConfigSync.Result) -> [String: Any] {
            var payload: [String: Any] = [
                "path": result.targetPath,
                "changed": result.changed,
                "summary": result.summary,
                "notes": result.notes
            ]
            if let failure = result.failure { payload["failure"] = failure }
            if let backup = result.backupPath { payload["backupPath"] = backup }
            return payload
        }

        static func printTarget(_ label: String, _ result: HostConfigSync.Result) {
            print("\(label) : \(result.targetPath)")
            let mark = result.failure != nil ? "⚠️ " : (result.changed ? "✏️ " : "✅ ")
            print("             \(mark)\(result.summary)")
            for note in result.notes { print("                · \(note)") }
            if let failure = result.failure { print("                ⚠️ \(failure)") }
        }
    }

    // MARK: models（Codex 模型目录 + 密钥可用模型探测）

    static func runModels(_ service: KeyInjectorService, _ args: Args) async {
        let action = args.rest.first ?? "list"
        do {
            switch action {
            case "probe":
                // 模型发现：显式联网动作，探测该 Key 端点的 /models，失败自动降级
                let id = args.value("id")
                let all = args.flag("all")
                if id == nil && !all { fail("用法：keyinject models probe (--id <密钥id> | --all) [--json]") }
                if let id {
                    let result = try await service.discoverModels(forKeyID: id)
                    if Out.jsonMode {
                        Out.json(["ok": true, "id": id, "probed": result.probed, "endpoint": result.endpoint,
                                  "httpStatus": result.httpStatus, "note": result.note,
                                  "sourceLabel": result.sourceLabel, "fetchedAt": iso(result.fetchedAt),
                                  "balance": balanceJSON(result.balance),
                                  "models": result.normalizedModels.map { m -> [String: Any] in
                                      var item: [String: Any] = ["modelID": m.modelID, "source": m.source.rawValue, "sourceLabel": m.source.label,
                                                                 "confidence": m.source.confidence, "evidence": m.evidence,
                                                                 "host": m.host?.rawValue ?? ""]
                                      // REQ-024：三维度里的时间维度原样交给脚本，缺席即缺席（不做兜底填充）
                                      if let meta = m.metadata {
                                          if let published = meta.publishedAt { item["publishedAt"] = iso(published) }
                                          if let src = meta.publishedSource { item["publishedSource"] = src }
                                          if let tag = meta.versionTag { item["versionTag"] = tag }
                                          if let shutdown = meta.shutdownDate { item["shutdownDate"] = shutdown }
                                      }
                                      return item
                                  }])
                        return
                    }
                    let label = (try? service.listKeys())?.first { $0.id == id }?.label ?? id
                    Out.box("模型发现（\(label)）")
                    print("来源: \(result.sourceLabel)")
                    print("端点: \(result.endpoint.isEmpty ? "—" : result.endpoint)")
                    print("说明: \(result.note)")
                    if let balance = result.balance {
                        print(balance.supported
                              ? "额度: \(balance.summary)\(balance.endpoint.isEmpty ? "" : "（\(balance.endpoint)）")"
                              : "额度: 该协议不提供（\(balance.note)）")
                    }
                    print("")
                    for m in result.normalizedModels {
                        print("  [\(m.source.label)] \(m.modelID)  — \(m.evidence)")
                        if let meta = m.metadata {
                            var bits: [String] = []
                            if let published = meta.publishedAt { bits.append("更新时间 \(shortDate(published))") }
                            if let tag = meta.versionTag { bits.append("版本 \(tag)") }
                            if let shutdown = meta.shutdownDate { bits.append("下线 \(shutdown)") }
                            if !bits.isEmpty { print("      " + bits.joined(separator: " · ")) }
                        }
                    }
                    if result.normalizedModels.isEmpty { print("  （没有识别到任何模型）") }
                    return
                }
                let results = try await service.discoverAllModels()
                let keys = try service.listKeys()
                if Out.jsonMode {
                    var out: [String: Any] = [:]
                    for (keyID, result) in results {
                        out[keyID] = ["probed": result.probed, "endpoint": result.endpoint, "note": result.note,
                                      "sourceLabel": result.sourceLabel, "modelCount": result.normalizedModels.count,
                                      "models": result.normalizedModels.map { $0.modelID }]
                    }
                    Out.json(["ok": true, "total": results.count,
                              "probed": results.values.filter { $0.probed }.count, "results": out])
                    return
                }
                Out.box("批量模型发现（\(results.count) 把密钥）")
                for key in keys {
                    guard let result = results[key.id] else { continue }
                    let mark = result.probed ? "✅" : "⚠️"
                    print("\(mark) \(key.label)：\(result.sourceLabel) · \(result.normalizedModels.count) 个模型")
                    print("    \(result.note)")
                }

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
                fail("用法：keyinject models [list [--all] | probe (--id <密钥id> | --all) | add | show | hide | rm]")
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

        case "switch":
            // 一键切换 Codex 当前使用的网关模型。
            // 这是「Gemini 额度耗尽要手动换模型」这个维护点的最小代价替代：
            // 不自动替你换（用户明确选择只告警），但把「换模型」从
            // 「打开 Codex → 找菜单 → 选模型 → 确认 provider」压缩成一条命令。
            let target = args.value("model") ?? ""
            let available = GatewayConfig.declaredModels()
            guard !available.isEmpty else {
                fail("读不到网关声明的模型清单（\(GatewayConfig.defaultPath)），无法切换。")
            }
            let chosen = target.isEmpty ? (available.first ?? "") : target
            guard !chosen.isEmpty else { fail("没有可切换的网关模型。") }
            if !available.contains(chosen) {
                print("⚠️ \(chosen) 不在网关声明的清单里；仍会写入，但网关可能拒绝该模型。")
                print("   网关声明的模型：\(available.joined(separator: "、"))")
            }
            let dryRun = !args.flag("yes")
            do {
                let result = try service.switchCodexGatewayModel(to: chosen, configPath: configPath, dryRun: dryRun)
                if Out.jsonMode {
                    Out.json(["ok": true, "changed": result.changed, "dryRun": result.dryRun,
                              "model": chosen, "provider": result.status.provider ?? "",
                              "configPath": result.status.configPath,
                              "backupPath": result.backupPath ?? ""])
                    return
                }
                Out.box("切换 Codex 网关模型")
                print("目标模型 : \(chosen)")
                if !result.changed {
                    print("✅ 已经是该模型，配置未变。")
                } else if dryRun {
                    print("（dry-run，未写入。确认后加 --yes 落盘）")
                    if let preview = result.preview { print(preview) }
                } else {
                    print("✅ 已切换；原文件已备份：\(result.backupPath ?? "(无备份)")")
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
            fail("用法：keyinject gateway [check | repair [--yes] | switch --model <模型名> [--yes] | watch | install-agent | uninstall-agent] [--config <config.toml 路径>]")
        }
    }
}
