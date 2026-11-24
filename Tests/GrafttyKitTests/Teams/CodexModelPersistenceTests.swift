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
}
