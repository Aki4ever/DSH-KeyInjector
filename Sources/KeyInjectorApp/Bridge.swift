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
            return try service.listKeys().map { record in
                JSONMapping.record(record, secret: reveal ? try? service.secret(for: record.id) : nil)
            }

        case "addKey":
            let providerID = (params["providerID"] as? String) ?? ""
            let label = (params["label"] as? String) ?? ""
            let secret = (params["secret"] as? String) ?? ""
            let priority = (params["priority"] as? Int) ?? 100
            let tags = (params["tags"] as? [String]) ?? []
            let note = (params["note"] as? String) ?? ""
            let record = try service.addKey(providerID: providerID, label: label, secret: secret,
                                            priority: priority, tags: tags, note: note)
            secretCache[record.id] = secret.trimmingCharacters(in: .whitespacesAndNewlines)
            let provider = service.provider(id: providerID) ?? Provider(id: providerID, name: providerID, envKeys: [])
            return [
                "record": JSONMapping.record(record, secret: nil),
                "warnings": SecretValidator.warnings(secret: secret, provider: provider)
            ]

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
                itemKeyOverride: (params["itemKey"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            )
            let secret = (try? service.secret(for: keyID)) ?? ""
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
                itemKeyOverride: (params["itemKey"] as? String).flatMap { $0.isEmpty ? nil : $0 }
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
