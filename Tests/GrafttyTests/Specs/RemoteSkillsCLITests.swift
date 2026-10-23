import Foundation
import Testing
@testable import GrafttyCLI
import GrafttyKit

struct RemoteSkillsCLITests {
    @Test("@spec REMOTE-28.10: When exporting or staging remote skills through the CLI, the application shall require explicit source and destination selections, verify the requested revision before staging, and report staged paths without activating an agent or copying authentication stores.")
    func exportStageAndRejectWrongRevision() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("graftty-skill-cli-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let skill = root.appendingPathComponent("home/.claude/skills/demo/SKILL.md")
        try FileManager.default.createDirectory(at: skill.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("project"), withIntermediateDirectories: true)
        try Data("demo".utf8).write(to: skill)
        let archive = root.appendingPathComponent("skills.json")
        var export = try GrafttyCLI.parseAsRoot(["remote", "skills", "export", "--runtime", "claude", "--workspace", root.appendingPathComponent("project").path,
            "--source-home", root.appendingPathComponent("home").path, "--output", archive.path])
        try export.run()
        let data = try Data(contentsOf: archive)
        let snapshot = try RemoteSkillSnapshot.decode(data)
        #expect(snapshot.files.count == 1)
        let arguments = ["remote", "skills", "stage", "--input", archive.path, "--parent-id", "parent", "--project-id", "project", "--directory", root.appendingPathComponent("store").path]
        var wrong = try GrafttyCLI.parseAsRoot(arguments + ["--revision", String(repeating: "0", count: 64)])
        #expect(throws: (any Error).self) { try wrong.run() }
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("store").path))
        var stage = try GrafttyCLI.parseAsRoot(arguments + ["--revision", try snapshot.revision])
        try stage.run()
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("store").path))
        #expect(throws: (any Error).self) { try export.run() }
        #expect(try Data(contentsOf: archive) == data)
    }

    @Test func rejectsMissingSelectionsAndInvalidRuntime() throws {
        #expect(throws: (any Error).self) { _ = try GrafttyCLI.parseAsRoot(["remote", "skills", "export"]) }
        #expect(throws: (any Error).self) {
            _ = try GrafttyCLI.parseAsRoot(["remote", "skills", "export", "--runtime", "other", "--workspace", "/project", "--output", "/snapshot.json"])
        }
        #expect(throws: (any Error).self) { _ = try GrafttyCLI.parseAsRoot(["remote", "skills", "stage", "--input", "/snapshot.json"]) }
    }
}
