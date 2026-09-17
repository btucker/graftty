import Foundation
import GrafttyProtocol
import Testing
@testable import Graftty
@testable import GrafttyKit

@Suite("Remote CLI worktree creation")
@MainActor
struct RemoteCLIWorktreeTests {
    private func creation(project: String? = nil) -> RemoteWorktreeCreation {
        RemoteWorktreeCreation(callerWorktree: "/local/.worktrees/task", project: project,
            worktreeName: "fix", branchName: "fix", existing: false, base: "HEAD",
            command: "codex", agentRuntime: .codex, agentPrompt: "fix tests", operationID: "op-1")
    }

    @Test("@spec AGENT-5.11: When remote worktree creation omits a project, the application shall match the caller's Git origin on the destination regardless of project names or checkout paths, treating equivalent SSH and HTTPS origins as the same repository; an explicit project shall match an exact destination name or absolute repository path, and missing or ambiguous matches shall fail before mutation.")
    func resolvesDestinationProject() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        func repo(_ name: String, label: String, origin: String) async throws -> RepoEntry {
            let path = root.appendingPathComponent(name).path
            try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
            _ = try await GitRunner.run(args: ["init", "--quiet"], at: path)
            _ = try await GitRunner.run(args: ["remote", "add", "origin", origin], at: path)
            return RepoEntry(path: path, displayName: label, worktrees: [
                WorktreeEntry(path: path, branch: "main", state: .closed)
            ])
        }
        let local = try await repo("local", label: "local-label", origin: "git@github.com:team/app.git")
        let remote = try await repo("remote", label: "different-label", origin: "https://github.com/team/app")
        let wrong = try await repo("wrong", label: "local-label", origin: "https://github.com/someone-else/app.git")
        var options = creation()
        options.callerWorktree = local.path
        let resolved = try await options.resolvingSourceProject(in: [local])
        #expect(try JSONDecoder().decode(RemoteWorktreeCreation.self, from: JSONEncoder().encode(resolved)) == resolved)
        #expect(try await resolved.destinationRepository(in: [wrong, remote]).path == remote.path)
        let duplicate = try await repo("duplicate", label: "third-label", origin: "ssh://git@github.com/team/app.git")
        await #expect(throws: (any Error).self) { try await resolved.destinationRepository(in: [remote, duplicate]) }
        await #expect(throws: (any Error).self) { try await resolved.destinationRepository(in: [wrong]) }
        await #expect(throws: (any Error).self) { try await options.resolvingSourceProject(in: []) }
        _ = try await GitRunner.run(args: ["remote", "remove", "origin"], at: local.path)
        await #expect(throws: (any Error).self) { try await options.resolvingSourceProject(in: [local]) }
        let explicit = try await creation(project: duplicate.path).resolvingSourceProject(in: [])
        #expect(try await explicit.destinationRepository(in: [remote, duplicate]).path == duplicate.path)
        #expect(try await creation(project: remote.displayName).destinationRepository(in: [remote]).path == remote.path)
    }

    @Test("@spec AGENT-5.12: When a CLI requests a worktree on a connected Mac, the application shall route creation and status over either an outgoing or incoming authenticated connection, preserve the operation ID across retries, and return a device-qualified message address.", arguments: [false, true])
    func routesBothDirections(viewer: Bool) async throws {
        let router = RemoteTeamRouter()
        let device = RemoteDeviceID(value: "destination")
        let request = creation(project: "app")
        router.register(deviceID: device, connectionID: UUID(), label: "Other Mac",
            closeForReconnect: viewer ? { @Sendable in } : nil) { data in
            guard case .worktree(let request) = try JSONDecoder().decode(RemoteTeamRequest.self, from: data) else {
                Issue.record("Expected worktree request")
                return try JSONEncoder().encode(RemoteTeamResponse.error("wrong request"))
            }
            if case .create(let options) = request {
                #expect(options.project == "app")
                #expect(options.agentPrompt == "fix tests")
                #expect(options.base == "HEAD")
            }
            return try JSONEncoder().encode(RemoteTeamResponse.worktreeCreate(.init(
                operationID: request.operationID, state: .ready,
                worktreePath: "/remote/.worktrees/fix", messageAddress: "/remote/.worktrees/fix")))
        }
        for operation in [RemoteWorktreeRequest.create(request), .status(operationID: request.operationID)] {
            let response = await router.worktree(target: viewer ? device.value : "Other Mac", request: operation, repos: [])
            guard case .worktreeCreate(let status) = response else { Issue.record("Expected creation status"); return }
            #expect(status.operationID == "op-1")
            #expect(RemoteTeamAddress(rawValue: status.messageAddress)?.deviceID == device)
            #expect(RemoteTeamAddress(rawValue: status.messageAddress)?.worktreePath == status.worktreePath)
        }
    }

    @Test("@spec AGENT-5.14: When an authenticated peer creates or polls a worktree, the destination shall scope its operation ID to that peer, stage launch inputs through local creation, and return retained pending, ready, or failed results without repeating the mutation.")
    func destinationDeduplicatesAndScopesOperations() async throws {
        let store = CLIWorktreeCreationStore()
        let options = creation(project: "app")
        let peer = RemoteDeviceID(value: "source")
        let repos = [RepoEntry(path: "/destination", displayName: "app")]
        var creations = 0
        var scopedID = ""
        let create: (NotificationMessage) -> ResponseMessage = { request in
            creations += 1
            guard case let .createWorktree(caller, name, branch, existing, base, command, runtime, prompt, id) = request,
                  let id else { return .error("Wrong request") }
            scopedID = id
            #expect(caller == "/destination")
            #expect(name == "fix" && branch == "fix" && !existing)
            #expect(base == "HEAD" && command == "codex" && runtime == .codex)
            #expect(prompt == "fix tests")
            return .worktreeCreate(store.begin(worktreePath: "/destination/.worktrees/fix",
                messageAddress: "/destination/.worktrees/fix", operationID: id))
        }
        let lookup: (String) -> WorktreeCreateStatus? = { store.status(operationID: $0) }
        for _ in 0..<2 {
            let result = await RemoteCLIWorktreeService.handle(.create(options), from: peer, repos: repos, status: lookup, create: create)
            guard case .worktreeCreate(let status) = result else { Issue.record("Expected pending result"); return }
            #expect(status.operationID == options.operationID && status.state == .pending)
        }
        #expect(creations == 1)
        store.markReady(operationID: scopedID)
        let result = await RemoteCLIWorktreeService.handle(.status(operationID: options.operationID),
            from: peer, repos: [], status: lookup, create: create)
        guard case .worktreeCreate(let ready) = result else { Issue.record("Expected ready result"); return }
        #expect(ready.state == .ready)
        let stranger = await RemoteCLIWorktreeService.handle(.status(operationID: options.operationID),
            from: RemoteDeviceID(value: "other"), repos: repos, status: lookup, create: create)
        guard case .error = stranger else { Issue.record("Another peer accessed operation"); return }
        store.markFailed(operationID: scopedID, error: "shell failed")
        let failed = await RemoteCLIWorktreeService.handle(.create(options), from: peer, repos: [], status: lookup, create: create)
        guard case .worktreeCreate(let status) = failed else { Issue.record("Expected retained failure"); return }
        #expect(status.state == .failed && status.error == "shell failed")
        #expect(creations == 1)
    }

    @Test("Overlapping retries during origin lookup create only one worktree")
    func concurrentOriginResolutionIsIdempotent() async throws {
        let gate = OriginReadGate()
        let store = CLIWorktreeCreationStore()
        var options = creation()
        options.origin = GitRepositoryOrigin.parse("https://example.com/team/repo.git")
        let peer = RemoteDeviceID(value: "source")
        let repos = [RepoEntry(path: "/destination", displayName: "unrelated label")]
        var creations = 0
        let create: (NotificationMessage) -> ResponseMessage = { message in
            creations += 1
            guard case .createWorktree(_, _, _, _, _, _, _, _, let id) = message else { return .error("Wrong request") }
            return .worktreeCreate(store.begin(worktreePath: "/destination/.worktrees/fix",
                messageAddress: "/destination/.worktrees/fix", operationID: id))
        }
        let operation = RemoteWorktreeRequest.create(options)
        let first = Task { @MainActor in
            await RemoteCLIWorktreeService.handle(operation, from: peer, repos: repos,
                status: { store.status(operationID: $0) }, create: create, readOrigin: { _ in await gate.read() })
        }
        let second = Task { @MainActor in
            await RemoteCLIWorktreeService.handle(operation, from: peer, repos: repos,
                status: { store.status(operationID: $0) }, create: create, readOrigin: { _ in await gate.read() })
        }
        let firstResult = await first.value
        let secondResult = await second.value
        #expect(firstResult == secondResult)
        #expect(creations == 1)
    }

    @Test("Unreadable origins fail closed instead of hiding a possible duplicate")
    func unreadableOriginDoesNotMutate() async throws {
        var options = creation()
        options.origin = GitRepositoryOrigin.parse("https://example.com/team/repo.git")
        let response = await RemoteCLIWorktreeService.handle(.create(options),
            from: RemoteDeviceID(value: "source"),
            repos: [RepoEntry(path: "/broken", displayName: "other")],
            status: { _ in nil }, create: { _ in
                Issue.record("Creation invoked after origin read failure")
                return .ok
            }, readOrigin: { _ in throw RemoteWorktreeError("Origin unreadable") })
        #expect(response == .error("Origin unreadable"))
    }

    @Test("Missing destination projects fail before invoking local creation")
    func missingProjectDoesNotMutate() async {
        let response = await RemoteCLIWorktreeService.handle(.create(creation(project: "missing")),
            from: RemoteDeviceID(value: "source"), repos: [], status: { _ in nil }, create: { _ in
                Issue.record("Creation invoked for unknown project")
                return .ok
            })
        guard case .error = response else { Issue.record("Missing project succeeded"); return }
    }

    @Test("@spec AGENT-5.13: If a remote worktree request has an unknown or ambiguous Mac target, then the application shall reject it; once dispatched, retries shall remain pinned to that device even if its label is reused.")
    func targetSelectionAndRetryPinning() async throws {
        let router = RemoteTeamRouter()
        let request = RemoteWorktreeRequest.create(creation(project: "app"))
        guard case .error = await router.worktree(target: "missing", request: request, repos: []) else {
            Issue.record("Missing target accepted"); return
        }
        let first = RemoteDeviceID(value: "first")
        let connection = UUID()
        router.register(deviceID: first, connectionID: connection, label: "Mac") { _ in throw URLError(.networkConnectionLost) }
        guard case .error(let message) = await router.worktree(target: "Mac", request: request, repos: []) else {
            Issue.record("Lost acknowledgement accepted"); return
        }
        #expect(message.contains("may still finish"))
        router.unregister(deviceID: first, connectionID: connection)
        router.register(deviceID: RemoteDeviceID(value: "second"), connectionID: UUID(), label: "Mac") { _ in
            Issue.record("Retried on a different Mac")
            return try JSONEncoder().encode(RemoteTeamResponse.ok)
        }
        guard case .error = await router.worktree(target: "Mac", request: request, repos: []) else {
            Issue.record("Disconnected pinned target accepted"); return
        }
        router.register(deviceID: first, connectionID: connection, label: "Mac") { _ in
            Issue.record("Ambiguous target dispatched")
            return try JSONEncoder().encode(RemoteTeamResponse.ok)
        }
        guard case .error(let ambiguous) = await router.worktree(target: "Mac", request: .status(operationID: "new"), repos: []) else {
            Issue.record("Ambiguous target accepted"); return
        }
        #expect(ambiguous.contains("Ambiguous"))
    }
}

private actor OriginReadGate {
    private var first: CheckedContinuation<Void, Never>?
    private var reads = 0

    func read() async -> GitRepositoryOrigin? {
        reads += 1
        if reads == 1 {
            await withCheckedContinuation { first = $0 }
        } else {
            first?.resume()
            first = nil
        }
        return GitRepositoryOrigin.parse("https://example.com/team/repo.git")
    }
}
