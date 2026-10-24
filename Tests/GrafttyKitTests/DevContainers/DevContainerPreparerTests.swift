import Foundation
import Testing
@testable import GrafttyKit

private actor DevContainerExecutorFake: CLIExecutor {
    struct Call: Sendable { let command: String; let args: [String]; let directory: String }
    var calls: [Call] = []
    let failingStage: String?
    let malformed: Bool
    let compose: Bool
    let supportsRelative: Bool
    let lateFailure: Bool
    init(failingStage: String? = nil, malformed: Bool = false, compose: Bool = false, supportsRelative: Bool = true, lateFailure: Bool = false) {
        self.failingStage = failingStage; self.malformed = malformed; self.compose = compose
        self.supportsRelative = supportsRelative; self.lateFailure = lateFailure
    }
    func run(command: String, args: [String], at directory: String) async throws -> CLIOutput {
        calls.append(.init(command: command, args: args, directory: directory))
        if args.first == failingStage { throw CLIError.nonZeroExit(command: command, exitCode: 1, stderr: "failed stage") }
        let value: String
        if args.contains("--help") { value = supportsRelative ? "--mount-git-worktree-common-dir" : "old CLI help" }
        else if args.first == "read-configuration" { value = compose ? #"{"configuration":{"dockerComposeFile":"compose.yaml"}}"# : #"{"configuration":{"image":"project:test"}}"# }
        else if args.first == "up" { value = malformed ? #"{"outcome":"success"}"# : #"{"outcome":"success","containerId":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","remoteUser":"dev","remoteWorkspaceFolder":"/workspaces/project"}"# }
        else { value = "" }
        return CLIOutput(stdout: value, stderr: "", exitCode: lateFailure && args.first == "up" ? 1 : 0)
    }
    func capture(command: String, args: [String], at directory: String) async throws -> CLIOutput {
        try await run(command: command, args: args, at: directory)
    }
}

struct DevContainerPreparerTests {
    private func workspace() throws -> URL {
        let root = URL.temporaryDirectory.appendingPathComponent("devcontainer-\(UUID())")
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".devcontainer"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".git"), withIntermediateDirectories: true)
        try Data("{ // JSONC stays the CLI's job\n\"image\":\"project:test\"\n}".utf8).write(to: root.appendingPathComponent(".devcontainer/devcontainer.json"))
        return root
    }

    @Test("@spec REMOTE-25.1: When preparing a remote project environment, the application shall use its selected Dev Container configuration through the existing Dev Container CLI.")
    func preparesSelectedConfigurationAndChecksGitBeforeReportingPrepared() async throws {
        let root = try workspace(); defer { try? FileManager.default.removeItem(at: root) }
        let executor = DevContainerExecutorFake()
        let operation = UUID()
        let result = try await DevContainerPreparer(executor: executor).prepare(workspace: root.path,
            configuration: ".devcontainer/devcontainer.json", operationID: operation)
        #expect(result.containerID == "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
        #expect(result.remoteWorkspaceFolder == "/workspaces/project")
        #expect(result.agentReady == false)
        let calls = await executor.calls
        #expect(calls.allSatisfy { $0.command == "devcontainer" })
        #expect(calls.map { $0.args.first } == ["read-configuration", "up", "exec"])
        let up = try #require(calls.first { $0.args.first == "up" })
        #expect(up.args.contains("graftty.placement=\(operation.uuidString.lowercased())"))
        #expect(up.args.contains("--config"))
        #expect(!up.args.contains("--mount"))
        #expect(!up.args.contains("--skip-post-create"))
        let check = try #require(calls.last)
        #expect(check.args.contains("--container-id") && check.args.contains("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"))
        #expect(check.args.suffix(3) == ["git", "status", "--porcelain"])
    }

    @Test(arguments: ["read-configuration", "up", "exec"])
    func failingStageNeverReportsPrepared(stage: String) async throws {
        let root = try workspace(); defer { try? FileManager.default.removeItem(at: root) }
        let executor = DevContainerExecutorFake(failingStage: stage)
        await #expect(throws: (any Error).self) {
            try await DevContainerPreparer(executor: executor).prepare(workspace: root.path, operationID: UUID())
        }
        #expect(await executor.calls.last?.args.first == stage)
    }

    @Test func malformedSuccessAndUnsupportedComposeDoNotStartShell() async throws {
        let root = try workspace(); defer { try? FileManager.default.removeItem(at: root) }
        for executor in [DevContainerExecutorFake(malformed: true), DevContainerExecutorFake(compose: true)] {
            await #expect(throws: (any Error).self) {
                try await DevContainerPreparer(executor: executor).prepare(workspace: root.path, operationID: UUID())
            }
            #expect(await !executor.calls.contains { $0.args.first == "exec" })
        }
    }

    @Test("@spec REMOTE-26.29: When preparing or reopening a relative Git worktree in a Dev Container, the application shall enable both upstream Git-root and common-directory mounting so Git metadata remains reachable inside the container.")
    func relativeWorktreeRequiresUpstreamSupportForEachCommand() async throws {
        let root = try workspace(); defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.removeItem(at: root.appendingPathComponent(".git"))
        try Data("gitdir: ../../.git/worktrees/task\n".utf8).write(to: root.appendingPathComponent(".git"))
        let executor = DevContainerExecutorFake()
        let result = try await DevContainerPreparer(executor: executor).prepare(workspace: root.path, operationID: UUID())
        #expect(result.usesRelativeGitWorktree)
        let calls = await executor.calls
        #expect(calls.filter { $0.args.contains("--help") }.count == 3)
        #expect(calls.filter { !$0.args.contains("--help") }.allSatisfy { $0.args.contains("--mount-git-worktree-common-dir") })
        for call in calls where !call.args.contains("--help") {
            let index = try #require(call.args.firstIndex(of: "--mount-workspace-git-root"))
            #expect(call.args[index + 1] == "true")
        }
        let shell = DevContainerPreparer.shellCommand(for: result)
        #expect(shell.contains("'--mount-workspace-git-root' 'true'"))
        #expect(shell.contains("'--mount-git-worktree-common-dir' 'true'"))
        let old = DevContainerExecutorFake(supportsRelative: false)
        await #expect(throws: (any Error).self) { try await DevContainerPreparer(executor: old).prepare(workspace: root.path, operationID: UUID()) }
        #expect(await old.calls.count == 1)
    }

    @Test func successJSONBeforeNonzeroExitDoesNotPassLifecycle() async throws {
        let root = try workspace(); defer { try? FileManager.default.removeItem(at: root) }
        let executor = DevContainerExecutorFake(lateFailure: true)
        do {
            _ = try await DevContainerPreparer(executor: executor).prepare(workspace: root.path, operationID: UUID())
            Issue.record("Reported success after failed lifecycle")
        } catch let error as DevContainerPreparationError { #expect(error.stage == "lifecycle") }
        #expect(await !executor.calls.contains { $0.args.first == "exec" })
    }

    @Test func symlinkedConfigurationOutsideWorktreeIsRejected() async throws {
        let root = try workspace(); defer { try? FileManager.default.removeItem(at: root) }
        let outside = try workspace(); defer { try? FileManager.default.removeItem(at: outside) }
        let path = root.appendingPathComponent(".devcontainer/devcontainer.json")
        try FileManager.default.removeItem(at: path)
        try FileManager.default.createSymbolicLink(at: path, withDestinationURL: outside.appendingPathComponent(".devcontainer/devcontainer.json"))
        let executor = DevContainerExecutorFake()
        await #expect(throws: (any Error).self) { try await DevContainerPreparer(executor: executor).prepare(workspace: root.path, operationID: UUID()) }
        #expect(await executor.calls.isEmpty)
    }

    @Test func absoluteLinkedMetadataAndEscapingConfigurationFailBeforeCLI() async throws {
        let root = try workspace(); defer { try? FileManager.default.removeItem(at: root) }
        let executor = DevContainerExecutorFake()
        try FileManager.default.removeItem(at: root.appendingPathComponent(".git"))
        try Data("gitdir: /some/repo/.git/worktrees/task\n".utf8).write(to: root.appendingPathComponent(".git"))
        await #expect(throws: (any Error).self) { try await DevContainerPreparer(executor: executor).prepare(workspace: root.path, operationID: UUID()) }
        await #expect(throws: (any Error).self) { try await DevContainerPreparer(executor: executor).prepare(workspace: root.path, configuration: "../outside.json", operationID: UUID()) }
        #expect(await executor.calls.isEmpty)
    }
}
