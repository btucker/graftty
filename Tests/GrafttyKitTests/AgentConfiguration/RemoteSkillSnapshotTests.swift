import Foundation
import Testing
@testable import GrafttyKit
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

@Suite("Remote skill snapshots")
struct RemoteSkillSnapshotTests {
    @Test("@spec REMOTE-28.19: When a runtime home mirrors the user's native skill directory inside their home, the application shall capture that directory through the alias while rejecting project-root escapes and aliases to unrelated directories.")
    func managedRuntimeAliasCanReachOnlyItsNativeUserRoot() throws {
        let fixture = try SkillFixture(); defer { fixture.remove() }
        try fixture.write("home/.codex/skills/personal/SKILL.md", "personal")
        try fixture.write("home/.codex/auth.json", "do not export")
        let managed = fixture.root.appendingPathComponent("managed")
        try FileManager.default.createDirectory(at: managed, withIntermediateDirectories: true)
        let alias = managed.appendingPathComponent("skills")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: fixture.root.appendingPathComponent("home/.codex/skills"))
        func capture() throws -> RemoteSkillSnapshot {
            try RemoteSkillSnapshot.capture(runtime: .codex, home: fixture.root.appendingPathComponent("home"),
                workspace: fixture.root.appendingPathComponent("project"), environment: ["CODEX_HOME": managed.path])
        }
        #expect(try capture().files.map(\.path) == [".codex/skills/personal/SKILL.md"])
        try FileManager.default.createDirectory(at: fixture.root.appendingPathComponent("project/.codex"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: fixture.root.appendingPathComponent("project/.codex/skills"), withDestinationURL: fixture.root.appendingPathComponent("home/.codex/skills"))
        #expect(throws: (any Error).self) { try capture() }
        try FileManager.default.removeItem(at: fixture.root.appendingPathComponent("project/.codex/skills"))
        try FileManager.default.removeItem(at: alias)
        try fixture.write("home/unrelated/personal/SKILL.md", "unrelated")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: fixture.root.appendingPathComponent("home/unrelated"))
        #expect(throws: (any Error).self) { try capture() }
    }

    @Test("@spec REMOTE-28.7: When capturing remote skills, the application shall retain user and project scope, supporting file bytes and executable flags in a deterministic runtime-specific snapshot without exporting the rest of the agent home.")
    func captureScopesAndResources() throws {
        let fixture = try SkillFixture()
        defer { fixture.remove() }
        try fixture.write("home/.agents/skills/shared/SKILL.md", "shared")
        try fixture.write("home/.codex/skills/personal/SKILL.md", "personal")
        try fixture.write("home/.codex/skills/personal/scripts/run.sh", "#!/bin/sh\nexit 0", executable: true)
        try fixture.write("home/.codex/auth.json", "credential sentinel")
        try fixture.write("home/.codex/config.toml", "settings sentinel")
        try fixture.write("home/.claude/skills/other/SKILL.md", "other runtime")
        try fixture.write("project/.agents/skills/local/SKILL.md", "local")
        let snapshot = try fixture.capture()
        #expect(snapshot.files.count == 4)
        #expect(snapshot.files.contains { $0.scope == .project && $0.path == ".agents/skills/local/SKILL.md" })
        #expect(snapshot.files.contains { $0.path.hasSuffix("run.sh") && $0.executable })
        #expect(!snapshot.files.contains { String(decoding: $0.contents, as: UTF8.self).contains("sentinel") })
        #expect(try snapshot.revision == fixture.capture().revision)
        #expect(try RemoteSkillSnapshot.decode(snapshot.encoded()) == snapshot)
        let claude = try fixture.capture(.claude)
        #expect(claude.files.map(\.path) == [".claude/skills/other/SKILL.md"])
    }

    @Test("@spec REMOTE-28.8: When capturing or decoding a remote skill snapshot, the application shall reject escaping links, special files, credential-file paths, duplicate or traversing destinations, and excessive content before installing any files.")
    func unsafeInputRejected() throws {
        let fixture = try SkillFixture()
        defer { fixture.remove() }
        try fixture.write("home/.agents/skills/demo/SKILL.md", "demo")
        try fixture.write("home/.ssh/id_ed25519", "private sentinel")
        let link = fixture.root.appendingPathComponent("home/.agents/skills/demo/key")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: fixture.root.appendingPathComponent("home/.ssh/id_ed25519"))
        #expect(throws: RemoteSkillError.self) { try fixture.capture() }
        try FileManager.default.removeItem(at: link)
        try fixture.write("home/.agents/skills/demo/.env", "secret")
        #expect(throws: RemoteSkillError.self) { try fixture.capture() }
        try FileManager.default.removeItem(at: fixture.root.appendingPathComponent("home/.agents/skills/demo/.env"))
        #expect(throws: RemoteSkillError.self) { try fixture.capture(limits: .init(maxFiles: 1, maxFileBytes: 2, maxTotalBytes: 2)) }
        let invalid = RemoteSkillSnapshot(runtime: .codex, files: [.init(scope: .user, path: "../auth.json", contents: Data())])
        #expect(throws: RemoteSkillError.self) { try invalid.encoded() }
        let file = RemoteSkillSnapshot.File(scope: .user, path: ".agents/skills/a/SKILL.md", contents: Data())
        #expect(throws: RemoteSkillError.self) { try RemoteSkillSnapshot(runtime: .codex, files: [file, file]).encoded() }
    }

    @Test func symlinkedSkillWithinApprovedRootsAndInternalResource() throws {
        let fixture = try SkillFixture()
        defer { fixture.remove() }
        try fixture.write("home/.agents/skills/demo/SKILL.md", "demo")
        try fixture.write("home/.agents/skills/demo/references/a.md", "reference")
        try FileManager.default.createSymbolicLink(at: fixture.root.appendingPathComponent("home/.agents/skills/demo/link.md"), withDestinationURL: fixture.root.appendingPathComponent("home/.agents/skills/demo/references/a.md"))
        try FileManager.default.createDirectory(at: fixture.root.appendingPathComponent("home/.codex/skills"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: fixture.root.appendingPathComponent("home/.codex/skills/demo"), withDestinationURL: fixture.root.appendingPathComponent("home/.agents/skills/demo"))
        let snapshot = try fixture.capture()
        #expect(snapshot.files.count == 6)
        #expect(snapshot.files.filter { $0.path.hasSuffix("link.md") }.allSatisfy { $0.contents == Data("reference".utf8) })
    }

    @Test func rejectsCyclesAndUnrelatedSkillRootLinks() throws {
        let fixture = try SkillFixture()
        defer { fixture.remove() }
        try fixture.write("home/.agents/skills/demo/SKILL.md", "demo")
        let root = fixture.root.appendingPathComponent("home/.agents/skills/demo")
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("cycle"), withDestinationURL: root)
        #expect(throws: RemoteSkillError.self) { try fixture.capture() }
        try FileManager.default.removeItem(at: root.appendingPathComponent("cycle"))
        try fixture.write("elsewhere/private/SKILL.md", "private")
        try FileManager.default.createSymbolicLink(at: fixture.root.appendingPathComponent("home/.agents/skills/private"), withDestinationURL: fixture.root.appendingPathComponent("elsewhere/private"))
        #expect(throws: RemoteSkillError.self) { try fixture.capture() }
    }

    @Test func inputOrderDoesNotChangeRevisionButContentsAndModesDo() throws {
        let a = RemoteSkillSnapshot.File(scope: .user, path: ".agents/skills/a/SKILL.md", contents: Data("a".utf8))
        let b = RemoteSkillSnapshot.File(scope: .project, path: ".agents/skills/b/SKILL.md", contents: Data("b".utf8))
        let first = RemoteSkillSnapshot(runtime: .codex, files: [a, b])
        #expect(try first.revision == RemoteSkillSnapshot(runtime: .codex, files: [b, a]).revision)
        let executable = RemoteSkillSnapshot.File(scope: a.scope, path: a.path, contents: a.contents, executable: true)
        #expect(try first.revision != RemoteSkillSnapshot(runtime: .codex, files: [executable, b]).revision)
    }

    @Test func specialFilesUnknownVersionsAndFileDirectoryConflictsAreRejected() throws {
        let fixture = try SkillFixture()
        defer { fixture.remove() }
        try fixture.write("home/.agents/skills/demo/SKILL.md", "demo")
        let fifo = fixture.root.appendingPathComponent("home/.agents/skills/demo/pipe").path
        #expect(mkfifo(fifo, 0o600) == 0)
        #expect(throws: RemoteSkillError.self) { try fixture.capture() }
        let unknown = Data("{\"version\":2,\"runtime\":\"codex\",\"files\":[]}".utf8)
        #expect(throws: RemoteSkillError.self) { try RemoteSkillSnapshot.decode(unknown) }
        let file = RemoteSkillSnapshot.File(scope: .user, path: ".agents/skills/a/SKILL.md", contents: Data())
        let child = RemoteSkillSnapshot.File(scope: .user, path: ".agents/skills/a/SKILL.md/nested", contents: Data())
        #expect(throws: RemoteSkillError.self) { try RemoteSkillSnapshot(runtime: .codex, files: [file, child]).encoded() }
    }

    @Test func customRuntimeHomeExportsOnlySkillsAndNeverLeaksSourcePaths() throws {
        let fixture = try SkillFixture()
        defer { fixture.remove() }
        try fixture.write("custom/skills/demo/SKILL.md", "demo")
        try fixture.write("custom/auth.json", "secret")
        let snapshot = try RemoteSkillSnapshot.capture(runtime: .codex, home: fixture.root.appendingPathComponent("home"),
            workspace: fixture.root.appendingPathComponent("project"), environment: ["CODEX_HOME": fixture.root.appendingPathComponent("custom").path])
        #expect(snapshot.files.map(\.path) == [".codex/skills/demo/SKILL.md"])
        #expect(!String(decoding: try snapshot.encoded(), as: UTF8.self).contains(fixture.root.path))
    }

    @Test func missingWorkspaceIsNotAnEmptyProject() throws {
        let fixture = try SkillFixture()
        defer { fixture.remove() }
        #expect(throws: RemoteSkillError.self) {
            try RemoteSkillSnapshot.capture(runtime: .codex, home: fixture.root.appendingPathComponent("home"),
                workspace: fixture.root.appendingPathComponent("missing"), environment: [:])
        }
    }
}

struct SkillFixture {
    let root: URL
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("graftty-skills-" + UUID().uuidString)
        for dir in ["home", "project"] { try FileManager.default.createDirectory(at: root.appendingPathComponent(dir), withIntermediateDirectories: true) }
    }
    func remove() { try? FileManager.default.removeItem(at: root) }
    func write(_ path: String, _ contents: String, executable: Bool = false) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: executable ? 0o700 : 0o600], ofItemAtPath: url.path)
    }
    func capture(_ runtime: TeamHookRuntime = .codex, limits: RemoteSkillSnapshot.Limits = .init()) throws -> RemoteSkillSnapshot {
        try RemoteSkillSnapshot.capture(runtime: runtime, home: root.appendingPathComponent("home"), workspace: root.appendingPathComponent("project"), environment: [:], limits: limits)
    }
}
