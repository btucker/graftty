import Foundation
import Testing
import GrafttyProtocol
@testable import GrafttyKit

/// Runs the exact container installation commands in an isolated local home.
/// Container lifecycle and SSH transport have separate integration tests.
actor SkillContainerExecutor: CLIExecutor {
    let home: URL
    let workspace: URL
    let missingAgent: Bool
    var commands: [[String]] = []
    init(home: URL, workspace: URL, missingAgent: Bool = false) { self.home = home; self.workspace = workspace; self.missingAgent = missingAgent }
    func run(command: String, args: [String], at directory: String) async throws -> CLIOutput {
        commands.append(args)
        if args.contains("--help") { return .init(stdout: "--mount-git-worktree-common-dir", stderr: "", exitCode: 0) }
        if args.first == "read-configuration" { return .init(stdout: #"{"configuration":{"image":"fixture"}}"#, stderr: "", exitCode: 0) }
        if args.first == "up" {
            let data = try JSONSerialization.data(withJSONObject: ["outcome": "success", "containerId": String(repeating: "a", count: 64), "remoteWorkspaceFolder": workspace.path])
            return .init(stdout: String(decoding: data, as: UTF8.self), stderr: "", exitCode: 0)
        }
        if args.suffix(3) == ["git", "status", "--porcelain"] { return .init(stdout: "", stderr: "", exitCode: 0) }
        if args.last?.contains("command -v codex") == true { return .init(stdout: "", stderr: "missing runtime", exitCode: missingAgent ? 127 : 0) }
        guard command == "devcontainer", args.first == "exec", let index = args.firstIndex(of: "/bin/sh") else {
            throw RemoteSkillError("Unexpected command")
        }
        return try await CLIRunner().run(command: "/usr/bin/env", args: ["HOME=" + home.path] + Array(args[index...]), at: workspace.path)
    }
    func capture(command: String, args: [String], at directory: String) async throws -> CLIOutput { try await run(command: command, args: args, at: directory) }
}

struct DevContainerSkillsTests {
    @Test("@spec REMOTE-28.17: When a skill-bearing container placement selects an agent, the application shall require a matching runtime revision, check the agent executable in that container, and launch with the retained isolated skill home without claiming authentication readiness.")
    func preparesProfileAndChecksRuntimeBeforeReturningEnvironment() async throws {
        let fixture = try SkillFixture(); defer { fixture.remove() }
        try fixture.write("home/.agents/skills/personal/SKILL.md", "personal")
        try fixture.write("remote/workspace/.devcontainer/devcontainer.json", #"{"image":"fixture"}"#)
        try fixture.write("remote/home/keep", "unrelated")
        let workspace = fixture.root.appendingPathComponent("remote/workspace")
        try FileManager.default.createDirectory(at: workspace.appendingPathComponent(".git"), withIntermediateDirectories: true)
        let snapshot = try fixture.capture()
        let executor = SkillContainerExecutor(home: fixture.root.appendingPathComponent("remote/home"), workspace: workspace)
        let prepared = try await DevContainerPreparer(executor: executor).prepare(workspace: workspace.path, operationID: UUID(), skills: [snapshot], agent: .codex)
        let profile = try #require(prepared.agentSkillHome)
        #expect(!prepared.agentReady)
        #expect(try String(contentsOfFile: profile + "/.agents/skills/personal/SKILL.md", encoding: .utf8) == "personal")
        let command = DevContainerPreparer.shellCommand(for: prepared, command: "codex")
        #expect(command.contains("HOME=" + profile) && command.contains("CODEX_HOME=" + profile + "/.codex"))
        #expect(command.contains("'codex\nexec /bin/sh'"))
        #expect(try JSONDecoder().decode(PreparedDevContainer.self, from: JSONEncoder().encode(prepared)) == prepared)
        let missing = SkillContainerExecutor(home: fixture.root.appendingPathComponent("remote/home"), workspace: workspace, missingAgent: true)
        await #expect(throws: (any Error).self) {
            try await DevContainerPreparer(executor: missing).prepare(workspace: workspace.path, operationID: UUID(), skills: [snapshot], agent: .codex)
        }
        let mismatched = SkillContainerExecutor(home: fixture.root.appendingPathComponent("remote/home"), workspace: workspace)
        await #expect(throws: (any Error).self) {
            try await DevContainerPreparer(executor: mismatched).prepare(workspace: workspace.path, operationID: UUID(), skills: [snapshot], agent: .claude)
        }
        #expect(await mismatched.commands.isEmpty)
    }

    @Test("@spec REMOTE-28.16: When a Dev Container placement selects verified skill revisions, the application shall install their user skills into an isolated writable agent home and project skills into the container worktree before opening its shell, rejecting conflicting project content without overwriting it.")
    func installsRealScriptsAndPreservesRuntimeOwnedFiles() async throws {
        let fixture = try SkillFixture(); defer { fixture.remove() }
        try fixture.write("home/.agents/skills/personal/SKILL.md", "personal")
        try fixture.write("home/.codex/skills/legacy/SKILL.md", "legacy")
        try fixture.write("project/.agents/skills/local/SKILL.md", "local")
        try fixture.write("project/.agents/skills/local/run.sh", "#!/bin/sh\nprintf 'test'\n", executable: true)
        let payload = "$(touch injected)\n" + String(repeating: "large skill support file\n", count: 15_000)
        try fixture.write("project/.agents/skills/local/quoted ' file.txt", payload)
        let snapshot = try fixture.capture()
        let remote = fixture.root.appendingPathComponent("remote")
        let workspace = remote.appendingPathComponent("workspace")
        let home = remote.appendingPathComponent("home")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let executor = SkillContainerExecutor(home: home, workspace: workspace)
        let profile = try await DevContainerSkillInstaller.install([snapshot], workspace: workspace.path,
            execArguments: ["exec"], operationID: UUID(), executor: executor)
        #expect(try String(contentsOfFile: profile + "/.agents/skills/personal/SKILL.md", encoding: .utf8) == "personal")
        #expect(try String(contentsOf: workspace.appendingPathComponent(".agents/skills/local/SKILL.md"), encoding: .utf8) == "local")
        #expect(FileManager.default.isExecutableFile(atPath: workspace.appendingPathComponent(".agents/skills/local/run.sh").path))
        #expect(try String(contentsOf: workspace.appendingPathComponent(".agents/skills/local/quoted ' file.txt"), encoding: .utf8) == payload)
        #expect(!FileManager.default.fileExists(atPath: workspace.appendingPathComponent("injected").path))
        #expect((try FileManager.default.attributesOfItem(atPath: workspace.appendingPathComponent(".agents/skills/local/run.sh").path)[.posixPermissions] as? NSNumber)?.intValue == 0o755)
        #expect(try FileManager.default.attributesOfItem(atPath: workspace.appendingPathComponent(".agents/skills/local").path)[.type] as? FileAttributeType == .typeDirectory)
        let system = URL(fileURLWithPath: profile).appendingPathComponent(".codex/skills/.system")
        try FileManager.default.createDirectory(at: system, withIntermediateDirectories: true)
        try Data("runtime-owned".utf8).write(to: system.appendingPathComponent("keep"))
        let second = try await DevContainerSkillInstaller.install([snapshot], workspace: workspace.path,
            execArguments: ["exec"], operationID: UUID(), executor: executor)
        #expect(second != profile)
        #expect(FileManager.default.fileExists(atPath: system.appendingPathComponent("keep").path))
        #expect(!FileManager.default.fileExists(atPath: second + "/.codex/skills/.system/keep"))
        #expect(await executor.commands.allSatisfy { $0.reduce(0) { $0 + $1.utf8.count } < 100_000 })
    }

    @Test func conflictsAndSymlinkParentsCannotOverwriteProjectFiles() async throws {
        let fixture = try SkillFixture(); defer { fixture.remove() }
        try fixture.write("home/.claude/skills/personal/SKILL.md", "user")
        try fixture.write("project/.claude/skills/local/SKILL.md", "new")
        let snapshot = try fixture.capture(.claude)
        try fixture.write("remote/workspace/.claude/skills/local/SKILL.md", "existing")
        try fixture.write("remote/home/keep", "unrelated")
        let workspace = fixture.root.appendingPathComponent("remote/workspace")
        let executor = SkillContainerExecutor(home: fixture.root.appendingPathComponent("remote/home"), workspace: workspace)
        await #expect(throws: (any Error).self) {
            try await DevContainerSkillInstaller.install([snapshot], workspace: workspace.path, execArguments: ["exec"], operationID: UUID(), executor: executor)
        }
        #expect(try String(contentsOf: workspace.appendingPathComponent(".claude/skills/local/SKILL.md"), encoding: .utf8) == "existing")
        try FileManager.default.removeItem(at: workspace.appendingPathComponent(".claude"))
        try FileManager.default.createSymbolicLink(at: workspace.appendingPathComponent(".claude"), withDestinationURL: fixture.root.appendingPathComponent("project/.claude"))
        await #expect(throws: (any Error).self) {
            try await DevContainerSkillInstaller.install([snapshot], workspace: workspace.path, execArguments: ["exec"], operationID: UUID(), executor: executor)
        }
        #expect(try String(contentsOf: fixture.root.appendingPathComponent("project/.claude/skills/local/SKILL.md"), encoding: .utf8) == "new")
    }
}
