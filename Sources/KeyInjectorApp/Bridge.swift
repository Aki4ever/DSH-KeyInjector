// ==============================================================================
// JS ↔ Swift 桥接层
//
// 约定：
//   · 前端调用 window.webkit.messageHandlers.bridge.postMessage({id, method, params})
//   · 本层处理后回调 window.__bridgeResolve({id, ok, result|error})
//   · 所有返回值必须是 JSON 可序列化类型；密钥明文只在显式请求时才回传，
//     默认一律回传掩码与指纹。
// ==============================================================================
import Foundation
import WebKit
import KeyInjectorCore

final class Bridge: NSObject, WKScriptMessageHandler {

    weak var webView: WKWebView?
    private var service: KeyInjectorService?
    private var bootError: String?
    private var secretCache: [String: String] = [:]

    override init() {
        super.init()
        do {
            service = try KeyInjectorService()
        } catch {
            bootError = "\(error)"
        }
    }

    // MARK: 消息入口

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any],
              let id = body["id"] as? String,
              let method = body["method"] as? String else {
            return
        }
        let params = (body["params"] as? [String: Any]) ?? [:]

        // 异步方法单独处理
        if method == "checkKey" {
            let keyID = (params["id"] as? String) ?? ""
            runAsync(id: id) { svc in
                let summary = try await svc.checkKey(id: keyID)
                return JSONMapping.check(summary)
            }
            return
        }
        if method == "checkAll" {
            runAsync(id: id) { svc in
                let results = try await svc.checkAllKeys()
                let ok = results.values.filter { $0.status == .valid }.count
                return ["total": results.count, "valid": ok] as [String: Any]
            }
            return
        }
        // 模型发现：真实联网动作，必须显式触发（绝不在启动时自动发起）
        if method == "discoverKey" {
            let keyID = (params["id"] as? String) ?? ""
            runAsync(id: id) { svc in
                let result = try await svc.discoverModels(forKeyID: keyID)
                return JSONMapping.discovery(result)
            }
            return
        }
        if method == "discoverAll" {
            runAsync(id: id) { svc in
                let results = try await svc.discoverAllModels()
                var out: [String: Any] = [:]
                for (keyID, result) in results { out[keyID] = JSONMapping.discovery(result) }
                let probed = results.values.filter { $0.probed }.count
                return ["results": out, "total": results.count, "probed": probed] as [String: Any]
            }
            return
        }
        // 只读补齐：对没有缓存的 Key 静默执行一次发现（每个 Key 只请求一次）
        if method == "ensureDiscoveries" {
            let ids = (params["ids"] as? [String]) ?? []
            runAsync(id: id) { svc in
                let keys = try svc.listKeys()
                var out: [String: Any] = [:]
                for record in keys where ids.isEmpty || ids.contains(record.id) {
                    let result = await svc.ensureDiscoveredModels(for: record)
                    out[record.id] = JSONMapping.discovery(result)
                }
                return out
            }
            return
        }

        // 同步方法
        do {
            let result = try handle(method: method, params: params)
            reply(id: id, result: result)
        } catch {
            reply(id: id, error: "\(error)")
        }
    }

    private func handle(method: String, params: [String: Any]) throws -> Any {
        guard let service else {
            throw BridgeError.notReady(bootError ?? "服务未初始化")
        }

        switch method {
        case "info":
            var out: [String: Any] = service.runtimeInfo()
            out["bootWarnings"] = service.bootWarnings
            return out

        case "providers":
            return service.providers.providers.map(JSONMapping.provider)

        case "targets":
            return service.targets.targets.map { JSONMapping.target($0) }

        case "keys":
            let reveal = (params["reveal"] as? Bool) ?? false
            // 走 listKeysWithModels：密钥卡需要直接展示「这个 Key 供给了哪些宿主模型」，
            // 这正是需求「从密钥库里就能看清模型清单」的落点。
            return try service.listKeysWithModels().map { record in
                var secret: String? = nil
                if let cached = secretCache[record.id] {
                    secret = cached
                } else if reveal {
                    secret = try? service.secret(for: record.id)
                    if let s = secret { secretCache[record.id] = s }
                }
                return JSONMapping.record(record, secret: secret)
            }

        // 密钥库分区视图：分区标题 = key 别名，一把 key 一个分区（需求 REQ-019）
        case "keysGrouped":
            let reveal = (params["reveal"] as? Bool) ?? false
            let groups = try service.keyGroups().map { group -> KeyInjectorService.KeyGroup in
                var copy = group
                copy.records = group.records.map { record -> KeyRecord in
                    var enriched = record
                    enriched.modelBindings = service.modelBindings(for: record)
                    return enriched
                }
                return copy
            }
            return groups.map { group -> [String: Any] in
                var json = JSONMapping.keyGroup(group)
                if reveal, let first = group.records.first, let secret = try? service.secret(for: first.id) {
                    json["secret"] = secret
                }
                return json
            }

        // 只读读取已缓存的发现结果（不联网）：密钥库首帧据此渲染「可提供模型」
        case "availableModels":
            let keys = try service.listKeys()
            var out: [String: Any] = [:]
            for record in keys {
                if let cached = service.cachedDiscovery(for: record) {
                    out[record.id] = JSONMapping.discovery(cached)
                }
            }
            return out

        // 单把密钥详情（需求 REQ-021）：元数据 + 可用模型 + 落点 + 审计摘要
        case "keyDetail":
            let id = (params["id"] as? String) ?? ""
            let detail = try service.keyDetail(id: id)
            return JSONMapping.keyDetail(detail)

        case "addKey":
            let providerID = (params["providerID"] as? String) ?? ""
            let label = (params["label"] as? String) ?? ""
            let secret = (params["secret"] as? String) ?? ""
            let priority = (params["priority"] as? Int) ?? 100
            let tags = (params["tags"] as? [String]) ?? []
            let note = (params["note"] as? String) ?? ""
            let baseURL = params["baseURL"] as? String
            let record = try service.addKey(providerID: providerID, label: label, secret: secret,
                                            priority: priority, tags: tags, note: note, baseURL: baseURL)
            secretCache[record.id] = secret.trimmingCharacters(in: .whitespacesAndNewlines)
            let provider = service.provider(id: providerID) ?? Provider(id: providerID, name: providerID, envKeys: [])
            return [
                "record": JSONMapping.record(record, secret: nil),
                "warnings": SecretValidator.warnings(secret: secret, provider: provider)
            ]

        case "updateKey":
            let id = (params["id"] as? String) ?? ""
            let label = params["label"] as? String
            let secret = params["secret"] as? String
            let priority = params["priority"] as? Int
            let tags = params["tags"] as? [String]
            let note = params["note"] as? String
            let baseURL = params["baseURL"] as? String
            let record = try service.updateKey(
                id: id,
                label: label,
                secret: secret,
                priority: priority,
                tags: tags,
                note: note,
                baseURL: baseURL
            )
            if let secret, !secret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                secretCache[record.id] = secret.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            let provider = service.provider(id: record.providerID) ?? Provider(id: record.providerID, name: record.providerID, envKeys: [])
            var warnings: [String] = []
            if let secret, !secret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                warnings = SecretValidator.warnings(secret: secret, provider: provider)
            }
            return [
                "record": JSONMapping.record(record, secret: nil),
                "warnings": warnings
            ]

        case "saveTarget":
            let id = ((params["id"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let name = ((params["name"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let providerIDRaw = ((params["providerID"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let providerID = providerIDRaw.isEmpty ? nil : providerIDRaw
            let formatRaw = ((params["format"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard let format = InjectionFormat(rawValue: formatRaw) else {
                throw BridgeError.badRequest("不支持的注入格式：\(formatRaw)")
            }
            let filePath = ((params["filePath"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let rawJsonPath = ((params["jsonPath"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let jsonPath = rawJsonPath.isEmpty ? [] : rawJsonPath.split(separator: ".").map { String($0) }
            let sectionRaw = ((params["section"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let section = sectionRaw.isEmpty ? nil : sectionRaw
            let itemKeyRaw = ((params["itemKey"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let itemKey = itemKeyRaw.isEmpty ? nil : itemKeyRaw
            let note = ((params["note"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

            let target = InjectionTarget(
                id: id.isEmpty ? "custom-\(UUID().uuidString.prefix(8).lowercased())" : id,
                name: name.isEmpty ? "自定义落点" : name,
                providerID: providerID,
                format: format,
                filePath: filePath,
                jsonPath: jsonPath,
                section: section,
                itemKey: itemKey,
                isCustom: true,
                note: note.isEmpty ? "用户自定义落点" : note
            )
            try service.addCustomTarget(target)
            return JSONMapping.target(target)

        case "deleteTarget":
            let id = (params["id"] as? String) ?? ""
            try service.removeCustomTarget(id: id)
            return ["id": id]

        case "deleteKey":
            let id = (params["id"] as? String) ?? ""
            let record = try service.removeKey(id: id)
            secretCache.removeValue(forKey: id)
            return ["label": record.label]

        case "setEnabled":
            let id = (params["id"] as? String) ?? ""
            let enabled = (params["enabled"] as? Bool) ?? true
            return JSONMapping.record(try service.setEnabled(id: id, enabled: enabled), secret: nil)

        case "setPriority":
            let id = (params["id"] as? String) ?? ""
            let priority = (params["priority"] as? Int) ?? 100
            return JSONMapping.record(try service.setPriority(id: id, priority: priority), secret: nil)

        case "plan":
            let targetID = (params["targetID"] as? String) ?? ""
            let keyID = (params["keyID"] as? String) ?? ""
            let reveal = (params["reveal"] as? Bool) ?? false
            let jsonPath = (params["jsonPath"] as? String).flatMap { raw -> [String]? in
                let parts = raw.split(separator: ".").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                return parts.isEmpty ? nil : parts
            }
            let plan = try service.planInjection(
                targetID: targetID,
                keyID: keyID,
                overridePath: (params["overridePath"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                jsonPathOverride: jsonPath,
                sectionOverride: (params["section"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                itemKeyOverride: (params["itemKey"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                cachedSecret: secretCache[keyID]
            )
            let secret = secretCache[keyID] ?? (try? service.secret(for: keyID)) ?? ""
            return JSONMapping.plan(plan, reveal: reveal, secret: secret)

        case "apply":
            let targetID = (params["targetID"] as? String) ?? ""
            let keyID = (params["keyID"] as? String) ?? ""
            let jsonPath = (params["jsonPath"] as? String).flatMap { raw -> [String]? in
                let parts = raw.split(separator: ".").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                return parts.isEmpty ? nil : parts
            }
            let plan = try service.planInjection(
                targetID: targetID,
                keyID: keyID,
                overridePath: (params["overridePath"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                jsonPathOverride: jsonPath,
                sectionOverride: (params["section"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                itemKeyOverride: (params["itemKey"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                cachedSecret: secretCache[keyID]
            )
            let outcome = try service.applyInjection(plan)
            var out = JSONMapping.outcome(outcome)
            out["blocked"] = plan.blocked
            out["blockedReason"] = plan.blockedReason ?? ""
            return out

        case "rollback":
            guard let auditID = params["auditID"] as? String,
                  let entry = service.audit.all().last(where: { $0.id == auditID }) else {
                throw BridgeError.badRequest("未找到该审计条目")
            }
            return JSONMapping.rollback(try service.rollback(entry: entry))

        case "rollbackLatest":
            let targetID = (params["targetID"] as? String) ?? ""
            let overridePath = (params["overridePath"] as? String) ?? ""
            let target = service.target(id: targetID)
            let raw = overridePath.isEmpty ? (target?.filePath ?? "") : overridePath
            let path = PathKit.expand(raw)
            guard let entry = service.latestInjectableEntry(targetID: targetID, filePath: path) else {
                throw BridgeError.badRequest("没有找到该落点的注入记录，无可回滚内容")
            }
            return JSONMapping.rollback(try service.rollback(entry: entry))

        case "audit":
            let limit = (params["limit"] as? Int) ?? 80
            return service.recentAudit(limit).map(JSONMapping.audit)

        case "exportConfig":
            let written = try service.exportConfigTemplates()
            return ["written": written, "dir": service.root.appendingPathComponent("config").path]

        case "models":
            let includeOfficial = (params["all"] as? Bool) ?? false
            let entries = service.codexCatalogEntries(includeOfficial: includeOfficial)
            return [
                "overview": service.codexCatalogOverview(),
                "models": entries.map { entry -> [String: Any] in
                    [
                        "slug": entry.slug,
                        "displayName": entry.displayName,
                        "description": entry.description,
                        "source": entry.sourceLabel,
                        "isGateway": entry.isGateway,
                        "inPicker": entry.inPicker
                    ]
                }
            ]

        // 跨宿主模型清单：DSH 设置文件 + Codex 网关目录，按归一化身份聚合。
        // 这是「模型清单并入密钥库」之后的全局总览视图数据源。
        case "hostModels":
            let records = service.hostModelRecords()
            let gateway = service.gatewayConfig()
            return [
                "overview": service.hostModelOverview(),
                // 网关事实源：模型清单与地址的唯一权威（界面据此说明「清单从哪来」）
                "gateway": [
                    "sourcePath": gateway.sourcePath,
                    "baseURL": gateway.baseURL,
                    "models": gateway.upstreamModels,
                    "routes": gateway.routes.map { ["route": $0.route, "upstreamModel": $0.upstreamModel] },
                    "available": gateway.isUsable
                ],
                "sync": Bridge.syncPlanJSON(service.planHostConfigSync()),
                "groups": service.hostModelGroups().map(JSONMapping.modelGroup),
                "records": records.map(JSONMapping.hostModel),
                "dshProviders": service.dshProviders().map { provider -> [String: Any] in
                    [
                        "id": provider.id,
                        "displayName": provider.displayName,
                        "api": provider.api,
                        "baseURL": provider.baseURL,
                        "apiKeyEnv": provider.apiKeyEnv,
                        "enabled": provider.enabled,
                        "modelIDs": provider.modelIDs
                    ]
                }
            ]

        case "syncPlan":
            // 只是预览，绝不落盘
            return Bridge.syncPlanJSON(service.planHostConfigSync())

        case "syncApply":
            let plan = service.applyHostConfigSync()
            return Bridge.syncPlanJSON(plan)

        case "switchGatewayModel":
            let model = (params["model"] as? String) ?? ""
            let dryRun = (params["dryRun"] as? Bool) ?? true
            let result = try service.switchCodexGatewayModel(to: model, dryRun: dryRun)
            return [
                "changed": result.changed,
                "dryRun": result.dryRun,
                "model": model,
                "provider": result.status.provider ?? "",
                "backupPath": result.backupPath ?? "",
                "configPath": result.status.configPath
            ]

        case "addModel":
            let slug = (params["slug"] as? String) ?? ""
            let name = (params["name"] as? String) ?? slug
            let desc = (params["desc"] as? String) ?? ""
            let inPicker = (params["inPicker"] as? Bool) ?? true
            let added = try service.addCodexGatewayModel(slug: slug, displayName: name, description: desc, inPicker: inPicker)
            return ["added": added, "slug": slug]

        case "setModelPicker":
            let slug = (params["slug"] as? String) ?? ""
            let inPicker = (params["inPicker"] as? Bool) ?? true
            let changed = try service.setCodexModelInPicker(slug: slug, inPicker: inPicker)
            return ["changed": changed, "slug": slug, "inPicker": inPicker]

        case "removeModel":
            let slug = (params["slug"] as? String) ?? ""
            let removed = try service.removeCodexGatewayModel(slug: slug)
            return ["removed": removed, "slug": slug]

        case "gatewayCheck":
            let status = service.checkCodexGatewayRouting()
            return ["healthy": status.healthy, "model": status.model ?? "", "provider": status.provider ?? "",
                    "exists": status.exists, "summary": status.summary, "configPath": status.configPath]

        case "gatewayRepair":
            let result = try service.repairCodexGatewayRouting(dryRun: false)
            return ["changed": result.changed, "backupPath": result.backupPath ?? "",
                    "summary": result.status.summary, "model": result.status.model ?? "",
                    "provider": result.status.provider ?? ""]

        case "openURL":
            let raw = (params["url"] as? String) ?? ""
            if let url = URL(string: raw), url.scheme == "https" || url.scheme == "http" {
                NSWorkspace.shared.open(url)
                return ["opened": raw]
            }
            throw BridgeError.badRequest("仅允许打开 http/https 链接")

        case "copy":
            let text = (params["text"] as? String) ?? ""
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(text, forType: .string)
            return ["copied": text.count]

        case "revealSecret":
            let id = (params["id"] as? String) ?? ""
            if let cached = secretCache[id] { return ["secret": cached] }
            let secret = try service.secret(for: id)
            secretCache[id] = secret
            return ["secret": secret]

        default:
            throw BridgeError.badRequest("未知方法：\(method)")
        }
    }

    // MARK: 同步计划 → 前端形状

    /// 把同步计划转成前端可直接渲染的形状
    static func syncPlanJSON(_ plan: HostConfigSync.Plan) -> [String: Any] {
        func target(_ result: HostConfigSync.Result) -> [String: Any] {
            var payload: [String: Any] = [
                "path": result.targetPath,
                "changed": result.changed,
                "dryRun": result.dryRun,
                "summary": result.summary,
                "notes": result.notes
            ]
            if let failure = result.failure { payload["failure"] = failure }
            if let backup = result.backupPath { payload["backupPath"] = backup }
            return payload
        }
        return [
            "gatewayPath": plan.gateway.sourcePath,
            "gatewayBaseURL": plan.gateway.baseURL,
            "gatewayModels": plan.gateway.upstreamModels,
            "anyChanged": plan.anyChanged,
            "allConsistent": plan.allConsistent,
            "dsh": target(plan.dsh),
            "codex": target(plan.codex)
        ]
    }

    // MARK: 异步任务

    private func runAsync(id: String, _ work: @escaping (KeyInjectorService) async throws -> Any) {
        guard let service else {
            reply(id: id, error: bootError ?? "服务未初始化")
            return
        }
        Task { [weak self] in
            do {
                let value = try await work(service)
                DispatchQueue.main.async { self?.reply(id: id, result: value) }
            } catch {
                DispatchQueue.main.async { self?.reply(id: id, error: "\(error)") }
            }
        }
    }

    // MARK: 回传

    private func reply(id: String, result: Any) {
        send(["id": id, "ok": true, "result": result])
    }

    private func reply(id: String, error: String) {
        send(["id": id, "ok": false, "error": error])
    }

    private func send(_ payload: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.withoutEscapingSlashes]),
              var json = String(data: data, encoding: .utf8) else {
            return
        }
        // 这两个码位在 JSON 中合法但在 JS 源文本中非法，必须转义后再注入
        json = json.replacingOccurrences(of: "\u{2028}", with: "\\u2028")
                   .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
        DispatchQueue.main.async { [weak self] in
            self?.webView?.evaluateJavaScript("window.__bridgeResolve(\(json));", completionHandler: nil)
        }
    }
}

enum BridgeError: Error, CustomStringConvertible {
    case notReady(String)
    case badRequest(String)

    var description: String {
        switch self {
        case .notReady(let m): return "服务未就绪：\(m)"
        case .badRequest(let m): return m
        }
    }
}
