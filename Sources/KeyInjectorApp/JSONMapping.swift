// ==============================================================================
// 核心类型 → JSON 字典映射（供前端消费）
//
// 安全铁律：除非显式传入 secret，否则任何映射结果都不含密钥明文。
// ==============================================================================
import Foundation
import KeyInjectorCore

enum JSONMapping {

    static func any<T>(_ value: T) throws -> Any {
        switch value {
        case let dict as [String: Int]:
            return dict
        case let dict as [String: String]:
            return dict
        case let dict as [String: Any]:
            return dict
        case let array as [[String: Any]]:
            return array
        default:
            throw BridgeError.badRequest("异步返回值类型不可序列化：\(type(of: value))")
        }
    }

    static func provider(_ p: Provider) -> [String: Any] {
        var out: [String: Any] = [
            "id": p.id,
            "name": p.name,
            "envKeys": p.envKeys,
            "primaryEnvKey": p.primaryEnvKey,
            "secretPrefixes": p.secretPrefixes,
            "authStyle": p.authStyle.rawValue,
            "note": p.note
        ]
        out["baseURL"] = p.baseURL ?? ""
        out["healthPath"] = p.healthPath ?? ""
        out["consoleURL"] = p.consoleURL ?? ""
        out["hasHealthCheck"] = p.healthPath != nil
        return out
    }

    static func target(_ t: InjectionTarget) -> [String: Any] {
        [
            "id": t.id,
            "name": t.name,
            "providerID": t.providerID ?? "",
            "format": t.format.rawValue,
            "formatLabel": t.format.label,
            "filePath": t.filePath,
            "jsonPath": t.jsonPath.joined(separator: "."),
            "section": t.section ?? "",
            "itemKey": t.itemKey ?? "",
            "note": t.note,
            "isCustom": t.isCustom,
            "writesFile": t.format.writesFile,
            "requiresPath": TargetCatalog.requiresPath(t)
        ]
    }

    static func check(_ c: CheckSummary?) -> [String: Any] {
        guard let c else {
            return ["status": CheckStatus.unchecked.rawValue,
                    "label": CheckStatus.unchecked.label,
                    "message": "",
                    "checkedAt": "",
                    "latencyMS": 0,
                    "httpStatus": 0]
        }
        return [
            "status": c.status.rawValue,
            "label": c.status.label,
            "message": c.message,
            "checkedAt": ISO8601DateFormatter().string(from: c.checkedAt),
            "latencyMS": c.latencyMS ?? 0,
            "httpStatus": c.httpStatus ?? 0
        ]
    }

    /// 一条「密钥 → 模型」供给绑定的 JSON 形态（不含任何明文）
    static func binding(_ b: HostModelInventory.Binding) -> [String: Any] {
        [
            "modelID": b.modelID,
            "displayName": b.displayName,
            "host": b.host.rawValue,
            "hostLabel": b.host.label,
            "owner": b.owner,
            "inMenu": b.inMenu,
            "credentialKey": b.credentialKey,
            "endpoint": b.endpoint,
            "matchedBy": b.matchedBy
        ]
    }

    /// 跨宿主统一模型条目的 JSON 形态
    static func hostModel(_ m: HostModelRecord) -> [String: Any] {
        [
            "id": m.id,
            "normalizedID": m.normalizedID,
            "displayName": m.displayName,
            "host": m.host.rawValue,
            "hostLabel": m.hostLabel,
            "owner": m.owner,
            "credentialKey": m.credentialKey,
            "endpoint": m.endpoint,
            "note": m.note,
            "inMenu": m.inMenu,
            "isGateway": m.isGateway,
            "sourcePath": m.sourcePath
        ]
    }

    /// 按归一化身份聚合后的模型分组
    static func modelGroup(_ g: HostModelInventory.Group) -> [String: Any] {
        [
            "normalizedID": g.normalizedID,
            "displayName": g.displayName,
            "aliases": g.aliases,
            "hosts": g.hosts.map { ["id": $0.rawValue, "label": $0.label] },
            "isGateway": g.isGateway,
            "records": g.records.map(hostModel)
        ]
    }

    static func record(_ r: KeyRecord, secret: String?) -> [String: Any] {
        var out: [String: Any] = [
            "id": r.id,
            "providerID": r.providerID,
            "label": r.label,
            "hint": r.hint,
            "fingerprint": r.fingerprint,
            "enabled": r.enabled,
            "priority": r.priority,
            "tags": r.tags,
            "note": r.note,
            "baseURL": r.baseURL ?? "",
            "createdAt": ISO8601DateFormatter().string(from: r.createdAt),
            "updatedAt": ISO8601DateFormatter().string(from: r.updatedAt),
            "lastCheck": check(r.lastCheck),
            "modelBindings": r.modelBindings.map(binding)
        ]
        if let secret { out["secret"] = secret }
        return out
    }

    /// 一条「这把 Key 可提供」的模型（含取证来源与置信度）
    static func availableModel(_ m: AvailableModel) -> [String: Any] {
        var out: [String: Any] = [
            "modelID": m.modelID,
            "displayName": m.displayName,
            "source": m.source.rawValue,
            "sourceLabel": m.source.label,
            "confidence": m.source.confidence,
            "evidence": m.evidence,
            "owner": m.owner,
            "inMenu": m.inMenu,
            "credentialKey": m.credentialKey,
            "endpoint": m.endpoint
        ]
        out["host"] = m.host?.rawValue ?? ""
        out["hostLabel"] = m.host?.label ?? ""
        return out
    }

    /// 一次模型发现的完整结果（含降级原因，界面据此如实告知用户）
    static func discovery(_ d: ModelDiscoveryResult) -> [String: Any] {
        let models = d.normalizedModels
        var bySource: [String: Int] = [:]
        for m in models { bySource[m.source.rawValue, default: 0] += 1 }
        return [
            "probed": d.probed,
            "endpoint": d.endpoint,
            "note": d.note,
            "httpStatus": d.httpStatus,
            "fetchedAt": ISO8601DateFormatter().string(from: d.fetchedAt),
            "fingerprint": d.fingerprint,
            "sourceLabel": d.sourceLabel,
            "modelCount": d.modelCount,
            "sourceCounts": bySource,
            "models": models.map(availableModel)
        ]
    }

    static func keyGroup(_ g: KeyInjectorService.KeyGroup) -> [String: Any] {
        [
            "label": g.label,
            "modelCount": g.modelCount,
            "keys": g.records.map { record($0, secret: nil) }
        ]
    }

    static func injectedLocation(_ l: KeyInjectorService.InjectedLocation) -> [String: Any] {
        [
            "targetID": l.targetID,
            "targetName": l.targetName,
            "filePath": l.filePath,
            "itemKey": l.itemKey,
            "lastInjectedAt": ISO8601DateFormatter().string(from: l.lastInjectedAt)
        ]
    }

    /// 密钥详情：元数据 + 可用模型 + 宿主绑定 + 落点 + 审计摘要
    static func keyDetail(_ d: KeyInjectorService.KeyDetail) -> [String: Any] {
        var out: [String: Any] = [
            "record": record(d.record, secret: nil),
            "availableModels": d.availableModels.map(availableModel),
            "bindings": d.bindings.map(binding),
            "locations": d.locations.map(injectedLocation),
            "audit": d.auditEntries.map(audit),
            "probeable": d.probeable
        ]
        out["discovery"] = d.discovery.map(discovery) ?? NSNull()
        return out
    }

    static func audit(_ e: AuditEntry) -> [String: Any] {
        var out: [String: Any] = [
            "id": e.id,
            "timestamp": ISO8601DateFormatter().string(from: e.timestamp),
            "action": e.action.rawValue,
            "actionLabel": e.action.label,
            "result": e.result,
            "message": e.message
        ]
        out["targetID"] = e.targetID ?? ""
        out["filePath"] = e.filePath ?? ""
        out["keyID"] = e.keyID ?? ""
        out["providerID"] = e.providerID ?? ""
        out["fingerprint"] = e.fingerprint ?? ""
        out["backupPath"] = e.backupPath ?? ""
        out["canRollback"] = (e.action == .inject && e.result == "success" && e.backupPath != nil)
        return out
    }

    static func plan(_ p: InjectionPlan, reveal: Bool, secret: String) -> [String: Any] {
        let diff = reveal ? p.diff : p.redactedDiff(secret: secret)
        var out: [String: Any] = [
            "targetID": p.target.id,
            "targetName": p.target.name,
            "format": p.target.format.rawValue,
            "formatLabel": p.target.format.label,
            "providerID": p.provider.id,
            "providerName": p.provider.name,
            "keyLabel": p.keyRecord.label,
            "keyHint": p.keyRecord.hint,
            "keyFingerprint": p.keyRecord.fingerprint,
            "itemKey": p.itemKey,
            "existedBefore": p.existedBefore,
            "writesFile": p.target.format.writesFile,
            "blocked": p.blocked,
            "warnings": p.warnings,
            "suppliedModels": p.suppliedModels.map(binding),
            "diff": diff.map { ["kind": $0.kind.rawValue, "text": $0.text] },
            "snippet": reveal ? p.snippet : p.redactedSnippet(secret: secret)
        ]
        out["filePath"] = p.resolvedPath ?? ""
        out["blockedReason"] = p.blockedReason ?? ""
        return out
    }

    static func outcome(_ o: ApplyOutcome) -> [String: Any] {
        var out: [String: Any] = [
            "success": o.success,
            "message": o.message
        ]
        out["filePath"] = o.filePath ?? ""
        out["backupPath"] = o.backupPath ?? ""
        out["metaPath"] = o.metaPath ?? ""
        out["verifiedFingerprint"] = o.verifiedFingerprint ?? ""
        return out
    }

    static func rollback(_ o: RollbackOutcome) -> [String: Any] {
        var out: [String: Any] = ["success": o.success, "message": o.message]
        out["filePath"] = o.filePath ?? ""
        return out
    }
}
