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
            "createdAt": ISO8601DateFormatter().string(from: r.createdAt),
            "updatedAt": ISO8601DateFormatter().string(from: r.updatedAt),
            "lastCheck": check(r.lastCheck)
        ]
        if let secret { out["secret"] = secret }
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
