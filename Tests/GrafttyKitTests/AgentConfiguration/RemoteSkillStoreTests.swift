import Foundation
import Testing
@testable import GrafttyKit

@Suite("Remote skill installation")
struct RemoteSkillStoreTests {
    @Test("@spec REMOTE-28.9: When staging a remote skill snapshot, the application shall validate all content before publishing a complete revision isolated by parent, project, and runtime, retaining earlier revisions for running agents.")
    func stageAndRefreshWithoutMutatingExistingRevision() throws {
        let fixture = try SkillFixture()
        defer { fixture.remove() }
        try fixture.write("home/.agents/skills/one/SKILL.md", "old")
        try fixture.write("project/.agents/skills/local/SKILL.md", "project")
        let store = RemoteSkillStore(directory: fixture.root.appendingPathComponent("installed"))
        let first = try store.stage(fixture.capture(), parentID: "parent-a", projectID: "repo-a")
        #expect(try String(contentsOf: first.userDirectory.appendingPathComponent(".agents/skills/one/SKILL.md"), encoding: .utf8) == "old")
        #expect(try String(contentsOf: first.projectDirectory.appendingPathComponent(".agents/skills/local/SKILL.md"), encoding: .utf8) == "project")
        #expect(try store.stage(fixture.capture(), parentID: "parent-a", projectID: "repo-a") == first)
        try fixture.write("home/.agents/skills/one/SKILL.md", "new")
        let next = try store.stage(fixture.capture(), parentID: "parent-a", projectID: "repo-a")
        #expect(first.revision != next.revision)
        #expect(try String(contentsOf: first.userDirectory.appendingPathComponent(".agents/skills/one/SKILL.md"), encoding: .utf8) == "old")
        #expect(try String(contentsOf: next.userDirectory.appendingPathComponent(".agents/skills/one/SKILL.md"), encoding: .utf8) == "new")
        let otherParent = try store.stage(fixture.capture(), parentID: "parent-b", projectID: "repo-a")
        let otherProject = try store.stage(fixture.capture(), parentID: "parent-a", projectID: "repo-b")
        #expect(otherParent.directory != next.directory)
        #expect(otherProject.directory != next.directory)
        let empty = try store.stage(.init(runtime: .codex, files: []), parentID: "parent-a", projectID: "repo-a")
        #expect(try FileManager.default.contentsOfDirectory(atPath: empty.userDirectory.path).isEmpty)
        #expect(FileManager.default.fileExists(atPath: next.userDirectory.appendingPathComponent(".agents/skills/one/SKILL.md").path))
    }

    @Test func invalidSnapshotDoesNotCreateDestination() throws {
        let fixture = try SkillFixture()
        defer { fixture.remove() }
        let store = RemoteSkillStore(directory: fixture.root.appendingPathComponent("installed"))
        let bad = RemoteSkillSnapshot(runtime: .codex, files: [.init(scope: .user, path: "../../escape", contents: Data())])
        #expect(throws: RemoteSkillError.self) { try store.stage(bad, parentID: "parent", projectID: "project") }
        #expect(!FileManager.default.fileExists(atPath: store.directory.path))
    }

    @Test func interruptedStageLeavesNoPublishedRevisionAndRetryWorks() throws {
        let fixture = try SkillFixture()
        defer { fixture.remove() }
        try fixture.write("home/.agents/skills/one/SKILL.md", "skill")
        let snapshot = try fixture.capture()
        let store = RemoteSkillStore(directory: fixture.root.appendingPathComponent("installed"))
        #expect(throws: CancellationError.self) {
            try store.stage(snapshot, parentID: "parent", projectID: "project", beforePublish: { throw CancellationError() })
        }
        let entries = try #require(FileManager.default.enumerator(atPath: store.directory.path)).allObjects as! [String]
        #expect(!entries.contains { $0.contains(".staging-") || $0.hasSuffix("SKILL.md") })
        let result = try store.stage(snapshot, parentID: "parent", projectID: "project")
        #expect(FileManager.default.fileExists(atPath: result.userDirectory.appendingPathComponent(".agents/skills/one/SKILL.md").path))
    }

    @Test func unexpectedFileInPublishedRevisionIsRejected() throws {
        let fixture = try SkillFixture()
        defer { fixture.remove() }
        let snapshot = RemoteSkillSnapshot(runtime: .claude, files: [])
        let store = RemoteSkillStore(directory: fixture.root.appendingPathComponent("installed"))
        let result = try store.stage(snapshot, parentID: "parent", projectID: "project")
        try Data("unexpected".utf8).write(to: result.userDirectory.appendingPathComponent("extra"))
        #expect(throws: RemoteSkillError.self) { try store.stage(snapshot, parentID: "parent", projectID: "project") }
    }

    @Test func changedExistingRevisionIsRejectedRatherThanOverwritten() throws {
        let fixture = try SkillFixture()
        defer { fixture.remove() }
        try fixture.write("home/.agents/skills/one/SKILL.md", "old")
        let snapshot = try fixture.capture()
        let store = RemoteSkillStore(directory: fixture.root.appendingPathComponent("installed"))
        let installed = try store.stage(snapshot, parentID: "parent", projectID: "project")
        let file = installed.userDirectory.appendingPathComponent(".agents/skills/one/SKILL.md")
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        try Data("changed".utf8).write(to: file)
        #expect(throws: RemoteSkillError.self) { try store.stage(snapshot, parentID: "parent", projectID: "project") }
        #expect(try String(contentsOf: file, encoding: .utf8) == "changed")
    }

    @Test func storeRejectsSymlinkAndKeepsUnrelatedFiles() throws {
        let fixture = try SkillFixture()
        defer { fixture.remove() }
        try fixture.write("outside/keep", "unrelated")
        let link = fixture.root.appendingPathComponent("installed")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: fixture.root.appendingPathComponent("outside"))
        let store = RemoteSkillStore(directory: link)
        #expect(throws: RemoteSkillError.self) { try store.stage(.init(runtime: .claude, files: []), parentID: "parent", projectID: "project") }
        #expect(try String(contentsOf: fixture.root.appendingPathComponent("outside/keep"), encoding: .utf8) == "unrelated")
    }
}
