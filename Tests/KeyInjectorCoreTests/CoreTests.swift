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
