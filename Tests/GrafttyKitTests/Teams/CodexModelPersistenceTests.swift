import Foundation
import Testing
@testable import GrafttyKit

struct CodexModelPersistenceTests {
    @Test("@spec TEAM-10.25: When Graftty refreshes a managed Codex home after a /model choice, the application shall retain the saved model and reasoning effort across launches while honoring subsequent durable model changes.")
    func modelChoiceSurvivesRefresh() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source")
        let managed = root.appendingPathComponent("managed")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let config = source.appendingPathComponent("config.toml")
        let local = managed.appendingPathComponent("config.toml")
        let original = "model = \"original\"\nmodel_reasoning_effort = \"medium\"\n"
        try original.write(to: config, atomically: true, encoding: .utf8)
        let mirror = CodexHomeMirror(sourceDirectory: source, mirrorDirectory: managed)
        try mirror.rebuild()
        try "model = \"selected\"\nmodel_reasoning_effort = \"high\"\n".write(to: local, atomically: true, encoding: .utf8)

        // Unrelated durable edits must refresh without undoing /model.
        let updated = "'model'  =  \"original\" # same default\nmodel_reasoning_effort=\"medium\"\n[features]\nhooks = false\n"
        try updated.write(to: config, atomically: true, encoding: .utf8)
        for _ in 0..<2 {
            try mirror.rebuild()
            let result = try String(contentsOf: local, encoding: .utf8)
            #expect(result.contains("model = \"selected\""))
            #expect(result.contains("model_reasoning_effort = \"high\""))
            #expect(result.contains("hooks = false"))
            #expect(try String(contentsOf: config, encoding: .utf8) == updated)
            #expect(!FileManager.default.fileExists(atPath: source.appendingPathComponent(".graftty-model-defaults.json").path))
        }
        // A deliberate change to the durable defaults takes precedence.
        try "model = \"external\"\nmodel_reasoning_effort = \"low\"\n".write(to: config, atomically: true, encoding: .utf8)
        try mirror.rebuild()
        let result = try String(contentsOf: local, encoding: .utf8)
        #expect(result.contains("model = \"external\""))
        #expect(result.contains("model_reasoning_effort = \"low\""))
    }

    @Test("A /model choice can clear reasoning effort without restoring the prior default.")
    func clearedEffortSurvivesRefresh() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source")
        let managed = root.appendingPathComponent("managed")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try "model = \"original\"\nmodel_reasoning_effort = \"high\"\n".write(to: source.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)
        let mirror = CodexHomeMirror(sourceDirectory: source, mirrorDirectory: managed)
        try mirror.rebuild()
        let local = managed.appendingPathComponent("config.toml")
        try "model = \"selected\"\n".write(to: local, atomically: true, encoding: .utf8)
        try mirror.rebuild()
        let result = try String(contentsOf: local, encoding: .utf8)
        #expect(result.contains("model = \"selected\""))
        #expect(!result.contains("model_reasoning_effort"))
    }

    @Test("A corrupt model-defaults baseline falls back to durable config and self-heals.")
    func corruptDefaultsFileSelfHeals() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source")
        let managed = root.appendingPathComponent("managed")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try "model = \"original\"\n".write(to: source.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)
        let mirror = CodexHomeMirror(sourceDirectory: source, mirrorDirectory: managed)
        try mirror.rebuild()
        try "{not valid json".write(to: managed.appendingPathComponent(".graftty-model-defaults.json"), atomically: true, encoding: .utf8)

        try mirror.rebuild()

        let local = managed.appendingPathComponent("config.toml")
        #expect(try String(contentsOf: local, encoding: .utf8) == "model = \"original\"\n")
        try "model = \"selected\"\n".write(to: local, atomically: true, encoding: .utf8)
        try mirror.rebuild()
        #expect(try String(contentsOf: local, encoding: .utf8) == "model = \"selected\"\n")
    }

    @Test("Model preservation keeps durable comments, omits stale managed comments, and handles table-only configs.")
    func preservesDurableCommentsAndLayout() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source")
        let managed = root.appendingPathComponent("managed")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let config = source.appendingPathComponent("config.toml")
        let local = managed.appendingPathComponent("config.toml")
        let mirror = CodexHomeMirror(sourceDirectory: source, mirrorDirectory: managed)

        try "model = \"original\"\nmodel_reasoning_effort = \"medium\"\n\n# Old comment\napproval_policy = \"on-request\"\n"
            .write(to: config, atomically: true, encoding: .utf8)
        try mirror.rebuild()
        try "model = \"selected\"\nmodel_reasoning_effort = \"high\"\n\n# Old comment\napproval_policy = \"on-request\"\n"
            .write(to: local, atomically: true, encoding: .utf8)
        try "model = \"original\"\nmodel_reasoning_effort = \"medium\"\n\n# New comment\napproval_policy = \"never\"\n"
            .write(to: config, atomically: true, encoding: .utf8)
        try mirror.rebuild()
        #expect(try String(contentsOf: local, encoding: .utf8)
            == "model = \"selected\"\nmodel_reasoning_effort = \"high\"\n\n# New comment\napproval_policy = \"never\"\n")

        // Table-only durable config should not gain a leading blank line.
        try "[features]\nhooks = false\n".write(to: config, atomically: true, encoding: .utf8)
        try mirror.rebuild()
        try "model = \"selected\"\n\n[features]\nhooks = false\n".write(to: local, atomically: true, encoding: .utf8)
        try mirror.rebuild()
        #expect(try String(contentsOf: local, encoding: .utf8) == "model = \"selected\"\n\n[features]\nhooks = false\n")
    }

    @Test("CRLF, quote-style equivalence, multiline durable model edits, and effort-only choices are handled accurately.")
    func handlesTOMLEdgeCasesAndEffortOnlyChoices() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source")
        let managed = root.appendingPathComponent("managed")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let config = source.appendingPathComponent("config.toml")
        let local = managed.appendingPathComponent("config.toml")
        let mirror = CodexHomeMirror(sourceDirectory: source, mirrorDirectory: managed)

        // CRLF + quote style equivalence should not discard a /model choice.
        try "model = \"original\"\r\n".write(to: config, atomically: true, encoding: .utf8)
        try mirror.rebuild()
        try "model = \"selected\"\n".write(to: local, atomically: true, encoding: .utf8)
        try "model = 'original' # reformatted\n".write(to: config, atomically: true, encoding: .utf8)
        try mirror.rebuild()
        #expect(try String(contentsOf: local, encoding: .utf8) == "model = \"selected\"\n")

        // Editing a multiline durable model must be detected as a durable change.
        try "model = \"\"\"\noriginal\"\"\"\n".write(to: config, atomically: true, encoding: .utf8)
        try mirror.rebuild()
        try "model = \"selected\"\n".write(to: local, atomically: true, encoding: .utf8)
        try "model = \"\"\"\nexternal\"\"\"\n".write(to: config, atomically: true, encoding: .utf8)
        try mirror.rebuild()
        #expect(try String(contentsOf: local, encoding: .utf8) == "model = \"\"\"\nexternal\"\"\"\n")

        // Effort-only choice without a model key survives refresh.
        try "model_reasoning_effort = \"medium\"\n".write(to: config, atomically: true, encoding: .utf8)
        try mirror.rebuild()
        try "model_reasoning_effort = \"high\"\n".write(to: local, atomically: true, encoding: .utf8)
        try mirror.rebuild()
        #expect(try String(contentsOf: local, encoding: .utf8) == "model_reasoning_effort = \"high\"\n")
    }
}
