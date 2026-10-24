import Foundation
import Testing
@testable import GrafttyKit
import GrafttyProtocol

// `graftty worktree add` / `worktree remove` on the headless host. These run
// the request path the Mac app shares (`ControlRequestCore`), against real
// Git repositories and a fake zmx driver.

@MainActor
private final class LifecycleTerminals: HostTerminalDriver {
    var live: Set<String> = []
    var starts: [ZmxSpawnConfiguration] = []
    var killed: [String] = []
    func sessions() async throws -> Set<String> { live }
    func start(_ configuration: ZmxSpawnConfiguration) async throws {
        starts.append(configuration)
        live.insert(configuration.sessionName)
    }
    func kill(_ session: String) async throws { killed.append(session); live.remove(session) }
    func send(_ text: String, to session: String) async throws {}
    func show(_ session: String, lines: Int) async throws -> String { "" }
    func detachAll() {}
}

@Suite @MainActor
struct HeadlessWorktreeLifecycleTests {
    private struct Host {
        let root: URL
        let runtime: HeadlessHostRuntime
        let terminals: LifecycleTerminals
        var repo: String { root.path }
    }

    /// A registered repository with one commit on `main`.
    private func host() async throws -> Host {
        let raw = URL(fileURLWithPath: "/tmp", isDirectory: true).appendingPathComponent("ghw-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: raw, withIntermediateDirectories: true)
        let root = URL(fileURLWithPath: CanonicalPath.canonicalize(raw.path), isDirectory: true)
        try await git(["init", "--initial-branch=main"], at: root.path)
        try await commit("initial", at: root.path)
        let configuration = HostConfiguration(stateDirectory: root.appendingPathComponent(".state"),
            runtimeDirectory: root.appendingPathComponent(".run"), zmxExecutable: URL(fileURLWithPath: "/bin/true"))
        let terminals = LifecycleTerminals()
        let runtime = try HeadlessHostRuntime(configuration: configuration, terminals: terminals,
            initialState: AppState())
        _ = try await runtime.registerRepository(root.path)
        return Host(root: root, runtime: runtime, terminals: terminals)
    }

    @discardableResult
    private func git(_ args: [String], at path: String) async throws -> String {
        try await GitRunner.run(args: args, at: path)
    }

    private func commit(_ message: String, at path: String) async throws {
        try await git(["-c", "user.name=Host Test", "-c", "user.email=host@example.invalid",
            "-c", "core.hooksPath=/dev/null", "commit", "--allow-empty", "-m", message], at: path)
    }

    private func create(_ host: Host, name: String, branch: String? = nil, existing: Bool = false,
                        base: String? = nil, command: String? = nil, agent: TeamHookRuntime? = nil,
                        prompt: String? = nil, caller: String? = nil) async -> ResponseMessage {
        await host.runtime.handle(.createWorktree(callerWorktree: caller ?? host.repo, worktreeName: name,
            branchName: branch ?? name, existing: existing, base: base, command: command,
            agentRuntime: agent, agentPrompt: prompt, operationID: UUID().uuidString))
    }

    /// Polls a creation until it leaves `.pending` (bounded).
    private func finished(_ host: Host, _ response: ResponseMessage) async throws -> WorktreeCreateStatus {
        guard case .worktreeCreate(var status) = response else {
            Issue.record("creation was not accepted: \(response)")
            throw CancellationError()
        }
        let deadline = ContinuousClock.now + .seconds(20)
        while status.state == .pending, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
            guard case .worktreeCreate(let next) = await host.runtime.handle(.worktreeCreateStatus(operationID: status.operationID)) else {
                Issue.record("creation status was lost")
                throw CancellationError()
            }
            status = next
        }
        return status
    }

    /// Polls a removal until it leaves `.pending` (bounded).
    private func finished(removal response: ResponseMessage, _ host: Host) async throws -> WorktreeRemoveStatus {
        guard case .worktreeRemove(var status) = response else {
            Issue.record("removal was not accepted: \(response)")
            throw CancellationError()
        }
        let deadline = ContinuousClock.now + .seconds(20)
        while status.state == .pending, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
            guard case .worktreeRemove(let next) = await host.runtime.handle(.worktreeRemoveStatus(operationID: status.operationID)) else {
                Issue.record("removal status was lost")
                throw CancellationError()
            }
            status = next
        }
        return status
    }

    private func createdWorktree(_ host: Host, name: String) async throws -> String {
        let status = try await finished(host, await create(host, name: name))
        try #require(status.state == .ready, "\(status.error ?? "creation did not finish")")
        return status.worktreePath
    }

    @Test("@spec REMOTE-22.50: If a headless host receives a worktree creation request from an untracked caller, with an invalid worktree name, with an agent prompt but no agent runtime, or with an obsolete prompt loader, then the application shall reject it with the Mac app's message before acknowledging an operation.")
    func creationAdmissionMatchesTheMac() async throws {
        let host = try await host()
        defer { try? FileManager.default.removeItem(at: host.root) }
        let obsoleteLoader = "_graftty_agent_prompt_file='/tmp/task'; exec codex; /bin/rm -f \"$_graftty_agent_prompt_file\""

        #expect(await create(host, name: "a", caller: "/nowhere") == .error("caller is not inside a tracked worktree"))
        #expect(await create(host, name: "../outside") == .error(try #require(
            WorktreeCreationInput.validationError(worktreeName: "../outside", branchName: "../outside", existing: false, base: nil))))
        #expect(await create(host, name: "b", prompt: "task") == .error("an agent prompt requires an agent runtime"))
        #expect(await create(host, name: "c", command: obsoleteLoader, agent: .codex) == .error(
            "this request uses an obsolete agent prompt loader; use the graftty CLI bundled with the running app and retry"))
        #expect(host.runtime.state.repos[0].worktrees.count == 1)
    }

    @Test("@spec REMOTE-22.51: When a headless host receives a worktree creation request with an explicit base, the application shall resolve the base in the caller's worktree before acknowledging the operation, and shall reject a base that does not resolve.")
    func explicitBaseIsCapturedBeforeAcknowledging() async throws {
        let host = try await host()
        defer { try? FileManager.default.removeItem(at: host.root) }

        guard case .error(let message) = await create(host, name: "unresolved", base: "no-such-ref") else {
            Issue.record("an unresolvable base was acknowledged")
            return
        }
        #expect(message.hasPrefix("could not resolve worktree base:"), "\(message)")
        #expect(host.runtime.state.worktree(forPath: host.repo + "/.worktrees/unresolved") == nil)
    }

    @Test("@spec REMOTE-22.52: When a headless host accepts a worktree creation request, the application shall show a creating row for the destination before acknowledging it, and shall reject a destination that is already tracked or an existing branch that is already checked out.")
    func creationInsertsAPlaceholderAndRejectsCollisions() async throws {
        let host = try await host()
        defer { try? FileManager.default.removeItem(at: host.root) }

        #expect(await create(host, name: "mounted", branch: "main", existing: true)
            == .error("branch is already mounted at " + host.root.lastPathComponent))
        let response = await create(host, name: "feature")
        #expect(host.runtime.state.worktree(forPath: host.repo + "/.worktrees/feature")?.state == .creating)
        #expect(await create(host, name: "feature") == .error("a worktree at that name already exists"))
        let status = try await finished(host, response)
        #expect(status.state == .ready, "\(status.error ?? "")")
        #expect(host.runtime.state.worktree(forPath: status.worktreePath)?.state == .running)
    }

    @Test("@spec REMOTE-22.53: When a headless host creates a new branch without an explicit base, the application shall start it from the branch that origin names as its default rather than from the main checkout's current HEAD, as the Mac app does.")
    func newBranchStartsFromOriginsDefaultBranch() async throws {
        let raw = URL(fileURLWithPath: "/tmp", isDirectory: true).appendingPathComponent("gho-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: raw, withIntermediateDirectories: true)
        let scratch = URL(fileURLWithPath: CanonicalPath.canonicalize(raw.path), isDirectory: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let origin = scratch.appendingPathComponent("origin.git").path
        let clone = scratch.appendingPathComponent("clone").path
        try await git(["init", "--bare", "--initial-branch=main", origin], at: scratch.path)
        try await git(["clone", origin, clone], at: scratch.path)
        try await commit("first", at: clone)
        try await git(["push", "origin", "main"], at: clone)
        let defaultHead = try await git(["rev-parse", "main"], at: clone).trimmingCharacters(in: .whitespacesAndNewlines)
        // The main checkout moves to a topic branch ahead of main.
        try await git(["checkout", "-b", "topic"], at: clone)
        try await commit("topic work", at: clone)
        let configuration = HostConfiguration(stateDirectory: scratch.appendingPathComponent("state"),
            runtimeDirectory: scratch.appendingPathComponent("run"), zmxExecutable: URL(fileURLWithPath: "/bin/true"))
        let terminals = LifecycleTerminals()
        let runtime = try HeadlessHostRuntime(configuration: configuration, terminals: terminals, initialState: AppState())
        _ = try await runtime.registerRepository(clone)
        let host = Host(root: URL(fileURLWithPath: clone), runtime: runtime, terminals: terminals)

        let status = try await finished(host, await create(host, name: "feature"))

        try #require(status.state == .ready, "\(status.error ?? "")")
        #expect(try await git(["rev-parse", "feature"], at: clone).trimmingCharacters(in: .whitespacesAndNewlines) == defaultHead)
    }

    @Test("@spec REMOTE-22.54: If a headless host is polled for a worktree creation or removal that it does not retain, then the application shall answer with the Mac app's unknown-or-expired message, and finished results shall expire after the retention period.")
    func operationResultsExpireLikeTheMac() async throws {
        let host = try await host()
        defer { try? FileManager.default.removeItem(at: host.root) }

        #expect(await host.runtime.handle(.worktreeCreateStatus(operationID: "missing"))
            == .error("unknown or expired worktree creation operation"))
        #expect(await host.runtime.handle(.worktreeRemoveStatus(operationID: "missing"))
            == .error("unknown or expired worktree removal operation"))

        let status = try await finished(host, await create(host, name: "short-lived"))
        try #require(status.state == .ready)
        // The Mac's ten-minute retention, read with an explicit clock.
        let creations = host.runtime.worktreeCreations
        #expect(creations.status(operationID: status.operationID, now: Date().addingTimeInterval(9 * 60)) == status)
        #expect(creations.status(operationID: status.operationID, now: Date().addingTimeInterval(11 * 60)) == nil)
    }

    @Test("@spec REMOTE-22.55: When paired Macs create or poll worktrees on a headless host with the same operation ID, the application shall retain independent operations for each peer and the local CLI, and shall reject a stranger's status poll.")
    func remoteOperationsAreScopedToThePeer() async throws {
        let host = try await host()
        defer { try? FileManager.default.removeItem(at: host.root) }
        let operationID = "shared-id"
        let owner = RemoteDeviceID(value: "mac-a")
        let other = RemoteDeviceID(value: "mac-b")

        func remoteCreation(_ name: String, from device: RemoteDeviceID) async throws -> WorktreeCreateStatus {
            let creation = RemoteWorktreeCreation(callerWorktree: "/elsewhere/project", project: host.repo,
                worktreeName: name, branchName: name, existing: false, base: nil, command: nil,
                agentRuntime: nil, agentPrompt: nil, operationID: operationID)
            let response = await host.runtime.remoteTeam(.worktree(.create(creation)), deviceID: device)
            guard case .worktreeCreate(var status) = response else {
                Issue.record("remote creation was rejected: \(response)")
                throw CancellationError()
            }
            // Finish before removing the fixture, even when an assertion fails.
            let deadline = ContinuousClock.now + .seconds(20)
            while status.state == .pending, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(10))
                let response = await host.runtime.remoteTeam(.worktree(.status(operationID: operationID)), deviceID: device)
                guard case .worktreeCreate(let next) = response else {
                    Issue.record("the owning peer could not poll its operation: \(response)")
                    throw CancellationError()
                }
                status = next
            }
            #expect(status.operationID == operationID)
            #expect(status.state == .ready, "\(status.error ?? "")")
            #expect(status.worktreePath == host.repo + "/.worktrees/" + name)
            return status
        }

        let first = try await remoteCreation("remote-a", from: owner)
        #expect(await host.runtime.remoteTeam(.worktree(.status(operationID: operationID)), deviceID: other)
            == .error("Unknown or expired remote worktree operation"))
        #expect(await host.runtime.handle(.worktreeCreateStatus(operationID: operationID))
            == .error("unknown or expired worktree creation operation"))

        let second = try await remoteCreation("remote-b", from: other)
        #expect(first.worktreePath != second.worktreePath)
        #expect(await host.runtime.remoteTeam(.worktree(.status(operationID: operationID)), deviceID: owner)
            == .worktreeCreate(first))
        #expect(await host.runtime.remoteTeam(.worktree(.status(operationID: operationID)), deviceID: other)
            == .worktreeCreate(second))

        let local = try await finished(host, await host.runtime.handle(.createWorktree(
            callerWorktree: host.repo, worktreeName: "local", branchName: "local", existing: false,
            base: nil, command: nil, agentRuntime: nil, agentPrompt: nil, operationID: operationID)))
        #expect(local.state == .ready)
        #expect(local.worktreePath == host.repo + "/.worktrees/local")
        #expect(host.terminals.starts.count == 3)
    }

    @Test("@spec REMOTE-22.60: If a paired client asks a headless host to delete a worktree that is still being created or removed, then the application shall reject the request and leave the row to the operation that owns it.")
    func pairedDeleteLeavesInFlightRowsAlone() async throws {
        let host = try await host()
        defer { try? FileManager.default.removeItem(at: host.root) }
        // `graftty worktree add` inserts its row at admission, before its Git
        // task takes the worktree lease.
        let path = AppState.linkedWorktreePath(repoPath: host.repo, worktreeName: "admitted")
        _ = host.runtime.state.insertCreatingWorktree(repoPath: host.repo, worktreeName: "admitted",
            branch: .createNew(name: "admitted"))

        let response = await host.runtime.manage(.delete(worktreeID: path, force: false))

        guard case .error = response else {
            Issue.record("an in-flight row was deleted: \(response)")
            return
        }
        #expect(host.runtime.state.worktree(forPath: path)?.state == .creating)
        #expect(try host.runtime.inbox.messages(teamID: TeamLookup.id(forRepoPath: host.repo)).isEmpty)
    }

    @Test("@spec REMOTE-22.61: If a headless host cannot save a new worktree's initial agent task, then the application shall reject the creation and drop its creating row from saved state as well as from the live model.")
    func unsavedInitialTaskLeavesNoSavedRow() async throws {
        let host = try await host()
        defer { try? FileManager.default.removeItem(at: host.root) }
        // A file where the team inbox directory belongs fails the task write.
        let inbox = host.runtime.configuration.stateDirectory.appendingPathComponent("team-inbox")
        try? FileManager.default.removeItem(at: inbox)
        try Data().write(to: inbox)

        let response = await create(host, name: "tasked", agent: .codex, prompt: "Ship it")

        guard case .error(let message) = response else {
            Issue.record("creation was acknowledged without its task: \(response)")
            return
        }
        #expect(message.hasPrefix("could not save initial agent task:"), "\(message)")
        let path = host.repo + "/.worktrees/tasked"
        #expect(host.runtime.state.worktree(forPath: path) == nil)
        #expect(try AppState.load(from: host.runtime.configuration.stateDirectory).worktree(forPath: path) == nil)
    }

    @Test("@spec REMOTE-22.62: When a headless host removes a worktree, the application shall drop the worktree's cached diff statistics, so a worktree created later at the same path starts without them.")
    func removalDropsCachedStatistics() async throws {
        let host = try await host()
        defer { try? FileManager.default.removeItem(at: host.root) }
        let path = try await createdWorktree(host, name: "counted")
        host.runtime.worktreeStats[path] = WorktreeWireStats(ahead: 3, behind: 0, hasUncommittedChanges: true, baseRef: "main")

        let removal = try await finished(removal: await host.runtime.handle(.removeWorktree(worktreePath: path, force: true)), host)

        #expect(removal.state == .removed, "\(removal.error ?? "")")
        #expect(host.runtime.worktreeStats[path] == nil)
    }

    @Test("A paired client's invalid worktree name reports the name rule even when the worktree container exists")
    func pairedCreationValidatesTheNameBeforeTheDestination() async throws {
        let host = try await host()
        defer { try? FileManager.default.removeItem(at: host.root) }
        try FileManager.default.createDirectory(atPath: host.repo + "/.worktrees", withIntermediateDirectories: true)
        let rule = try #require(WorktreeCreationInput.validationError(worktreeName: "", branchName: "empty"))

        do {
            _ = try await host.runtime.createWorktree(repository: host.repo, name: "", branch: "empty")
            Issue.record("an empty worktree name was accepted")
        } catch {
            #expect("\(error)".contains(rule), "\(error)")
        }
    }

    @Test("@spec REMOTE-22.56: When a headless host creates or removes a linked worktree, the application shall send the team's member-joined or member-left event to the main checkout, as the Mac app does.")
    func membershipEventsReachTheMainCheckout() async throws {
        let host = try await host()
        defer { try? FileManager.default.removeItem(at: host.root) }
        let path = try await createdWorktree(host, name: "member")

        let removal = try await finished(removal: await host.runtime.handle(.removeWorktree(worktreePath: path, force: false)), host)

        #expect(removal.state == .removed, "\(removal.error ?? "")")
        let kinds = try host.runtime.inbox.messages(teamID: TeamLookup.id(forRepoPath: host.repo)).map(\.kind)
        #expect(kinds == [TeamChannelEvents.EventType.memberJoined, TeamChannelEvents.EventType.memberLeft], "\(kinds)")
    }

    @Test("@spec REMOTE-22.57: If a headless host receives a worktree removal request for an unknown worktree, the main checkout, a pinned worktree without --pinned, or a worktree whose removal is already pending, then the application shall reject it with the Mac app's message before acknowledging, and shall recheck the pin before Git runs.")
    func removalAdmissionMatchesTheMac() async throws {
        let host = try await host()
        defer { try? FileManager.default.removeItem(at: host.root) }
        let path = try await createdWorktree(host, name: "pinned")

        #expect(await host.runtime.handle(.removeWorktree(worktreePath: "/nowhere", force: false)) == .error("unknown worktree"))
        #expect(await host.runtime.handle(.removeWorktree(worktreePath: host.repo, force: true)) == .error("cannot remove the main checkout"))
        #expect(await host.runtime.handle(.setWorktreePinned(worktreePath: path, isPinned: true)) == .ok)
        #expect(await host.runtime.handle(.removeWorktree(worktreePath: path, force: true)) == .error(
            "worktree is pinned; rerun with --pinned to authorize removal; --force does not bypass pin protection"))
        #expect(await host.runtime.handle(.setWorktreePinned(worktreePath: path, isPinned: false)) == .ok)

        let first = await host.runtime.handle(.removeWorktree(worktreePath: path, force: false))
        #expect(await host.runtime.handle(.removeWorktree(worktreePath: path, force: false)) == .error("worktree removal is already in progress"))
        // Pinned after admission, before the removal task runs.
        let index = try #require(host.runtime.state.indices(forWorktreePath: path))
        host.runtime.state.repos[index.repo].worktrees[index.worktree].isPinned = true
        let status = try await finished(removal: first, host)
        #expect(status.state == .failed)
        #expect(status.error == "worktree is pinned; rerun with --pinned to authorize removal; --force does not bypass pin protection")
        #expect(FileManager.default.fileExists(atPath: path))
    }

    @Test("@spec REMOTE-22.58: If Git refuses to remove a headless worktree because of local changes, then the application shall report Git's message with the worktree's `git status --short` output and allow a forced retry.")
    func forceableRemovalReportsShortStatus() async throws {
        let host = try await host()
        defer { try? FileManager.default.removeItem(at: host.root) }
        let path = try await createdWorktree(host, name: "dirty")
        try "draft".write(toFile: path + "/notes.txt", atomically: true, encoding: .utf8)

        let status = try await finished(removal: await host.runtime.handle(.removeWorktree(worktreePath: path, force: false)), host)

        #expect(status.state == .failed)
        #expect(status.forceAllowed)
        #expect(status.shortStatus == "?? notes.txt")
        #expect(status.error?.contains("notes.txt") == true || status.error?.contains("untracked") == true, "\(status.error ?? "")")
        let forced = try await finished(removal: await host.runtime.handle(.removeWorktree(worktreePath: path, force: true)), host)
        #expect(forced.state == .removed, "\(forced.error ?? "")")
    }

    @Test("@spec REMOTE-22.59: While a headless host removes a worktree, the application shall show it as deleting, and if Git refuses the removal, the application shall restore the worktree's prior state.")
    func removalShowsDeletingThenRestores() async throws {
        let host = try await host()
        defer { try? FileManager.default.removeItem(at: host.root) }
        let path = try await createdWorktree(host, name: "busy")
        try "draft".write(toFile: path + "/notes.txt", atomically: true, encoding: .utf8)

        let response = await host.runtime.handle(.removeWorktree(worktreePath: path, force: false))
        guard case .worktreeRemove(let pending) = response else {
            Issue.record("removal was not accepted: \(response)")
            return
        }
        // Git takes tens of milliseconds to refuse; the row must read
        // `.deleting` while it runs.
        var sawDeleting = false
        let deadline = ContinuousClock.now + .seconds(10)
        while !sawDeleting, ContinuousClock.now < deadline,
              case .worktreeRemove(let current) = await host.runtime.handle(.worktreeRemoveStatus(operationID: pending.operationID)),
              current.state == .pending {
            sawDeleting = host.runtime.state.worktree(forPath: path)?.state == .deleting
            if !sawDeleting { try await Task.sleep(for: .milliseconds(1)) }
        }
        #expect(sawDeleting)
        let status = try await finished(removal: response, host)

        #expect(status.state == .failed)
        #expect(host.runtime.state.worktree(forPath: path)?.state == .running)
    }

    @Test("@spec REMOTE-22.63: If Git refuses a headless worktree creation, then the application shall report Git's message as the operation's error, as the Mac app does.")
    func gitRefusalReportsGitsMessage() async throws {
        let host = try await host()
        defer { try? FileManager.default.removeItem(at: host.root) }

        let status = try await finished(host, await create(host, name: "missing", branch: "no-such-branch", existing: true))

        #expect(status.state == .failed)
        let error = try #require(status.error)
        #expect(error.contains("no-such-branch") && !error.hasPrefix("gitFailed("), "\(error)")
    }

    @Test("@spec REMOTE-22.64: When a paired client creates or deletes a worktree on a headless host, the application shall use the Mac's create-failed, not-found, invalid, and git-failed error codes, and shall include short status only when force can help.")
    func pairedClientFailuresMatchTheMac() async throws {
        let host = try await host()
        defer { try? FileManager.default.removeItem(at: host.root) }

        #expect(await host.runtime.manage(.delete(worktreeID: "/missing", force: false)) == .error(
            code: "not-found", message: "unknown worktree", forceAllowed: false, shortStatus: nil))
        #expect(await host.runtime.manage(.delete(worktreeID: host.repo, force: false)) == .error(
            code: "invalid", message: "cannot delete the main checkout", forceAllowed: false, shortStatus: nil))

        let dirty = try await createdWorktree(host, name: "dirty")
        try "draft".write(toFile: dirty + "/notes.txt", atomically: true, encoding: .utf8)
        let shortStatus = await GitStatusCapture.shortStatus(at: dirty)
        guard case .error(let code, let message, let forceAllowed, let capturedStatus) =
                await host.runtime.manage(.delete(worktreeID: dirty, force: false)) else {
            Issue.record("a dirty worktree was deleted without force")
            return
        }
        #expect(code == "git-failed" && forceAllowed && capturedStatus == shortStatus && message.contains("untracked"))

        // `--force` does not override a lock, so Git refuses again.
        try await git(["worktree", "lock", dirty], at: host.repo)
        guard case .error(let forcedCode, _, let forcedAllowed, let forcedStatus) =
                await host.runtime.manage(.delete(worktreeID: dirty, force: true)) else {
            Issue.record("a locked worktree was deleted")
            return
        }
        #expect(forcedCode == "git-failed" && !forcedAllowed && forcedStatus == nil)
        #expect(host.runtime.state.worktree(forPath: dirty)?.state == .running)

        #expect(await host.runtime.manage(.create(repositoryID: host.repo, worktreeName: "dirty", branchName: "other",
            existingSource: nil)) == .error(code: "create-failed",
            message: "worktree destination already exists or is invalid", forceAllowed: false, shortStatus: nil))
    }

    @Test("A removal whose final save fails is not reported as done")
    func removalSaveFailureIsReported() async throws {
        let host = try await host()
        defer { try? FileManager.default.removeItem(at: host.root) }
        let viaEnvelope = try await createdWorktree(host, name: "envelope")
        let viaCLI = try await createdWorktree(host, name: "cli")
        // A directory where state.json belongs makes every save fail.
        let stateFile = host.runtime.configuration.stateDirectory.appendingPathComponent("state.json")
        try FileManager.default.removeItem(at: stateFile)
        try FileManager.default.createDirectory(at: stateFile.appendingPathComponent("blocked"), withIntermediateDirectories: true)

        guard case .error(let code, _, _, _) = await host.runtime.manage(.delete(worktreeID: viaEnvelope, force: false)) else {
            Issue.record("an unsaved removal was acknowledged")
            return
        }
        #expect(code == "git-failed")

        let status = try await finished(removal: await host.runtime.handle(.removeWorktree(worktreePath: viaCLI, force: false)), host)
        #expect(status.state == .failed)
        #expect(!status.forceAllowed)
    }
}
