// ==============================================================================
// 核心层自动化测试（swift-testing 框架）
//
// 说明：本机仅安装了 Command Line Tools（无完整 Xcode），工具链**不提供 XCTest**，
//      因此测试统一使用 swift-testing（`import Testing` / `@Test` / `#expect`）。
// 运行：swift test
// ==============================================================================
import Foundation
import Testing
@testable import KeyInjectorCore

// MARK: - 测试辅助

/// 每个用例独立的临时数据目录，确保用例之间零污染
final class TempDir {
    let url: URL
    init() {
        url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("keyinjector-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
    deinit { try? FileManager.default.removeItem(at: url) }

    func file(_ name: String, content: String? = nil) -> URL {
        let u = url.appendingPathComponent(name)
        if let c = content { try? c.write(to: u, atomically: true, encoding: .utf8) }
        return u
    }

    func makeService(transport: HTTPTransport = URLSessionTransport()) throws -> KeyInjectorService {
        try KeyInjectorService(root: url, storeBackend: "memory", transport: transport)
    }
}

func makeTarget(
    id: String = "t",
    format: InjectionFormat,
    path: String,
    jsonPath: [String] = [],
    section: String? = nil,
    itemKey: String? = nil,
    providerID: String? = nil
) -> InjectionTarget {
    InjectionTarget(id: id, name: "测试落点", providerID: providerID, format: format,
                    filePath: path, jsonPath: jsonPath, section: section, itemKey: itemKey)
}

/// 离线假传输层：让健康探测的用例完全不依赖网络
struct MockTransport: HTTPTransport {
    var status: Int = 200
    var body: Data = Data("{}".utf8)
    func send(_ request: URLRequest) async throws -> (status: Int, body: Data) {
        (status, body)
    }
}

// MARK: - 掩码与指纹

@Suite("掩码与指纹")
struct RedactionTests {
    @Test("掩码绝不泄露完整密钥")
    func maskNeverLeaksFullSecret() {
        let secret = "sk-abcdefghijklmnop1234"
        let masked = Redaction.mask(secret)
        #expect(!masked.contains(secret))
        #expect(masked.contains("…"))
        #expect(Redaction.mask("short") == "…")
    }

    @Test("指纹稳定且为 8 位")
    func fingerprintIsStableAndShort() {
        #expect(Fingerprint.short("sk-test-value") == Fingerprint.short("sk-test-value"))
        #expect(Fingerprint.short("sk-test-value") != Fingerprint.short("sk-test-value2"))
        #expect(Fingerprint.short("sk-test-value").count == 8)
    }

    @Test("格式预检能识别前缀不匹配")
    func validatorFlagsPrefixMismatch() {
        let provider = Provider(id: "openai", name: "OpenAI", envKeys: ["OPENAI_API_KEY"], secretPrefixes: ["sk-"])
        let warnings = SecretValidator.warnings(secret: "AIzaSyWrongPrefixValue123", provider: provider)
        #expect(warnings.contains { $0.contains("开头") })
        #expect(SecretValidator.warnings(secret: "sk-1234567890abcdef", provider: provider).isEmpty)

        let catalog = ProviderCatalog()
        let gemini = catalog.provider(id: "google")!
        #expect(SecretValidator.warnings(secret: "AIzaTESTONLYNOTAREALKEY", provider: gemini).isEmpty)
        #expect(SecretValidator.warnings(secret: "AIzaSyD-1234567890abcdef", provider: gemini).isEmpty)
    }
}

// MARK: - JSON 定点补丁

@Suite("JSON 定点补丁")
struct JSONPatcherTests {
    @Test("替换值时保留缩进与键序")
    func patchPreservesFormattingAndKeyOrder() throws {
        let original = """
        {
          "zebra": 1,
          "env": {
            "ANTHROPIC_API_KEY": "old-value",
            "OTHER": "keep-me"
          },
          "alpha": true
        }
        """
        let patched = try JSONPatcher.patch(content: original, path: ["env", "ANTHROPIC_API_KEY"], newValue: "sk-new-key")
        #expect(patched.contains("\"ANTHROPIC_API_KEY\": \"sk-new-key\""))
        #expect(patched.contains("\"OTHER\": \"keep-me\""))
        #expect(patched.contains("\n  \"env\": {"))
        let zebraIdx = try #require(patched.range(of: "\"zebra\"")).lowerBound
        let alphaIdx = try #require(patched.range(of: "\"alpha\"")).lowerBound
        #expect(zebraIdx < alphaIdx)
    }

    @Test("键路径不存在时拒绝写入而非猜测")
    func missingPathIsRefused() throws {
        let original = "{\n  \"env\": {}\n}\n"
        var caught: JSONPatchError?
        do {
            _ = try JSONPatcher.patch(content: original, path: ["env", "NOT_THERE"], newValue: "x")
            Issue.record("键路径不存在时必须抛错")
        } catch let error as JSONPatchError {
            caught = error
        }
        guard case .pathNotFound = try #require(caught) else {
            Issue.record("应抛出 pathNotFound，实际为 \(String(describing: caught))")
            return
        }
    }

    @Test("特殊字符转义后可原样读回")
    func escapingAndReadingBack() throws {
        let original = "{\n  \"key\": \"old\"\n}\n"
        let tricky = "line1\nline2\t\"quoted\"\\slash"
        let patched = try JSONPatcher.patch(content: original, path: ["key"], newValue: tricky)
        #expect(JSONPatcher.readString(content: patched, path: ["key"]) == tricky)
    }

    @Test("中文与符号值往返无损")
    func unicodeValueSurvivesRoundTrip() throws {
        let original = "{\n  \"note\": \"旧\"\n}\n"
        let patched = try JSONPatcher.patch(content: original, path: ["note"], newValue: "密钥-中文-✓")
        #expect(JSONPatcher.readString(content: patched, path: ["note"]) == "密钥-中文-✓")
    }

    @Test("非法 JSON 拒绝解析")
    func malformedJSONIsRejected() {
        #expect(throws: (any Error).self) {
            _ = try JSONPatcher.patch(content: "{ not json", path: ["a"], newValue: "b")
        }
    }
}

// MARK: - dotenv / shell 补丁

@Suite("dotenv 与 shell 补丁")
struct EnvPatcherTests {
    @Test("dotenv 命中替换、未命中追加")
    func dotenvReplaceAndAppend() throws {
        let original = "FOO=1\nDEEPSEEK_API_KEY=\"old\"\nBAR=2\n"
        let replaced = try ContentPatcher.patchDotenv(content: original, key: "DEEPSEEK_API_KEY", value: "sk-new")
        #expect(replaced.contains("DEEPSEEK_API_KEY=\"sk-new\""))
        #expect(replaced.contains("FOO=1"))
        #expect(replaced.contains("BAR=2"))
        #expect(!replaced.contains("old"))

        let appended = try ContentPatcher.patchDotenv(content: original, key: "NEW_KEY", value: "v")
        #expect(appended.hasSuffix("NEW_KEY=\"v\"\n"))
    }

    @Test("shell 使用受管区块且重复注入幂等")
    func shellExportManagedBlockIsIdempotent() throws {
        let original = "export PATH=/usr/bin:$PATH\nalias ll='ls -l'\n"
        let once = try ContentPatcher.patchShellExport(content: original, key: "OPENAI_API_KEY", value: "sk-1")
        #expect(once.contains(ContentPatcher.blockStart))
        #expect(once.contains(ContentPatcher.blockEnd))
        #expect(once.contains("export PATH=/usr/bin:$PATH"))
        #expect(once.contains("alias ll='ls -l'"))

        let twice = try ContentPatcher.patchShellExport(content: once, key: "OPENAI_API_KEY", value: "sk-2")
        #expect(twice.components(separatedBy: ContentPatcher.blockStart).count - 1 == 1)
        #expect(twice.contains("export OPENAI_API_KEY=\"sk-2\""))
        #expect(!twice.contains("sk-1"))

        let three = try ContentPatcher.patchShellExport(content: twice, key: "ANTHROPIC_API_KEY", value: "sk-ant")
        #expect(three.contains("export OPENAI_API_KEY=\"sk-2\""))
        #expect(three.contains("export ANTHROPIC_API_KEY=\"sk-ant\""))
        #expect(three.components(separatedBy: ContentPatcher.blockStart).count - 1 == 1)
    }

    @Test("受管区块标记不成对时拒绝写入")
    func shellRejectsBrokenBlockMarkers() {
        let broken = "\(ContentPatcher.blockStart)\nexport A=\"1\"\n"
        #expect(throws: (any Error).self) {
            _ = try ContentPatcher.patchShellExport(content: broken, key: "A", value: "2")
        }
    }

    @Test("shell 引号转义覆盖危险字符")
    func shellQuoteEscapesDangerousChars() {
        #expect(ContentPatcher.shellQuote("a\"b$c`d\\e") == "\"a\\\"b\\$c\\`d\\\\e\"")
    }
}

// MARK: - YAML / TOML 补丁

@Suite("YAML 与 TOML 补丁")
struct StructuredPatcherTests {
    @Test("YAML 区块内替换、插入与新区块")
    func yamlSectionReplaceAndInsert() throws {
        let original = """
        # 顶部注释
        model: gpt-4
        openai:
          api-key: old
          timeout: 30
        other: 1
        """
        let replaced = try ContentPatcher.patchYAML(content: original, section: "openai", key: "api-key", value: "sk-new")
        #expect(replaced.contains("  api-key: \"sk-new\""))
        #expect(replaced.contains("  timeout: 30"))
        #expect(replaced.contains("# 顶部注释"))
        #expect(replaced.contains("other: 1"))

        let inserted = try ContentPatcher.patchYAML(content: original, section: "openai", key: "organization", value: "org-1")
        #expect(inserted.contains("  organization: \"org-1\""))
        let orgIdx = try #require(inserted.range(of: "organization")).lowerBound
        let otherIdx = try #require(inserted.range(of: "other: 1")).lowerBound
        #expect(orgIdx < otherIdx)

        let newSection = try ContentPatcher.patchYAML(content: original, section: "gemini", key: "api-key", value: "AIza")
        #expect(newSection.contains("gemini:"))
        #expect(newSection.contains("  api-key: \"AIza\""))
    }

    @Test("TOML 区块内替换与新区块")
    func tomlSectionReplaceAndInsert() throws {
        let original = """
        [default]
        model = "gpt-4"

        [openai]
        api_key = "old"
        timeout = 30
        """
        let replaced = try ContentPatcher.patchTOML(content: original, section: "openai", key: "api_key", value: "sk-new")
        #expect(replaced.contains("api_key = \"sk-new\""))
        #expect(replaced.contains("timeout = 30"))
        #expect(replaced.contains("model = \"gpt-4\""))

        let inserted = try ContentPatcher.patchTOML(content: original, section: "deepseek", key: "api_key", value: "sk-ds")
        #expect(inserted.contains("[deepseek]"))
        #expect(inserted.contains("api_key = \"sk-ds\""))
    }
}

// MARK: - 行差异与脱敏

@Suite("行差异与脱敏")
struct LineDiffTests {
    @Test("单行变更产出一增一删")
    func singleLineChange() {
        let diff = LineDiff.compute(old: "a\nb\nc\n", new: "a\nB\nc\n")
        #expect(diff.filter { $0.kind == .removed }.count == 1)
        #expect(diff.filter { $0.kind == .added }.count == 1)
        #expect(diff.filter { $0.kind == .context }.count == 2)
    }

    @Test("脱敏后的差异不含明文，原始差异含明文")
    func diffRedactionRemovesSecret() throws {
        let tmp = TempDir()
        let service = try tmp.makeService()
        let envFile = tmp.file("redact.env", content: "OPENAI_API_KEY=\"sk-old-value\"\n")
        let secret = "sk-super-secret-value-123456"
        let record = try service.addKey(providerID: "openai", label: "脱敏", secret: secret)
        let provider = try #require(service.provider(id: "openai"))
        let target = makeTarget(format: .dotenv, path: envFile.path)

        let plan = try service.engine.plan(target: target, provider: provider, keyRecord: record, secret: secret)
        #expect(!plan.blocked)
        #expect(plan.diff.contains { $0.text.contains(secret) })
        let masked = plan.redactedDiff(secret: secret)
        #expect(!masked.contains { $0.text.contains(secret) })
        #expect(masked.contains { $0.text.contains("…") })
        #expect(!plan.redactedSnippet(secret: secret).contains(secret))
    }
}

// MARK: - 原子写入

@Suite("原子写入")
struct AtomicWriterTests {
    @Test("创建与替换且不留临时文件")
    func createAndReplace() throws {
        let tmp = TempDir()
        let url = tmp.file("a.txt", content: "old")
        try AtomicWriter.write("new-content", to: url)
        #expect(try String(contentsOf: url, encoding: .utf8) == "new-content")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: tmp.url.path)
            .filter { $0.hasPrefix(".keyinjector-") }
        #expect(leftovers.isEmpty)
    }

    @Test("替换后保留原文件权限位")
    func permissionsPreserved() throws {
        let tmp = TempDir()
        let url = tmp.file("secret.json", content: "{}")
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        try AtomicWriter.write("{\"a\":1}", to: url, preservePermissionsFrom: url)
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        #expect((attrs[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }

    @Test("自动创建缺失的父目录")
    func createsMissingParentDirectory() throws {
        let tmp = TempDir()
        let nested = tmp.url.appendingPathComponent("deep/dir/file.txt")
        try AtomicWriter.write("x", to: nested)
        #expect(FileManager.default.fileExists(atPath: nested.path))
    }
}

// MARK: - 密钥仓库事务

@Suite("密钥仓库事务")
struct KeyVaultTests {
    @Test("新增、列举、删除，且索引内无明文")
    func addListAndRemove() throws {
        let tmp = TempDir()
        let service = try tmp.makeService()
        let secret = "sk-abcdefghijklmnop"
        let record = try service.addKey(providerID: "openai", label: "主力", secret: secret)
        #expect(try service.listKeys().count == 1)
        #expect(try service.secret(for: record.id) == secret)
        let indexRaw = try String(contentsOf: tmp.url.appendingPathComponent("vault.json"), encoding: .utf8)
        #expect(!indexRaw.contains(secret))

        _ = try service.removeKey(id: record.id)
        #expect(try service.listKeys().count == 0)
        #expect(throws: (any Error).self) { _ = try service.secret(for: record.id) }
    }

    @Test("更新明文后索引保持一致")
    func updateSecretKeepsIndexConsistent() throws {
        let tmp = TempDir()
        let service = try tmp.makeService()
        let record = try service.addKey(providerID: "deepseek", label: "备用", secret: "sk-old-value-12345")
        let updated = try service.updateSecret(id: record.id, secret: "sk-new-value-67890")
        #expect(updated.fingerprint != record.fingerprint)
        #expect(try service.secret(for: record.id) == "sk-new-value-67890")
        #expect(updated.hint == Redaction.mask("sk-new-value-67890"))
    }

    @Test("可视化编辑密钥名称与明文")
    func updateKeyEditsLabelAndSecret() throws {
        let tmp = TempDir()
        let service = try tmp.makeService()
        let record = try service.addKey(providerID: "deepseek", label: "旧名称", secret: "sk-initial-12345", priority: 100, tags: ["旧标签"], note: "旧备注")
        
        // 仅修改名称与标签，不修改明文
        let metaUpdated = try service.updateKey(id: record.id, label: "新名称", secret: nil, priority: 50, tags: ["新标签"], note: "新备注")
        #expect(metaUpdated.label == "新名称")
        #expect(metaUpdated.priority == 50)
        #expect(metaUpdated.tags == ["新标签"])
        #expect(metaUpdated.note == "新备注")
        #expect(try service.secret(for: record.id) == "sk-initial-12345")
        
        // 同时修改明文
        let fullUpdated = try service.updateKey(id: record.id, label: "最终名称", secret: "sk-changed-99999")
        #expect(fullUpdated.label == "最终名称")
        #expect(try service.secret(for: record.id) == "sk-changed-99999")
        #expect(fullUpdated.fingerprint != record.fingerprint)
    }

    @Test("动态扩展自定义注入落点")
    func dynamicCustomTargetManagement() throws {
        let tmp = TempDir()
        let service = try tmp.makeService()
        let target = InjectionTarget(
            id: "my-custom-app",
            name: "我的自定义工具",
            providerID: "deepseek",
            format: .json,
            filePath: tmp.url.appendingPathComponent("custom.json").path,
            jsonPath: ["auth", "token"],
            isCustom: true,
            note: "测试扩展落点"
        )
        try service.addCustomTarget(target)
        #expect(service.target(id: "my-custom-app") != nil)
        #expect(service.target(id: "my-custom-app")?.name == "我的自定义工具")

        try service.removeCustomTarget(id: "my-custom-app")
        #expect(service.target(id: "my-custom-app") == nil)
    }

    @Test("优选密钥遵循启用状态与优先级")
    func preferredKeyHonoursEnabledAndPriority() throws {
        let tmp = TempDir()
        let service = try tmp.makeService()
        let low = try service.addKey(providerID: "openai", label: "低优先", secret: "sk-lowlolololololo", priority: 200)
        _ = try service.addKey(providerID: "openai", label: "高优先", secret: "sk-highhighhighhigh", priority: 10)
        let preferred = try #require(try service.preferredKey(providerID: "openai"))
        #expect(preferred.label == "高优先")

        _ = try service.setEnabled(id: preferred.id, enabled: false)
        #expect(try service.preferredKey(providerID: "openai")?.id == low.id)
    }

    @Test("未知厂商被拒绝")
    func unknownProviderIsRejected() throws {
        let tmp = TempDir()
        let service = try tmp.makeService()
        #expect(throws: (any Error).self) {
            _ = try service.addKey(providerID: "not-exist", label: "x", secret: "y")
        }
    }

    @Test("审计日志有记录但绝不含明文")
    func auditLogNeverStoresPlaintext() throws {
        let tmp = TempDir()
        let service = try tmp.makeService()
        let secret = "sk-audit-plaintext-check-9999"
        _ = try service.addKey(providerID: "openai", label: "审计", secret: secret)
        #expect(!service.recentAudit(10).isEmpty)
        let raw = try String(contentsOf: URL(fileURLWithPath: service.audit.path), encoding: .utf8)
        #expect(!raw.contains(secret))
    }
}

// MARK: - 注入引擎端到端（真实文件 + 备份 + 回滚）

@Suite("注入引擎端到端")
struct InjectionEngineTests {
    @Test("既有文件：计划 → 写入 → 回滚还原")
    func planApplyAndRollbackOnExistingFile() throws {
        let tmp = TempDir()
        let service = try tmp.makeService()
        let original = "{\n  \"env\": {\n    \"ANTHROPIC_API_KEY\": \"sk-original\"\n  }\n}\n"
        let targetFile = tmp.file("settings.json", content: original)
        let secret = "sk-ant-newkey-1234567890"
        let record = try service.addKey(providerID: "anthropic", label: "Claude", secret: secret)

        let target = InjectionTarget(id: "claude-code", name: "Claude Code", providerID: "anthropic",
                                     format: .json, filePath: targetFile.path,
                                     jsonPath: ["env", "ANTHROPIC_API_KEY"])
        let provider = try #require(service.provider(id: "anthropic"))
        let plan = try service.engine.plan(target: target, provider: provider, keyRecord: record, secret: secret)
        #expect(!plan.blocked)
        #expect(plan.originalContent?.contains("sk-original") == true)

        let outcome = try service.applyInjection(plan)
        #expect(outcome.success, "\(outcome.message)")
        #expect(outcome.backupPath != nil)
        #expect(outcome.verifiedFingerprint != nil)
        #expect(try String(contentsOf: targetFile, encoding: .utf8).contains(secret))

        let entry = try #require(service.audit.all().last { $0.action == .inject && $0.result == "success" })
        let back = try service.rollback(entry: entry)
        #expect(back.success, "\(back.message)")
        #expect(try String(contentsOf: targetFile, encoding: .utf8) == original)
    }

    @Test("新建文件的回滚即删除该文件")
    func rollbackOfNewlyCreatedFileDeletesIt() throws {
        let tmp = TempDir()
        let service = try tmp.makeService()
        let targetFile = tmp.url.appendingPathComponent("brand-new.env")
        let secret = "sk-new-file-value-123"
        let record = try service.addKey(providerID: "deepseek", label: "新文件", secret: secret)
        let provider = try #require(service.provider(id: "deepseek"))
        let target = makeTarget(id: "dotenv-project", format: .dotenv, path: targetFile.path)

        let plan = try service.engine.plan(target: target, provider: provider, keyRecord: record, secret: secret)
        #expect(!plan.blocked)
        #expect(!plan.existedBefore)
        let outcome = try service.applyInjection(plan)
        #expect(outcome.success)
        #expect(FileManager.default.fileExists(atPath: targetFile.path))

        let entry = try #require(service.audit.all().last { $0.action == .inject })
        let back = try service.rollback(entry: entry)
        #expect(back.success, "\(back.message)")
        #expect(!FileManager.default.fileExists(atPath: targetFile.path))
    }

    @Test("键路径缺失时必须阻断且不改动文件")
    func blockedWhenJSONPathMissing() throws {
        let tmp = TempDir()
        let service = try tmp.makeService()
        let original = "{\n  \"other\": 1\n}\n"
        let targetFile = tmp.file("flat.json", content: original)
        let secret = "sk-blocked-value-1234"
        let record = try service.addKey(providerID: "openai", label: "阻断", secret: secret)
        let provider = try #require(service.provider(id: "openai"))
        let target = makeTarget(format: .json, path: targetFile.path, jsonPath: ["env", "OPENAI_API_KEY"])

        let plan = try service.engine.plan(target: target, provider: provider, keyRecord: record, secret: secret)
        #expect(plan.blocked)
        let outcome = try service.applyInjection(plan)
        #expect(!outcome.success)
        #expect(try String(contentsOf: targetFile, encoding: .utf8) == original)
    }

    @Test("仅片段落点绝不触碰磁盘")
    func envOnlyTargetNeverTouchesDisk() throws {
        let tmp = TempDir()
        let service = try tmp.makeService()
        let secret = "sk-snippet-value-123456"
        let record = try service.addKey(providerID: "openai", label: "片段", secret: secret)
        let provider = try #require(service.provider(id: "openai"))
        let target = InjectionTarget(id: "env-only", name: "仅片段", format: .none)

        let plan = try service.engine.plan(target: target, provider: provider, keyRecord: record, secret: secret)
        #expect(!plan.blocked)
        #expect(plan.resolvedPath == nil)
        #expect(plan.snippet.contains("export OPENAI_API_KEY="))
        let outcome = try service.applyInjection(plan)
        #expect(outcome.success)
        #expect(outcome.filePath == nil)
    }

    @Test("shell 启动脚本注入幂等且可轮换密钥")
    func shellProfileInjectionOnTemporaryZshrc() throws {
        let tmp = TempDir()
        let service = try tmp.makeService()
        let zshrc = tmp.file("zshrc", content: "export LANG=zh_CN.UTF-8\n")
        let first = "sk-dsh-value-1234567890"
        let record = try service.addKey(providerID: "deepseek", label: "DSH", secret: first)
        let provider = try #require(service.provider(id: "deepseek"))
        let target = InjectionTarget(id: "shell-profile", name: "Shell", format: .shellExport, filePath: zshrc.path)

        let plan = try service.engine.plan(target: target, provider: provider, keyRecord: record, secret: first)
        #expect(!plan.blocked)
        let outcome = try service.applyInjection(plan)
        #expect(outcome.success, "\(outcome.message)")

        let content = try String(contentsOf: zshrc, encoding: .utf8)
        #expect(content.contains("export LANG=zh_CN.UTF-8"))
        #expect(content.contains("export DEEPSEEK_API_KEY=\"\(first)\""))
        #expect(content.contains(ContentPatcher.blockStart))

        let rotated = "sk-dsh-value-ROTATED-9999"
        let plan2 = try service.engine.plan(target: target, provider: provider, keyRecord: record, secret: rotated)
        _ = try service.applyInjection(plan2)
        let content2 = try String(contentsOf: zshrc, encoding: .utf8)
        #expect(content2.components(separatedBy: ContentPatcher.blockStart).count - 1 == 1)
        #expect(content2.contains("ROTATED"))
        #expect(!content2.contains(first))
    }

    @Test("目标为不可写目录时阻断")
    func blockedWhenTargetIsDirectory() throws {
        let tmp = TempDir()
        let service = try tmp.makeService()
        let secret = "sk-dir-target-value-1"
        let record = try service.addKey(providerID: "openai", label: "目录", secret: secret)
        let provider = try #require(service.provider(id: "openai"))
        let target = makeTarget(format: .dotenv, path: tmp.url.path)

        let plan = try service.engine.plan(target: target, provider: provider, keyRecord: record, secret: secret)
        #expect(plan.blocked)
    }

    @Test("同秒内连续备份不互相覆盖（回归：备份文件重名）")
    func repeatedBackupsDoNotCollide() throws {
        let tmp = TempDir()
        let service = try tmp.makeService()
        let targetFile = tmp.file("collide.env", content: "A=1\n")
        let secret = "sk-collide-value-12345"
        let record = try service.addKey(providerID: "openai", label: "连击", secret: secret)
        let provider = try #require(service.provider(id: "openai"))
        let target = makeTarget(format: .dotenv, path: targetFile.path)

        var backupPaths: [String] = []
        for round in 0..<3 {
            let plan = try service.engine.plan(target: target, provider: provider, keyRecord: record,
                                               secret: "sk-collide-value-\(round)0000")
            let outcome = try service.applyInjection(plan)
            #expect(outcome.success, "第 \(round + 1) 轮注入失败：\(outcome.message)")
            if let b = outcome.backupPath { backupPaths.append(b) }
        }
        #expect(backupPaths.count == 3)
        #expect(Set(backupPaths).count == 3, "同秒内多次备份产生了重名路径：\(backupPaths)")
        for p in backupPaths { #expect(FileManager.default.fileExists(atPath: p)) }
    }
}

// MARK: - 健康探测（离线可验证）

@Suite("健康探测")
struct HealthCheckerTests {
    @Test("状态码分类正确")
    func classification() {
        #expect(HealthChecker.classify(status: 200, body: Data("{}".utf8)).status == .valid)
        #expect(HealthChecker.classify(status: 401, body: Data()).status == .invalid)
        #expect(HealthChecker.classify(status: 403, body: Data()).status == .invalid)
        #expect(HealthChecker.classify(status: 429, body: Data()).status == .quota)
        #expect(HealthChecker.classify(status: 402, body: Data()).status == .quota)
        #expect(HealthChecker.classify(status: 404, body: Data()).status == .unknown)
        #expect(HealthChecker.classify(status: 500, body: Data()).status == .unknown)
    }

    @Test("各厂商鉴权头风格正确")
    func authHeaderStyles() throws {
        let checker = HealthChecker(transport: MockTransport())
        let catalog = ProviderCatalog()

        let openai = try #require(catalog.provider(id: "openai"))
        let req = try #require(checker.makeRequest(provider: openai, secret: "sk-x"))
        #expect(req.value(forHTTPHeaderField: "Authorization") == "Bearer sk-x")

        let anthropic = try #require(catalog.provider(id: "anthropic"))
        let req2 = try #require(checker.makeRequest(provider: anthropic, secret: "sk-ant-x"))
        #expect(req2.value(forHTTPHeaderField: "x-api-key") == "sk-ant-x")
        #expect(req2.value(forHTTPHeaderField: "anthropic-version") != nil)
        #expect(req2.value(forHTTPHeaderField: "Authorization") == nil)

        let gemini = try #require(catalog.provider(id: "google"))
        let req3 = try #require(checker.makeRequest(provider: gemini, secret: "AIza-x"))
        #expect(req3.url?.absoluteString.contains("key=AIza-x") == true)
        #expect(req3.value(forHTTPHeaderField: "Authorization") == nil)

        // Gemini 中间商 / AQ. 凭证支持自定义 BaseURL 并带 Bearer
        let req4 = try #require(checker.makeRequest(provider: gemini, secret: "AIzaTESTONLYNOTAREALKEY", overrideBaseURL: "https://my-gemini-proxy.com/v1"))
        #expect(req4.url?.host == "my-gemini-proxy.com")
        #expect(req4.value(forHTTPHeaderField: "Authorization") == "Bearer AIzaTESTONLYNOTAREALKEY")
    }

    @Test("探测经传输层返回并带耗时")
    func checkUsesTransportAndReportsLatency() async throws {
        let checker = HealthChecker(transport: MockTransport(status: 401))
        let provider = try #require(ProviderCatalog().provider(id: "openai"))
        let summary = await checker.check(provider: provider, secret: "sk-bad")
        #expect(summary.status == .invalid)
        #expect(summary.httpStatus == 401)
        #expect(summary.latencyMS != nil)
    }

    @Test("未配置探测端点时如实说明")
    func unreachableWhenEndpointMissing() async {
        let checker = HealthChecker(transport: MockTransport())
        let custom = Provider(id: "custom", name: "自定义", envKeys: ["CUSTOM_API_KEY"])
        let summary = await checker.check(provider: custom, secret: "x")
        #expect(summary.status == .unknown)
        #expect(summary.message.contains("未配置探测端点"))
    }
}

// MARK: - 目录与配置一致性

@Suite("目录与配置一致性")
struct CatalogTests {
    @Test("内置目录完整性（含反例说明强制项）")
    func builtinCatalogIntegrity() {
        let catalog = ProviderCatalog()
        #expect(catalog.providers.count >= 8)
        for p in catalog.providers {
            #expect(!p.id.isEmpty)
            #expect(!p.envKeys.isEmpty)
            #expect(!p.note.isEmpty)
            if let hp = p.healthPath {
                #expect(hp.hasPrefix("/"))
                #expect(p.baseURL != nil)
            }
        }

        let targets = TargetCatalog()
        #expect(targets.targets.count >= 2)
        for t in targets.targets {
            #expect(!t.note.isEmpty)
            // 非自定义的 JSON / plist 落点必须自带键路径；自定义落点的键路径由用户填写
            if (t.format == .json || t.format == .plist) && !t.isCustom {
                #expect(!t.jsonPath.isEmpty)
                #expect(!t.filePath.isEmpty)
            }
        }
    }

    @Test("配置模板导出且不覆盖既有文件")
    func configTemplateExportAndOverride() throws {
        let tmp = TempDir()
        let service = try tmp.makeService()
        let written = try service.exportConfigTemplates()
        #expect(written.count == 2)
        for p in written { #expect(FileManager.default.fileExists(atPath: p)) }
        #expect(try service.exportConfigTemplates().isEmpty)
    }

    @Test("路径展开正确处理 ~ 与 $HOME")
    func pathExpansion() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        #expect(PathKit.expand("~/x/y") == home + "/x/y")
        #expect(PathKit.expand("$HOME/.zshrc") == home + "/.zshrc")
        #expect(PathKit.expand("/tmp/./a/../b") == "/tmp/b")
    }
}

// MARK: - Codex 网关 provider 路由守护
// 回归背景：桌面端把模型切成公司网关模型后，config.toml 只剩 `model` 却没有 `model_provider`，
// 请求退回 openai provider，被 ChatGPT 后端拒绝为
// “The '<model>' model is not supported when using Codex with a ChatGPT account.”

@Suite("Codex 网关 provider 路由守护")
struct CodexGatewayRoutingTests {

    @Test("官方模型不做任何改动")
    func officialModelUntouched() {
        let text = """
        model = "gpt-5.6-luna"
        model_provider = "openai"

        [features]
        foo = true
        """
        let out = InjectionEngine.ensureCodexGatewayProviderRouting(text, catalogPath: "/nonexistent.json")
        #expect(out == text)
    }

    @Test("网关模型缺少 provider 时补写受管区块")
    func gatewayModelGainsProvider() {
        let text = """
        model_catalog_json = "/tmp/catalog.json"
        model = "ark/DeepSeek-V4.1-Flash"

        [marketplaces.openai-bundled]
        source_type = "local"
        """
        let out = InjectionEngine.ensureCodexGatewayProviderRouting(text, catalogPath: "/nonexistent.json")
        #expect(out.contains(InjectionEngine.codexDesktopBlockStart))
        #expect(out.contains("model_provider = \"codex_gateway\""))
        #expect(out.contains("model = \"ark/DeepSeek-V4.1-Flash\""))
        // 受管区块必须落在第一个 [section] 之前，否则会被当成别的表内的键
        let blockIndex = out.range(of: InjectionEngine.codexDesktopBlockStart)!.lowerBound
        let sectionIndex = out.range(of: "[marketplaces.openai-bundled]")!.lowerBound
        #expect(blockIndex < sectionIndex)
        // 顶层 `model` 不重复
        let topLevelModels = out.split(separator: "\n").prefix(while: { !$0.hasPrefix("[") })
            .filter { $0.hasPrefix("model = ") }
        #expect(topLevelModels.count == 1)
    }

    @Test("已有受管区块时保持幂等")
    func idempotentWhenBlockExists() {
        let text = """
        model_provider = "codex_gateway"
        # BEGIN CODEX-GATEWAY DESKTOP
        model = "gemini-3.8-flash-high"
        model_provider = "codex_gateway"
        # END CODEX-GATEWAY DESKTOP

        [features]
        foo = true
        """
        let out = InjectionEngine.ensureCodexGatewayProviderRouting(text, catalogPath: "/nonexistent.json")
        #expect(out == text)
    }

    @Test("受管区块被改回官方 provider 时自动收敛")
    func repairsTamperedBlock() {
        let text = """
        # BEGIN CODEX-GATEWAY DESKTOP
        model = "gemini-3.8-flash-high"
        model_provider = "openai"
        # END CODEX-GATEWAY DESKTOP

        [marketplaces.openai-bundled]
        source_type = "local"
        """
        let out = InjectionEngine.ensureCodexGatewayProviderRouting(text, catalogPath: "/nonexistent.json")
        #expect(out.contains("model_provider = \"codex_gateway\""))
        #expect(!out.contains("model_provider = \"openai\""))
        #expect(out.components(separatedBy: InjectionEngine.codexDesktopBlockStart).count == 2)
    }

    @Test("用户显式选择的其它第三方 provider 不被覆盖")
    func respectsThirdPartyProvider() {
        let text = """
        model = "gemini-3.8-flash-high"
        model_provider = "my_own_gateway"
        """
        let out = InjectionEngine.ensureCodexGatewayProviderRouting(text, catalogPath: "/nonexistent.json")
        #expect(out == text)
    }

    @Test("孤儿 BEGIN 标记（Codex 重写吞掉 END 注释）也能被清理干净")
    func cleansOrphanBeginMarker() {
        let text = """
        model_reasoning_effort = "xhigh"
        # BEGIN CODEX-GATEWAY DESKTOP
        # 桌面端换模型时必须同时锁定 provider
        model = "ark/DeepSeek-V4.1-Flash"

        [marketplaces.openai-bundled]
        source_type = "local"
        """
        let out = InjectionEngine.ensureCodexGatewayProviderRouting(text, catalogPath: "/nonexistent.json")
        #expect(out.components(separatedBy: InjectionEngine.codexDesktopBlockStart).count == 2)
        #expect(out.components(separatedBy: InjectionEngine.codexDesktopBlockEnd).count == 2)
        #expect(out.contains("model_reasoning_effort = \"xhigh\""))
        #expect(out.contains("[marketplaces.openai-bundled]"))
        // 顶层 model 只出现一次
        let models = out.split(separator: "\n").prefix(while: { !$0.hasPrefix("[") }).filter { $0.hasPrefix("model = ") || $0.hasPrefix("model =") }
        #expect(models.count == 1)
    }

    @Test("结构完整的受管区块保持原样（幂等），孤儿标记才清理")
    func keepsCompleteBlockIntact() {
        let text = """
        model_reasoning_effort = "xhigh"
        # BEGIN CODEX-GATEWAY DESKTOP
        # 说明注释
        model = "ark/DeepSeek-V4.1-Flash"
        model_provider = "codex_gateway"
        # END CODEX-GATEWAY DESKTOP

        [marketplaces.openai-bundled]
        source_type = "local"
        """
        let out = InjectionEngine.ensureCodexGatewayProviderRouting(text, catalogPath: "/nonexistent.json")
        // 一个 BEGIN + 一个 END → 结构完整，原样返回（幂等）
        #expect(out == text)
        #expect(out.components(separatedBy: InjectionEngine.codexDesktopBlockStart).count == 2)
        // 再次调用仍不变
        #expect(InjectionEngine.ensureCodexGatewayProviderRouting(out, catalogPath: "/nonexistent.json") == text)
    }

    @Test("模型目录：新增/切换/删除网关条目，官方条目不可删")
    func catalogMutations() throws {
        let tmp = TempDir()
        let catalog = tmp.file("catalog.json", content: """
        {"models": [
          {"slug": "gpt-6-astra", "display_name": "GPT-6-Astra", "visibility": "list"},
          {"slug": "gemini-3.8-flash-high", "display_name": "Gemini 3.8 Flash（公司网关）", "visibility": "list"}
        ]}
        """)
        let path = catalog.path

        // 原始条目识别
        let before = CodexCatalogStore.load(path: path)
        #expect(before.count == 2)
        #expect(before.filter { $0.isGateway }.count == 1)
        #expect(before.first(where: { $0.slug == "gpt-6-astra" })?.sourceLabel == "Codex 官方")

        // 新增网关条目（模板取现有条目，字段零丢失）
        let added = try CodexCatalogStore.addGatewayModel(slug: "ark/DeepSeek-V4.1-Flash",
                                                         displayName: "DeepSeek V4.1（公司网关）",
                                                         path: path)
        #expect(added)
        #expect(try !CodexCatalogStore.addGatewayModel(slug: "ark/DeepSeek-V4.1-Flash", displayName: "重复", path: path))
        let afterAdd = CodexCatalogStore.load(path: path)
        #expect(afterAdd.count == 3)
        #expect(afterAdd.first(where: { $0.slug == "ark/DeepSeek-V4.1-Flash" })?.inPicker == true)

        // 菜单可见性切换
        #expect(try CodexCatalogStore.setInPicker(slug: "ark/DeepSeek-V4.1-Flash", inPicker: false, path: path))
        #expect(CodexCatalogStore.load(path: path).first(where: { $0.slug == "ark/DeepSeek-V4.1-Flash" })?.inPicker == false)

        // 官方条目不可删
        #expect(try !CodexCatalogStore.removeGatewayModel(slug: "gpt-6-astra", path: path))
        #expect(CodexCatalogStore.load(path: path).count == 3)

        // 网关条目可删
        #expect(try CodexCatalogStore.removeGatewayModel(slug: "ark/DeepSeek-V4.1-Flash", path: path))
        #expect(CodexCatalogStore.load(path: path).count == 2)
    }

    @Test("目录内的网关标记条目同样被识别")
    func catalogMarkerDetection() throws {
        let tmp = TempDir()
        let catalog = tmp.file("catalog.json", content: """
        {"models": [
          {"slug": "gpt-6-astra", "display_name": "GPT-6-Astra"},
          {"slug": "ark/kimi-k3", "display_name": "Kimi K3（公司网关）"}
        ]}
        """)
        #expect(GatewayCatalog.isGatewayModel("ark/kimi-k3", catalogPath: catalog.path))
        #expect(!GatewayCatalog.isGatewayModel("gpt-6-astra", catalogPath: catalog.path))
        #expect(GatewayCatalog.isGatewayModel("ark/DeepSeek-V4.1-Flash", catalogPath: catalog.path))
    }
}

// MARK: - 跨宿主模型清单与密钥供给绑定

@Suite("跨宿主模型清单")
struct HostModelCatalogTests {

    /// 一份贴近真实环境的 DSH 设置片段：两个供应商、不同缩进层级与列表项
    static let dshSample = """
    ui-onboarding:
      welcomeNoticeVersion: 2026-08-13.1
    llm-pi-ai:
      providers:
        midpro:
          displayName: Aki
          apiKeyEnv: MIDPRO_API_KEY
          api: openai-completions
          baseURL: http://192.168.1.200:8080/v1
          models:
            - id: DS/DeepSeek V4.1 Flash
              input:
                - text
                - image
            - id: gemini-3.8-flash-high
              input:
                - text
            - id: gpt-image-2.5
        legacy:
          displayName: Legacy
          apiKeyEnv: LEGACY_API_KEY
          baseURL: https://legacy.example.com/v1
          enabled: false
          models:
            - id: legacy-model
    agent-default-model:
      provider: midpro
      model: DS/DeepSeek V4.1 Flash
    permission:
      defaultPreset: danger-full-access
    """

    @Test("解析宿主供应商：凭据引用、端点与模型 id 列表")
    func parseDshProviders() throws {
        let providers = DshModelCatalog.parseProviders(Self.dshSample)
        #expect(providers.count == 2)

        let midpro = try #require(providers.first(where: { $0.id == "midpro" }))
        #expect(midpro.displayName == "Aki")
        #expect(midpro.apiKeyEnv == "MIDPRO_API_KEY")
        #expect(midpro.baseURL == "http://192.168.1.200:8080/v1")
        #expect(midpro.modelIDs == ["DS/DeepSeek V4.1 Flash", "gemini-3.8-flash-high", "gpt-image-2.5"])
        #expect(midpro.enabled)

        let legacy = try #require(providers.first(where: { $0.id == "legacy" }))
        #expect(legacy.enabled == false)
        #expect(legacy.modelIDs == ["legacy-model"])
        // 顶层其它设置（agent-default-model / permission）绝不能被误读成供应商
        #expect(!providers.contains { $0.id == "permission" })
    }

    @Test("供应商区之外的模型 id 不被误收")
    func doesNotLeakTopLevelKeys() {
        let providers = DshModelCatalog.parseProviders(Self.dshSample)
        #expect(!providers.contains { $0.modelIDs.contains("midpro") })
        #expect(providers.flatMap { $0.modelIDs }.count == 4)
    }

    @Test("凭据文件只读键名与占用状态，绝不回传明文")
    func credentialStatusParsing() {
        let status = DshModelCatalog.parseCredentialRefs("""
        version: 1
        refs:
          MIDPRO_API_KEY: sk-fVrr-secret-value
          EMPTY_KEY:
        """)
        #expect(status["MIDPRO_API_KEY"] == true)
        // 空值必须读作「未配置」，否则界面会把空凭据当成已就绪
        #expect(status["EMPTY_KEY"] == false)
        #expect(status.count == 2)
    }

    @Test("归一化：DSH 与 Codex 侧同一模型归到同一身份")
    func identityNormalization() {
        #expect(ModelIdentity.normalize("DS/DeepSeek V4.1 Flash") == ModelIdentity.normalize("ark/DeepSeek-V4.1-Flash"))
        #expect(ModelIdentity.normalize("gemini-3.8-flash-high") == ModelIdentity.normalize("gemini-3.8-flash-high"))
        // 不同模型不能被错误合并
        #expect(ModelIdentity.normalize("gpt-image-2.5") != ModelIdentity.normalize("gpt-image-2.5-flare"))
    }

    @Test("跨宿主聚合：同一模型的两个别名收进同一组")
    func groupingAcrossHosts() throws {
        let records = [
            HostModelRecord(id: "DS/DeepSeek V4.1 Flash", host: .dsh, owner: "Aki", credentialKey: "MIDPRO_API_KEY"),
            HostModelRecord(id: "ark/DeepSeek-V4.1-Flash", displayName: "DeepSeek V4.1（公司网关）",
                            host: .codex, owner: "codex_gateway"),
            HostModelRecord(id: "gpt-image-2.5", host: .dsh, owner: "Aki", credentialKey: "MIDPRO_API_KEY")
        ]
        let groups = HostModelInventory.groups(records)
        #expect(groups.count == 2)

        let deepseek = try #require(groups.first { $0.records.count == 2 })
        let expectedHosts: [HostKind] = [.dsh, .codex]
        #expect(deepseek.hosts == expectedHosts)
        #expect(deepseek.aliases.sorted() == ["DS/DeepSeek V4.1 Flash", "ark/DeepSeek-V4.1-Flash"])
        // 展示名优先取 Codex 侧的中文显示名
        #expect(deepseek.displayName == "DeepSeek V4.1（公司网关）")
    }

    @Test("从 config.toml 取网关 base_url，用于把 Codex 模型挂到同端点密钥")
    func codexGatewayBaseURL() {
        let toml = """
        model_catalog_json = "/tmp/catalog.json"
        model = "ark/DeepSeek-V4.1-Flash"
        model_provider = "codex_gateway"

        [model_providers.codex_gateway]
        name = "Company AI Gateway"
        base_url = "http://192.168.1.200:8080/v1"
        wire_api = "responses"

        [model_providers.other]
        base_url = "https://should-not-be-picked.example.com/v1"
        """
        #expect(HostModelInventory.codexGatewayBaseURL(in: toml) == "http://192.168.1.200:8080/v1")
        #expect(HostModelInventory.codexGatewayBaseURL(in: "model = \"x\"") == "")
    }

    @Test("端点同源判断忽略结尾斜杠与大小写")
    func endpointComparison() {
        #expect(HostModelInventory.sameEndpoint("http://192.168.1.200:8080/v1/", "HTTP://192.168.1.200:8080/v1"))
        #expect(!HostModelInventory.sameEndpoint("http://192.168.1.200:8080/v1", "http://192.168.1.200:8080/v2"))
        #expect(!HostModelInventory.sameEndpoint("", "http://x/v1"))
    }

    @Test("密钥供给绑定：凭据键名与端点两条依据，都不命中则不猜测")
    func bindingRules() throws {
        let records = [
            HostModelRecord(id: "dsh-model-1", host: .dsh, owner: "Aki", credentialKey: "MIDPRO_API_KEY",
                            endpoint: "http://gw.local:8080/v1"),
            HostModelRecord(id: "gateway-model", host: .codex, owner: "codex_gateway",
                            endpoint: "http://gw.local:8080/v1"),
            HostModelRecord(id: "unrelated", host: .dsh, owner: "Other", credentialKey: "OTHER_API_KEY",
                            endpoint: "https://other.example.com/v1")
        ]
        let provider = Provider(id: "custom", name: "自定义", envKeys: ["CUSTOM_API_KEY"])

        // ① 凭据键名命中**且端点同源** → 绑定
        let byCredential = KeyRecord(providerID: "custom", label: "按凭据命中", hint: "…", fingerprint: "x",
                                     baseURL: "http://gw.local:8080/v1")
        let credentialTargets = [makeTarget(id: "dsh-desktop", format: .yaml, path: "/tmp/x.yaml", itemKey: "MIDPRO_API_KEY")]
        let first = HostModelInventory.bindings(for: byCredential, provider: provider,
                                                targets: credentialTargets, records: records)
        // 凭据键名命中 dsh-model-1；同一端点上的 codex 模型由「端点同源」再命中一条
        #expect(first.map { $0.modelID }.sorted() == ["dsh-model-1", "gateway-model"])
        #expect(first.contains { $0.modelID == "dsh-model-1" && $0.matchedBy.contains("MIDPRO_API_KEY") })

        // ①-反例：仅凭「落点键名同名」而端点完全无关时**必须不绑定**。
        // 实测踩坑：Gemini Key（generativelanguage.googleapis.com）曾被判成
        // 「供给公司网关的 5 个模型」，因为 DSH 落点键名与网关 apiKeyEnv 同名。
        let wrongVendor = KeyRecord(providerID: "google", label: "跨厂商 Key", hint: "…", fingerprint: "g",
                                    baseURL: nil)
        let googleProvider = Provider(id: "google", name: "Google Gemini", envKeys: ["GEMINI_API_KEY"],
                                      baseURL: "https://generativelanguage.googleapis.com/v1beta")
        #expect(HostModelInventory.bindings(for: wrongVendor, provider: googleProvider,
                                            targets: credentialTargets, records: records).isEmpty)

        // ② 端点命中（自定义 Base URL 指向同一台网关 → 同时挂上 DSH 与 Codex 两个模型）
        let byEndpoint = KeyRecord(providerID: "custom", label: "按端点命中", hint: "…", fingerprint: "y",
                                   baseURL: "http://gw.local:8080/v1/")
        let second = HostModelInventory.bindings(for: byEndpoint, provider: provider,
                                                 targets: [], records: records)
        #expect(second.count == 2)
        #expect(second.allSatisfy { $0.matchedBy.contains("端点") })
        #expect(second.contains { $0.host == .codex })

        // ③ 两条依据都不命中 → 不猜测，返回空
        let unrelated = KeyRecord(providerID: "custom", label: "无关", hint: "…", fingerprint: "z",
                                  baseURL: "https://nowhere.example.com/v1")
        #expect(HostModelInventory.bindings(for: unrelated, provider: provider,
                                            targets: [], records: records).isEmpty)
    }

    @Test("服务层：模型清单总览可在任意宿主路径下算出来")
    func serviceResolution() throws {
        let tmp = TempDir()
        // 造一份 DSH 宿主环境：设置文件 + 凭据文件都在临时目录里
        let settings = tmp.file("settings.yaml", content: Self.dshSample)
        let creds = tmp.file(".credentials.yaml", content: "refs:\n  MIDPRO_API_KEY: sk-abc\n")

        let providers = DshModelCatalog.parseProviders(try String(contentsOf: settings, encoding: .utf8))
        #expect(providers.first?.apiKeyEnv == "MIDPRO_API_KEY")
        let status = DshModelCatalog.credentialStatus(path: creds.path)
        #expect(status["MIDPRO_API_KEY"] == true)

        // 统一记录读取：临时设置文件 → 4 条模型记录，凭据键名来自宿主声明
        let records = DshModelCatalog.records(path: settings.path)
        #expect(records.count == 4)
        // 启用中的供应商：3 个模型，凭据键来自宿主声明的 apiKeyEnv
        let active = records.filter { $0.credentialKey == "MIDPRO_API_KEY" }
        #expect(active.count == 3)
        #expect(active.allSatisfy { $0.inMenu })
        // 已停用（enabled: false）的供应商：模型仍如实列出，但标注为不在宿主菜单
        let disabled = records.filter { $0.credentialKey == "LEGACY_API_KEY" }
        #expect(disabled.count == 1)
        #expect(disabled.allSatisfy { !$0.inMenu && !$0.note.isEmpty })

        // 概览必须能在任意宿主路径下算出来而不崩（不依赖运行本机的 ~/.codex）
        let service = try tmp.makeService()
        let overview = service.hostModelOverview(dshSettingsPath: settings.path,
                                                 dshCredentialsPath: creds.path,
                                                 codexCatalogPath: tmp.url.appendingPathComponent("none.json").path)
        #expect(overview["uniqueModels"] as? Int == 4)
        #expect(overview["dshDeclared"] as? Int == 4)
        // 只有声明了 MIDPRO_API_KEY 的 3 条算「凭据已配置」；LEGACY_API_KEY 未配置
        #expect(overview["dshCredentialConfigured"] as? Int == 3)

        // 未知落点不给宿主声明，回退到落点登记值（不越界猜测）
        #expect(service.hostDeclaredKeyName(forTargetID: "codex-cli") == nil)
    }

    @Test("密钥记录新增派生字段后，旧 vault.json 仍可解码")
    func vaultBackwardCompatibility() throws {
        let tmp = TempDir()
        let service = try tmp.makeService()
        let record = try service.addKey(providerID: "custom", label: "旧格式", secret: "sk-0123456789abcdef",
                                        priority: 100, tags: [], note: "", baseURL: nil)
        // 模拟旧版索引：把新增的派生字段从磁盘 JSON 里抹掉，再读回
        let url = tmp.url.appendingPathComponent("vault.json")
        var raw = try String(contentsOf: url, encoding: .utf8)
        raw = raw.replacingOccurrences(of: "\"modelBindings\"", with: "\"modelBindings_removed\"")
        try raw.write(to: url, atomically: true, encoding: .utf8)

        let reloaded = try service.listKeys()
        #expect(reloaded.contains { $0.id == record.id })
        // 派生字段不落盘：读回后必须为空数组而不是陈旧数据
        #expect(reloaded.first(where: { $0.id == record.id })?.modelBindings.isEmpty == true)
    }
}

// MARK: - 落点键名解析（宿主声明优先）

@Suite("宿主声明优先的键名解析")
struct TargetKeyResolutionTests {

    @Test("YAML 写入幂等：值相同但引号不同时不做空操作改写")
    func yamlIdempotentQuoting() throws {
        let original = """
        version: 1
        refs:
          MIDPRO_API_KEY: sk-abc123
        """
        // 同一值：不应产生任何改写（否则会造出假差异并留下无意义备份）
        let same = try ContentPatcher.patchYAML(content: original, section: "refs",
                                                key: "MIDPRO_API_KEY", value: "sk-abc123")
        #expect(same == original)

        // 值真的变了才改写
        let changed = try ContentPatcher.patchYAML(content: original, section: "refs",
                                                   key: "MIDPRO_API_KEY", value: "sk-changed")
        #expect(changed.contains("MIDPRO_API_KEY: \"sk-changed\""))
        #expect(changed != original)
    }
}

// ==============================================================================
// 网关单一事实源与宿主配置同步
// ==============================================================================

@Suite("网关单一事实源")
struct GatewayConfigTests {
    static let sample: [String: Any] = [
        "base_url": "http://192.168.1.200:8080/v1",
        "models": ["deepseek": "ark/DeepSeek-V4.1-Flash", "gemini": "gemini-3.8-flash-high"],
        "port": 47831
    ]

    @Test("解析网关声明的地址与模型路由")
    func parseGatewayConfig() {
        let config = GatewayConfig.parse(Self.sample, sourcePath: "/tmp/gw.json")
        #expect(config.baseURL == "http://192.168.1.200:8080/v1")
        #expect(config.port == 47831)
        // 键序稳定：deepseek 在 gemini 之前（按字典键排序，避免每次读出顺序不同）
        #expect(config.routes.map { $0.route } == ["deepseek", "gemini"])
        #expect(config.upstreamModels == ["ark/DeepSeek-V4.1-Flash", "gemini-3.8-flash-high"])
        #expect(config.isUsable)
    }

    @Test("读不到网关配置时如实返回空清单，不编造模型名")
    func missingGatewayDegrades() {
        let config = GatewayConfig.load(path: "/tmp/definitely-not-here-9f3a/config.json")
        #expect(config == nil)
        let empty = GatewayConfig.loadOrEmpty(path: "/tmp/definitely-not-here-9f3a/config.json")
        #expect(empty.upstreamModels.isEmpty)
        #expect(!empty.isUsable)
        // 网关不可用时，判定逻辑不得把任意模型当成网关模型
        #expect(!GatewayCatalog.isGatewayModel("gpt-5.6-luna", catalogPath: nil)
                || GatewayConfig.declaredModels(path: "/tmp/definitely-not-here-9f3a/config.json").isEmpty)
    }

    @Test("显示名由 slug 推导，新增模型无需改代码")
    func displayNameDerivation() {
        #expect(GatewayConfig.displayName(forSlug: "ark/DeepSeek-V4.1-Flash") == "DeepSeek V4.1 Flash（公司网关）")
        #expect(GatewayConfig.displayName(forSlug: "gemini-3.8-flash-high") == "gemini 3.8 flash high（公司网关）")
        // 无命名空间前缀也能处理
        #expect(GatewayConfig.displayName(forSlug: "kimi-k3").hasPrefix("kimi k3"))
    }

    @Test("网关二进制路径从 config.toml 已登记的 auth.command 读取，不硬编码家目录")
    func binaryPathFromRegisteredAuth() {
        let text = """
        model = "gpt-5.6-luna"

        [model_providers.codex_gateway.auth]
        command = "/bin/sh"
        args = ["auth", "print"]
        """
        #expect(GatewayConfig.registeredAuthCommand(in: text) == "/bin/sh")
        // 该路径可执行 → 直接采用
        #expect(GatewayConfig.binaryPath(codexConfigText: text) == "/bin/sh")

        let absent = """
        [model_providers.other.auth]
        command = "/bin/sh"
        """
        #expect(GatewayConfig.registeredAuthCommand(in: absent) == nil)
    }
}

@Suite("宿主配置同步：网关清单 → 客户端")
struct HostConfigSyncTests {
    static let settings = """
    onboarding:
      completed: true
    llm-pi-ai:
      providers:
        midpro:
          displayName: Company Gateway
          apiKeyEnv: MIDPRO_API_KEY
          baseURL: http://192.168.1.200:8080/v1
          models:
            - id: DS/DeepSeek V4.1 Flash
            - id: gpt-6-astra
        other:
          baseURL: https://api.example.com/v1
          models:
            - id: should-not-be-touched
      provider: midpro
    permissions:
      mode: allow
    """

    @Test("merge 默认只增不减：宿主自建模型绝不丢失")
    func mergeNeverDeletes() {
        // 真实反例：网关只声明 deepseek/gemini 两条线路，
        // 而 DSH 里还有 gpt-6-astra / gpt-image-2.5 —— 整体替换会把它们删掉
        let result = HostConfigSync.resolveModels(
            mode: .merge,
            declared: ["ark/DeepSeek-V4.1-Flash"],
            existing: ["DS/DeepSeek V4.1 Flash", "gpt-6-astra", "gpt-image-2.5"]
        )
        #expect(result == ["DS/DeepSeek V4.1 Flash", "gpt-6-astra", "gpt-image-2.5", "ark/DeepSeek-V4.1-Flash"])

        // replace 只在显式要求时才会删
        let pruned = HostConfigSync.resolveModels(
            mode: .replace,
            declared: ["ark/DeepSeek-V4.1-Flash"],
            existing: ["gpt-6-astra"]
        )
        #expect(pruned == ["ark/DeepSeek-V4.1-Flash"])
    }

    @Test("按网关地址唯一定位供应商；多个候选时拒绝猜测")
    func locateProviderByEndpoint() throws {
        let lines = Self.settings.components(separatedBy: "\n")
        let located = try #require(HostConfigSync.locateDshProvider(lines: lines, baseURL: "http://192.168.1.200:8080/v1"))
        #expect(located.providerID == "midpro")
        #expect(located.currentModels == ["DS/DeepSeek V4.1 Flash", "gpt-6-astra"])

        // 地址不在配置里 → 定位失败（调用方据此拒绝写入）
        #expect(HostConfigSync.locateDshProvider(lines: lines, baseURL: "http://10.0.0.1:1/v1") == nil)
    }

    @Test("定点同步：只在既有 models 列表末尾追加，其它字节一个都不动")
    func surgicalInsertPreservesBytes() throws {
        let patched = try HostConfigSync.patchDshModels(
            content: Self.settings, providerID: "midpro",
            models: ["ark/DeepSeek-V4.1-Flash"], mode: .merge
        )
        #expect(patched.before == ["DS/DeepSeek V4.1 Flash", "gpt-6-astra"])
        #expect(patched.after == ["DS/DeepSeek V4.1 Flash", "gpt-6-astra", "ark/DeepSeek-V4.1-Flash"])

        // 逐行比较：除了新增的那一行，原有内容必须完全一致（含另一供应商的区块）
        let before = Self.settings.components(separatedBy: "\n")
        let after = patched.text.components(separatedBy: "\n")
        #expect(after.count == before.count + 1)
        var removedLine = after
        removedLine.removeAll { $0.contains("ark/DeepSeek-V4.1-Flash") }
        #expect(removedLine == before)
        // 别的供应商区块没有被波及
        #expect(patched.text.contains("- id: should-not-be-touched"))
        // 不该出现重复的 models 键
        #expect(patched.text.components(separatedBy: "models:").count == 3)
    }

    @Test("既有条目用单行标量时，新条目也保持单行标量（形状一致）")
    func entryShapeFollowsExisting() throws {
        let patched = try HostConfigSync.patchDshModels(
            content: Self.settings, providerID: "midpro",
            models: ["ark/DeepSeek-V4.1-Flash"], mode: .merge
        )
        // 既有条目全是 `- id: xxx`，因此新条目不得带 input 子块
        #expect(!patched.text.contains("input:"))
    }

    @Test("已一致时不产生任何改写（幂等）")
    func idempotentWhenConsistent() throws {
        let already = try HostConfigSync.patchDshModels(
            content: Self.settings, providerID: "midpro",
            models: ["DS/DeepSeek V4.1 Flash"], mode: .merge
        )
        #expect(already.text == Self.settings)
    }

    @Test("行内流式写法拒绝改写而不是猜")
    func rejectsFlowStyle() {
        let flow = """
        llm-pi-ai:
          providers:
            midpro:
              baseURL: http://192.168.1.200:8080/v1
              models: [a, b]
        """
        #expect(throws: (any Error).self) {
            _ = try HostConfigSync.patchDshModels(content: flow, providerID: "midpro", models: ["c"])
        }
    }

    @Test("Codex 目录：补齐缺失的网关模型，已存在的条目字段不被覆盖")
    func codexCatalogMerge() throws {
        let gateway = GatewayConfig.parse(
            ["base_url": "http://192.168.1.200:8080/v1",
             "models": ["deepseek": "ark/DeepSeek-V4.1-Flash"]],
            sourcePath: "/tmp/gw.json"
        )
        let existing: [[String: Any]] = [
            ["slug": "ark/DeepSeek-V4.1-Flash", "display_name": "用户改过的名字", "visibility": "hide"]
        ]
        let outcome = try HostConfigSync.syncCodexCatalog(gateway: gateway, existingEntries: existing)
        #expect(outcome.changed)
        // 被隐藏的网关条目恢复为菜单可见，但显示名仍尊重用户
        #expect(outcome.entries.count == 1)
        #expect(outcome.entries[0]["display_name"] as? String == "用户改过的名字")
        #expect(outcome.entries[0]["visibility"] as? String == "list")
    }

    @Test("网关清单为空时同步是空操作，不会清空客户端配置")
    func emptyGatewayIsNoOp() throws {
        let empty = GatewayConfig(baseURL: "", port: nil, routes: [], updatedAt: nil, sourcePath: "")
        let existing: [[String: Any]] = [["slug": "gpt-5.6-luna"]]
        let outcome = try HostConfigSync.syncCodexCatalog(gateway: empty, existingEntries: existing)
        #expect(!outcome.changed)
        #expect(outcome.entries.count == 1)

        let result = HostConfigSync.resolveModels(mode: .merge, declared: [], existing: ["a", "b"])
        #expect(result == ["a", "b"])
    }
}

@Suite("DSH 网关路由表写法")
struct GatewayRouteShapeTests {
    @Test("models 写成 线路名: 上游模型名 时取上游模型名，不把内部别名当模型")
    func parsesRouteMap() {
        let yaml = """
        llm-pi-ai:
          providers:
            midpro:
              apiKeyEnv: MIDPRO_API_KEY
              baseURL: http://192.168.1.200:8080/v1
              models:
                deepseek: ark/DeepSeek-V4.1-Flash
                gemini: gemini-3.8-flash-high
        """
        let providers = DshModelCatalog.parseProviders(yaml)
        #expect(providers.count == 1)
        #expect(providers[0].modelIDs == ["ark/DeepSeek-V4.1-Flash", "gemini-3.8-flash-high"])
    }

    @Test("块式序列写法仍照旧解析（不回归）")
    func stillParsesBlockSequence() {
        let yaml = """
        llm-pi-ai:
          providers:
            midpro:
              models:
                - id: a
                - id: b
        """
        #expect(DshModelCatalog.parseProviders(yaml).first?.modelIDs == ["a", "b"])
    }
}

@Suite("一键切换 Codex 网关模型")
struct GatewayModelSwitchTests {
    @Test("切换模型只搬动 model 与 model_provider 两个键，其余设置字节不动")
    func switchRewritesOnlyTwoKeys() {
        let original = """
        model_catalog_json = "/tmp/catalog.json"
        approval_policy = "never"

        model = "gpt-5.6-luna"
        model_provider = "openai"

        [desktop]
        localeOverride = "zh-CN"
        """
        let updated = InjectionEngine.setCodexGatewayModel("gemini-3.8-flash-high", in: original)
        #expect(updated.contains("model = \"gemini-3.8-flash-high\""))
        #expect(updated.contains("model_provider = \"codex_gateway\""))
        #expect(!updated.contains("model_provider = \"openai\""))
        // 其它设置原样保留
        #expect(updated.contains("model_catalog_json = \"/tmp/catalog.json\""))
        #expect(updated.contains("approval_policy = \"never\""))
        #expect(updated.contains("localeOverride = \"zh-CN\""))
        // 只有一个 model 赋值
        #expect(updated.components(separatedBy: "model = ").count == 2)
    }

    @Test("重复切换幂等")
    func switchIsIdempotent() {
        let once = InjectionEngine.setCodexGatewayModel("gemini-3.8-flash-high", in: "model = \"a\"\n")
        let twice = InjectionEngine.setCodexGatewayModel("gemini-3.8-flash-high", in: once)
        #expect(once == twice)
        // 三次也稳定（防止「第二次正常、第三次又开始累积标记」这类回归）
        let thrice = InjectionEngine.setCodexGatewayModel("gemini-3.8-flash-high", in: twice)
        #expect(twice == thrice)
        // 无论如何都不该出现两个 BEGIN 或两个 END
        #expect(once.components(separatedBy: "# BEGIN CODEX-GATEWAY DESKTOP").count == 2)
        #expect(once.components(separatedBy: "# END CODEX-GATEWAY DESKTOP").count == 2)
    }
}

@Suite("受管标记清理：孤儿 BEGIN 不得吞掉用户设置")
struct ManagedMarkerTests {

    /// 真实回归：Codex 桌面端重写 `config.toml` 时会吞掉 `# END` 注释行，
    /// 只留下一个没有结束标记的 `# BEGIN`。早期实现把「BEGIN 之后的一切」
    /// 都当作受管块内容删掉，结果用户的 `[marketplaces.openai-bundled]`
    /// 被静默清除（实测发生过）。孤儿 BEGIN 只能删到「标记行 + 紧跟的注释行」。
    @Test("孤儿 BEGIN 只删标记与紧跟注释，[section] 必须保留")
    func orphanBeginKeepsUserSections() {
        let input = """
        model_reasoning_effort = "xhigh"
        # BEGIN CODEX-GATEWAY DESKTOP
        # 桌面端换模型时必须同时锁定 provider
        model = "ark/DeepSeek-V4.1-Flash"

        [marketplaces.openai-bundled]
        source_type = "local"
        """
        let out = InjectionEngine.removeManagedBlock(from: input)
        // 用户的设置段落必须逐字保留
        #expect(out.contains("[marketplaces.openai-bundled]"))
        #expect(out.contains("source_type = \"local\""))
        #expect(out.contains("model_reasoning_effort = \"xhigh\""))
        // 孤儿标记与它紧跟的说明注释清掉
        #expect(!out.contains("# BEGIN CODEX-GATEWAY DESKTOP"))
        #expect(!out.contains("# 桌面端换模型时必须同时锁定 provider"))
        // 块内那两行受管赋值也要清掉——否则会留下「挂着网关 provider 的裸 model」这种半残配置
        #expect(!out.contains("model = \"ark/DeepSeek-V4.1-Flash\""))
        #expect(!out.contains("model_provider = "))
    }

    /// 完整成对区块（BEGIN…END）必须整块消失，包括块内的受管赋值。
    @Test("完整成对区块被整体清除")
    func completeBlockIsRemoved() {
        let input = """
        model_reasoning_effort = "xhigh"
        # BEGIN CODEX-GATEWAY DESKTOP
        model = "gemini-3.8-flash-high"
        model_provider = "codex_gateway"
        # END CODEX-GATEWAY DESKTOP

        [marketplaces.openai-bundled]
        source_type = "local"
        """
        let out = InjectionEngine.removeManagedBlock(from: input)
        #expect(!out.contains("# BEGIN CODEX-GATEWAY DESKTOP"))
        #expect(!out.contains("# END CODEX-GATEWAY DESKTOP"))
        #expect(!out.contains("model_provider = \"codex_gateway\""))
        #expect(out.contains("[marketplaces.openai-bundled]"))
        #expect(out.contains("model_reasoning_effort = \"xhigh\""))
    }

    /// 反复清理必须收敛：第二次不能再删掉任何东西（否则用户每换一次模型就丢一段配置）。
    @Test("清理幂等：第二次不再改动")
    func cleanupIsIdempotent() {
        let input = """
        model_reasoning_effort = "xhigh"
        # BEGIN CODEX-GATEWAY DESKTOP
        model = "ark/DeepSeek-V4.1-Flash"
        model_provider = "codex_gateway"
        # END CODEX-GATEWAY DESKTOP

        [marketplaces.openai-bundled]
        source_type = "local"
        """
        let once = InjectionEngine.removeManagedBlock(from: input)
        let twice = InjectionEngine.removeManagedBlock(from: once)
        let thrice = InjectionEngine.removeManagedBlock(from: twice)
        #expect(once == twice)
        #expect(twice == thrice)
    }

    /// 没有标记时必须是**逐字节原样返回**：任何顺手「格式化」都会造成假差异。
    @Test("无标记时逐字节原样返回")
    func untouchedWhenNoMarkers() {
        let input = "model = \"x\"\n\n[tui]\nnotifications = true\n  indented = 1\n"
        #expect(InjectionEngine.removeManagedBlock(from: input) == input)
    }
}

// MARK: - 模型发现（REQ-020）

/// 记录请求并按候选端点返回不同响应的假传输层，
/// 用于验证「逐级兜底」而不是只验证「一次成功」。
final class ScriptedTransport: HTTPTransport, @unchecked Sendable {
    struct Reply { var status: Int; var body: Data }
    private let lock = NSLock()
    private(set) var requestedURLs: [String] = []
    private var responder: (String) -> Reply

    init(responder: @escaping (String) -> Reply) {
        self.responder = responder
    }

    convenience init(status: Int = 200, body: String = "{}") {
        self.init { _ in Reply(status: status, body: Data(body.utf8)) }
    }

    func send(_ request: URLRequest) async throws -> (status: Int, body: Data) {
        let url = request.url?.absoluteString ?? ""
        lock.lock()
        requestedURLs.append(url)
        let reply = responder(url)
        lock.unlock()
        return (reply.status, reply.body)
    }

    var callCount: Int {
        lock.lock(); defer { lock.unlock() }
        return requestedURLs.count
    }
}

@Suite("模型发现")
struct ModelDiscoveryTests {

    /// 四种响应形态必须都能解析（OpenAI / Gemini / Ollama / 裸数组）
    @Test("解析四种 /models 响应形态")
    func parsesFourResponseShapes() {
        let openai = Data(#"{"object":"list","data":[{"id":"gpt-4o"},{"id":"gpt-6-astra"}]}"#.utf8)
        #expect(ModelEndpointProbe.parseModels(body: openai) == ["gpt-4o", "gpt-6-astra"])

        let gemini = Data(#"{"models":[{"name":"models/gemini-3.8-flash-high"},{"name":"models/gemini-2.0"}]}"#.utf8)
        #expect(ModelEndpointProbe.parseModels(body: gemini) == ["gemini-3.8-flash-high", "gemini-2.0"])

        let ollama = Data(#"{"models":[{"name":"llama3","size":1}]}"#.utf8)
        #expect(ModelEndpointProbe.parseModels(body: ollama) == ["llama3"])

        let bare = Data(#"["ark/DeepSeek-V4.1-Flash",{"model":"gpt-image-2.5"}]"#.utf8)
        #expect(ModelEndpointProbe.parseModels(body: bare) == ["ark/DeepSeek-V4.1-Flash", "gpt-image-2.5"])
    }

    /// 畸形输入绝不能崩，也不能把垃圾当成模型名
    @Test("畸形响应返回空数组而不是崩溃")
    func malformedBodyIsSafe() {
        #expect(ModelEndpointProbe.parseModels(body: Data("<html>404</html>".utf8)).isEmpty)
        #expect(ModelEndpointProbe.parseModels(body: Data("".utf8)).isEmpty)
        #expect(ModelEndpointProbe.parseModels(body: Data("{\"data\":{}}".utf8)).isEmpty)
        #expect(ModelEndpointProbe.parseModels(body: Data("{\"data\":[{\"nope\":1}]}".utf8)).isEmpty)
    }

    /// 候选端点顺序：自定义端点优先，且不允许重复
    @Test("候选端点顺序与去重")
    func candidateOrder() {
        let withCustom = ModelEndpointProbe.candidates(
            baseURL: "http://192.168.1.200:8080/v1",
            providerBaseURL: "https://api.openai.com/v1",
            healthPath: "/models"
        )
        #expect(withCustom.first?.url == "http://192.168.1.200:8080/v1/models")
        #expect(withCustom.count == Set(withCustom.map { $0.url }).count)
        #expect(withCustom.contains { $0.url == "http://192.168.1.200:8080/models" })
        #expect(withCustom.contains { $0.url == "https://api.openai.com/v1/models" })
        // 无端点（custom 厂商且未填 baseURL）时必须是空数组：界面据此提示「无法探测」
        #expect(ModelEndpointProbe.candidates(baseURL: nil, providerBaseURL: nil, healthPath: nil).isEmpty)
    }

    /// 端点探测成功：来源必须是「端点探测」，且模型数取实测结果
    @Test("端点探测成功采用实测模型")
    func probeSucceeds() async throws {
        let dir = TempDir()
        let transport = ScriptedTransport(status: 200, body: #"{"data":[{"id":"a"},{"id":"b"},{"id":"c"}]}"#)
        let service = try dir.makeService(transport: transport)
        let key = try service.addKey(providerID: "custom", label: "公司AI综合", secret: "sk-test-123456",
                                     baseURL: "http://192.168.1.200:8080/v1")
        let result = try await service.discoverModels(forKeyID: key.id)
        #expect(result.probed)
        #expect(result.models.count == 3)
        #expect(result.models.allSatisfy { $0.source == .probe })
        #expect(result.sourceLabel == "端点探测")
        #expect(result.endpoint == "http://192.168.1.200:8080/v1/models")
    }

    /// T1 失败必须逐级尝试变体，全部失败才降级到宿主映射（T4）
    @Test("四级兜底：变体尝试与宿主映射降级")
    func fallsBackToHostMapping() async throws {
        let dir = TempDir()
        // 只有 /v1/models 之外的路径返回 200，强迫走 T2 变体
        let transport = ScriptedTransport { url in
            url.hasSuffix("/v1/models")
                ? ScriptedTransport.Reply(status: 404, body: Data("no".utf8))
                : ScriptedTransport.Reply(status: 200, body: Data(#"{"data":[{"id":"ark/DeepSeek-V4.1-Flash"}]}"#.utf8))
        }
        let service = try dir.makeService(transport: transport)
        let key = try service.addKey(providerID: "custom", label: "变体端点", secret: "sk-variant-123",
                                     baseURL: "http://10.0.0.9/v1")
        // 显式传空宿主记录：本用例只验证 T1/T2 变体，不受本机 DSH/Codex 配置影响
        let probed = try await service.discoverModels(forKeyID: key.id, hostRecords: [])
        #expect(probed.probed)
        #expect(probed.models.map { $0.modelID } == ["ark/DeepSeek-V4.1-Flash"])
        #expect(probed.endpoint.contains("/v1/models") == false)

        // 全失败 → 降级为宿主映射（T4），note 里必须说明原因
        let dead = ScriptedTransport(status: 500, body: "boom")
        let deadService = try dir.makeService(transport: dead)
        let deadKey = try deadService.addKey(providerID: "custom", label: "全失败", secret: "sk-dead-1234",
                                             baseURL: "http://10.0.0.10/v1")
        let hostRecords = [
            HostModelRecord(id: "gemini-3.8-flash-high", host: .dsh, owner: "midpro",
                            credentialKey: "CUSTOM_API_KEY", endpoint: "http://10.0.0.10/v1")
        ]
        let degraded = await deadService.ensureDiscoveredModels(for: deadKey, hostRecords: hostRecords, persist: false)
        #expect(degraded.probed == false)
        #expect(degraded.models.map { $0.source } == [.hostMapped])
        #expect(degraded.note.contains("降级"))
        #expect(degraded.note.contains("HTTP 500"))
    }

    /// 无端点时不能编造：结果为空并如实说明「无法探测」
    @Test("无端点时不编造模型")
    func noEndpointMeansNoFabrication() async throws {
        let dir = TempDir()
        let transport = ScriptedTransport()
        let service = try dir.makeService(transport: transport)
        let key = try service.addKey(providerID: "custom", label: "无端点", secret: "sk-noendpoint-1")
        #expect(service.probeCandidates(for: key).isEmpty)
        let result = await service.ensureDiscoveredModels(for: key, hostRecords: [], persist: false)
        #expect(result.models.isEmpty)
        #expect(result.probed == false)
        #expect(result.note.contains("未配置可探测端点"))
        #expect(transport.callCount == 0)
    }

    /// T5 名称推断：只补 T4 未覆盖的模型，且必须标成「推断」
    @Test("名称推断只作候选且标注推断")
    func inferredModelsAreLabelled() async throws {
        let dir = TempDir()
        // 用独立数据目录：本用例与「端点探测」用例的缓存不能互相污染
        let cacheDir = TempDir()
        let service = try cacheDir.makeService(transport: ScriptedTransport(status: 500, body: "nope"))
        let key = try service.addKey(providerID: "custom", label: "推断验证", secret: "sk-infer-12345",
                                     baseURL: "http://10.0.0.11/v1")
        let hostRecords = [
            // ① 凭据键名命中本 Key 厂商环境变量名 → T4 宿主映射（不是推断）
            HostModelRecord(id: "mine-model", host: .dsh, owner: "公司AI综合", credentialKey: "CUSTOM_API_KEY",
                            endpoint: "http://10.0.0.11/v1"),
            // ② 宿主未标注凭据键名、且供应商与本 Key 厂商相符 → T5 推断
            HostModelRecord(id: "same-vendor-model", host: .dsh, owner: "自定义 / 兼容网关",
                            credentialKey: "", endpoint: "http://10.0.0.98/v1"),
            // ②-反例：既非本厂商、端点也不同域 → 连推断都不给（避免噪声误导）
            HostModelRecord(id: "noise-model", host: .dsh, owner: "someone",
                            credentialKey: "", endpoint: "https://totally-unrelated.example.com/v1"),
            // ③ 明确声明由别的凭据供给 → 绝不推断（那是别人的 Key）
            HostModelRecord(id: "other-key-model", host: .dsh, owner: "midpro",
                            credentialKey: "SOMEONE_ELSE_KEY", endpoint: "http://10.0.0.99/v1")
        ]
        let result = await service.ensureDiscoveredModels(for: key, hostRecords: hostRecords, persist: false)
        let byID = Dictionary(uniqueKeysWithValues: result.normalizedModels.map { ($0.modelID, $0) })
        #expect(byID["mine-model"]?.source == .hostMapped)
        #expect(byID["same-vendor-model"]?.source == .inferred)
        #expect(byID["same-vendor-model"]?.evidence.contains("推断") == true)
        #expect(byID["other-key-model"] == nil)
        #expect(byID["noise-model"] == nil)
    }

    /// 缓存只在指纹一致时有效；换明文（指纹变化）必须作废旧结果
    @Test("发现缓存与指纹绑定")
    func cacheIsFingerprintBound() async throws {
        let dir = TempDir()
        let first = ScriptedTransport(status: 200, body: #"{"data":[{"id":"old-model"}]}"#)
        let service = try dir.makeService(transport: first)
        let key = try service.addKey(providerID: "custom", label: "缓存", secret: "sk-cache-old",
                                     baseURL: "http://10.0.0.12/v1")
        _ = try await service.discoverModels(forKeyID: key.id)
        #expect(first.callCount == 1)
        // 有缓存时再读不应产生新请求
        _ = await service.ensureDiscoveredModels(for: key)
        #expect(first.callCount == 1)

        let changed = try service.updateKey(id: key.id, secret: "sk-cache-new-999")
        #expect(service.cachedDiscovery(for: changed) == nil)
    }

    /// 同类模型（ark/xxx 与 xxx）去重后只保留置信度最高的一条
    @Test("同一模型跨来源去重")
    func deduplicatesAcrossSources() {
        let result = ModelDiscoveryResult(
            probed: false, endpoint: "", note: "",
            models: [
                AvailableModel(modelID: "ark/DeepSeek-V4.1-Flash", source: .inferred),
                AvailableModel(modelID: "DeepSeek-V4.1-Flash", source: .probe),
                AvailableModel(modelID: "gemini-3.8-flash-high", source: .hostMapped)
            ],
            fingerprint: "abcd1234"
        )
        let normalized = result.normalizedModels
        #expect(normalized.count == 2)
        #expect(normalized.first?.modelID == "DeepSeek-V4.1-Flash")
        #expect(normalized.first?.source == .probe)
    }

    /// 缓存文件绝不能出现密钥明文
    @Test("发现缓存不含明文")
    func cacheHasNoPlaintext() async throws {
        let dir = TempDir()
        let secret = "sk-super-secret-value-42"
        let service = try dir.makeService(transport: ScriptedTransport(status: 200, body: #"{"data":[{"id":"m1"}]}"#))
        let key = try service.addKey(providerID: "custom", label: "明文检查", secret: secret,
                                     baseURL: "http://10.0.0.13/v1")
        _ = try await service.discoverModels(forKeyID: key.id)
        let cacheText = try String(contentsOf: URL(fileURLWithPath: service.discoveryCache.path), encoding: .utf8)
        #expect(!cacheText.contains(secret))
        #expect(cacheText.contains("m1"))
    }
}

// MARK: - 密钥库分区与详情（REQ-019 / REQ-021）

@Suite("密钥库分区与详情")
struct KeyGroupingTests {

    /// 一把 key 一个分区；标题就是别名；已启用优先、组内按优先级
    @Test("按别名分区与排序")
    func groupsByLabel() throws {
        let dir = TempDir()
        let service = try dir.makeService()
        _ = try service.addKey(providerID: "deepseek", label: "备用", secret: "sk-b-1", priority: 5)
        _ = try service.addKey(providerID: "openai", label: "主力", secret: "sk-a-1", priority: 100)
        let disabled = try service.addKey(providerID: "google", label: "停用中", secret: "AIza-1", priority: 1)
        _ = try service.setEnabled(id: disabled.id, enabled: false)

        let groups = try service.keyGroups()
        #expect(groups.count == 3)
        #expect(groups.map { $0.label } == ["备用", "主力", "停用中"])
        #expect(groups.allSatisfy { $0.records.count == 1 })
        #expect(groups.last?.records.first?.enabled == false)
    }

    /// 详情必须同时给出「可提供模型」与「宿主绑定」，并标清来源
    @Test("密钥详情聚合可提供模型与落点")
    func detailAggregates() async throws {
        let dir = TempDir()
        let service = try dir.makeService(transport: ScriptedTransport(status: 200, body: #"{"data":[{"id":"deepseek-chat"},{"id":"deepseek-reasoner"}]}"#))
        let key = try service.addKey(providerID: "custom", label: "公司AI综合", secret: "sk-detail-1",
                                     baseURL: "http://192.168.1.200:8080/v1")
        let targetFile = dir.file("dsh-settings.yaml", content: "refs: {}\n")
        try service.addCustomTarget(
            makeTarget(id: "dsh-desktop", format: .yaml, path: targetFile.path, itemKey: "MIDPRO_API_KEY", providerID: "custom")
        )
        _ = try service.applyInjection(try service.planInjection(targetID: "dsh-desktop", keyID: key.id))

        // 显式传空宿主记录：本机 ~/.codex 可能真实存在，会污染「可提供模型」的断言
        let detail = try service.keyDetail(id: key.id, hostRecords: [])
        #expect(detail.probeable)
        #expect(detail.availableModels.isEmpty)  // 未探测前不编造，只如实为空
        #expect(detail.locations.count == 1)
        #expect(detail.locations.first?.targetID == "dsh-desktop")
        #expect(detail.locations.first?.itemKey == "MIDPRO_API_KEY")
        #expect(!detail.auditEntries.isEmpty)

        // 该厂商预设（custom）没有模型清单，且临时目录里没有宿主配置文件，
        // 因此「可提供模型」只能来自端点实测 —— 这正是本需求要的能力。
        _ = try await service.discoverModels(forKeyID: key.id, hostRecords: [])
        let refreshed = try service.keyDetail(id: key.id, hostRecords: [])
        #expect(refreshed.availableModels.map { $0.modelID } == ["deepseek-chat", "deepseek-reasoner"])
        #expect(refreshed.availableModels.allSatisfy { $0.source == .probe })
    }

    // MARK: 三维度解析（REQ-024：模型名称 / 剩余额度 / 更新日期）

    @Test("OpenAI 形状：created 解析为发布时间，shutdown_date 进下线公告")
    func modelMetadataOpenAI() {
        let body = Data(#"""
        {"object":"list","data":[{"id":"gpt-4o","object":"model","created":1700000000,"owned_by":"openai","shutdown_date":"2027-01-31"}]}
        """#.utf8)
        let entries = ModelEndpointProbe.parseModelEntries(body: body)
        #expect(entries.count == 1)
        #expect(entries.first?.id == "gpt-4o")
        let meta = entries.first?.metadata
        #expect(meta?.versionTag == nil)
        #expect(meta?.shutdownDate == "2027-01-31")
        // 秒级时间戳必须落在 1700000000 之后，且不超过 1 秒误差
        if let published = meta?.publishedAt {
            #expect(published.timeIntervalSince1970 >= 1_700_000_000)
            #expect(published.timeIntervalSince1970 < 1_700_000_001)
        } else {
            Issue.record("created 未解析成发布时间")
        }
        #expect(meta?.publishedSource == "协议 · created")
    }

    @Test("DeepSeek 形状：完全没有时间字段，不得伪造更新时间")
    func modelMetadataDeepSeek() {
        let body = Data(#"{"object":"list","data":[{"id":"deepseek-chat","object":"model","owned_by":"deepseek"}]}"#.utf8)
        let entries = ModelEndpointProbe.parseModelEntries(body: body)
        #expect(entries.map { $0.id } == ["deepseek-chat"])
        // 该协议不提供时间与版本：元数据整体为 nil，界面据此显示「该协议不提供」
        #expect(entries.first?.metadata == nil)
    }

    @Test("Gemini 形状：version 记成版本号，绝不当作更新时间")
    func modelMetadataGemini() {
        let body = Data(#"{"models":[{"name":"models/gemini-2.0-flash","version":"001","displayName":"Gemini 2.0 Flash"}]}"#.utf8)
        let entries = ModelEndpointProbe.parseModelEntries(body: body)
        #expect(entries.map { $0.id } == ["gemini-2.0-flash"])
        // 关键断言：version 不得产生 publishedAt（否则界面会把版本号当日期显示）
        #expect(entries.first?.metadata?.publishedAt == nil)
        #expect(entries.first?.metadata?.versionTag == "001")
    }

    @Test("旧缓存（无 metadata / balance 键）仍可解码，不丢历史识别结果")
    func legacyCacheDecoding() throws {
        let legacy = Data(#"""
        {"probed":true,"endpoint":"http://x/v1/models","note":"ok","httpStatus":200,
         "models":[{"modelID":"m1","displayName":"m1","source":"probe","evidence":"e","owner":"","inMenu":true,"credentialKey":"","endpoint":"http://x/v1/models"}],
         "fetchedAt":770000000.0,"fingerprint":"fp-1"}
        """#.utf8)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let result = try decoder.decode(ModelDiscoveryResult.self, from: legacy)
        #expect(result.models.map { $0.modelID } == ["m1"])
        #expect(result.models.first?.metadata == nil)
        #expect(result.balance == nil)
        #expect(result.probed)
    }

    @Test("DeepSeek 余额响应解析：布尔闸门 + 分币种金额原样保留")
    func balanceParsing() {
        let body = Data(#"""
        {"is_available":true,"balance_infos":[{"currency":"CNY","total_balance":"110.00","granted_balance":"10.00","topped_up_balance":"100.00"}]}
        """#.utf8)
        let info = ModelEndpointProbe.parseBalance(body: body, endpoint: "https://api.deepseek.com/user/balance", httpStatus: 200)
        #expect(info?.isAvailable == true)
        #expect(info?.entries.count == 1)
        #expect(info?.entries.first?.currency == "CNY")
        // 金额必须是字符串原样，避免浮点误差把 110.00 显示成 110.0
        #expect(info?.entries.first?.total == "110.00")
        #expect(info?.entries.first?.granted == "10.00")
        #expect(info?.entries.first?.toppedUp == "100.00")
        #expect(info?.summary.contains("110.00 CNY") == true)
    }

    @Test("DeepSeek 余额识别：多候选端点命中 /user/balance")
    func balanceProbeEndToEnd() async throws {
        let dir = TempDir()
        let transport = ScriptedTransport { url in
            if url.contains("/user/balance") {
                return ScriptedTransport.Reply(status: 200, body: Data(#"{"is_available":true,"balance_infos":[{"currency":"USD","total_balance":"7.50"}]}"#.utf8))
            }
            return ScriptedTransport.Reply(status: 200, body: Data(#"{"object":"list","data":[{"id":"deepseek-chat","object":"model","owned_by":"deepseek"}]}"#.utf8))
        }
        let service = try dir.makeService(transport: transport)
        let key = try service.addKey(providerID: "deepseek", label: "DS 主力", secret: "sk-ds-balance-1")
        let result = try await service.discoverModels(forKeyID: key.id, hostRecords: [])

        #expect(result.probed)
        #expect(result.balance?.supported == true)
        #expect(result.balance?.isAvailable == true)
        #expect(result.balance?.entries.first?.total == "7.50")
        // 余额端点必须被真的请求过（而不是靠猜），且走的是官方 /user/balance 路径
        #expect(transport.requestedURLs.contains { $0.contains("/user/balance") })
    }

    @Test("非 DeepSeek 厂商：不做余额请求，如实标注「该协议不提供」")
    func balanceUnsupportedProvider() async throws {
        let dir = TempDir()
        let transport = ScriptedTransport { _ in
            ScriptedTransport.Reply(status: 200, body: Data(#"{"object":"list","data":[{"id":"gpt-4o","object":"model","created":1700000000,"owned_by":"openai"}]}"#.utf8))
        }
        let service = try dir.makeService(transport: transport)
        let key = try service.addKey(providerID: "openai", label: "OpenAI 主力", secret: "sk-openai-1")
        let result = try await service.discoverModels(forKeyID: key.id, hostRecords: [])

        #expect(result.probed)
        // 关键：预设里没有 balancePath，就不该发起任何余额请求
        #expect(result.balance == nil)
        #expect(!transport.requestedURLs.contains { $0.contains("balance") })
    }
}
