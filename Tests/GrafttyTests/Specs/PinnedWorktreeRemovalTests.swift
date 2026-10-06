import Foundation
import GrafttyKit
import SwiftUI
import Testing
@testable import Graftty
@testable import GrafttyCLI

@Suite("@spec AGENT-5.25: When graftty worktree remove targets a pinned linked worktree, the application shall require --pinned independently of --force, validate pin state in the running app before removal, reject the main checkout, and verify pinned-removal protocol support before sending a removal request.")
struct PinnedWorktreeRemovalTests {
    @Test func pinnedFlagReachesRemovalRequestIndependentlyOfForce() throws {
        for arguments in [["role", "--pinned"], ["role", "--pinned", "--force"]] {
            let command = try WorktreeRemove.parse(arguments)
            let request = command.removalRequest(worktreePath: "/repo/.worktrees/role")
            let json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any])
            #expect(json["pinned"] as? Bool == true)
            #expect(json["force"] as? Bool == arguments.contains("--force"))
        }
        #expect(WorktreeRemove.helpMessage().contains("--pinned"))
    }

    @Test func oldRemovalRequestsNeverAuthorizePinnedRemoval() throws {
        let legacy = Data(#"{"type":"remove_worktree","worktree_path":"/repo/.worktrees/role","force":true}"#.utf8)
        let request = try JSONDecoder().decode(NotificationMessage.self, from: legacy)
        let json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any])
        #expect(json["pinned"] as? Bool == false)
    }

    @Test func pinnedRequestAndCapabilityRoundTrip() throws {
        for request in [NotificationMessage.removeWorktree(worktreePath: "/repo/role", force: false, pinned: true),
                        .worktreePinnedRemovalCapability] {
            #expect(request.expectsResponse)
            let data = try JSONEncoder().encode(request)
            #expect(try JSONDecoder().decode(NotificationMessage.self, from: data) == request)
        }
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(NotificationMessage.self,
                from: Data(#"{"type":"remove_worktree","worktree_path":"/repo/role","force":true,"pinned":"true"}"#.utf8))
        }
    }

    @Test func everyRemovalRequiresGuardCapability() throws {
        for arguments in [["role"], ["role", "--force"], ["role", "--pinned"]] {
            let command = try WorktreeRemove.parse(arguments)
            var probes: [NotificationMessage] = []
            #expect(throws: (any Error).self) {
                try command.requirePinnedRemovalSupport(send: { probes.append($0); return .error("unknown message type") })
            }
            #expect(probes == [.worktreePinnedRemovalCapability])
            try command.requirePinnedRemovalSupport(send: { request in
                #expect(request == .worktreePinnedRemovalCapability)
                return .ok
            })
        }
    }

    @MainActor
    @Test(arguments: [false, true], [WorktreeState.closed, .stale])
    func appRejectsPinnedRemovalBeforeWakingOrDeleting(force: Bool, worktreeState: WorktreeState) {
        var role = WorktreeEntry(path: "/repo/.worktrees/role", branch: "role", state: worktreeState)
        role.isPinned = true
        var state = AppState(repos: [RepoEntry(path: "/repo", displayName: "Repo", worktrees: [role])])
        let store = CLIWorktreeRemovalStore()
        let response = CLIWorktreeRemovalRequestHandler.begin(
            worktreePath: role.path, force: force, pinned: false,
            appState: Binding(get: { state }, set: { state = $0 }), worktreeRemovals: store,
            wakeWorktree: { _ in Issue.record("rejected removal must not wake processes"); return true },
            deleteWorktree: { _, _ in Issue.record("rejected removal must not run Git or dismiss"); return .success(.init(dismissed: true)) }
        )
        guard case .error(let error) = response else { Issue.record("expected pin rejection"); return }
        #expect(error.contains("--pinned"))
        #expect(!store.hasPendingRemoval(worktreePath: role.path))
        #expect(state.repos[0].worktrees == [role])
    }

    @MainActor
    @Test(arguments: [false, true])
    func defaultCheckoutRemainsProtected(pinned: Bool) {
        let home = WorktreeEntry(path: "/repo", branch: "main")
        var state = AppState(repos: [RepoEntry(path: home.path, displayName: "Repo", worktrees: [home])])
        let response = CLIWorktreeRemovalRequestHandler.begin(
            worktreePath: home.path, force: true, pinned: pinned,
            appState: Binding(get: { state }, set: { state = $0 }), worktreeRemovals: CLIWorktreeRemovalStore(),
            wakeWorktree: { _ in Issue.record("main checkout must not wake"); return true },
            deleteWorktree: { _, _ in Issue.record("main checkout must survive"); return .success(.init(dismissed: false)) }
        )
        #expect(response == .error("cannot remove the main checkout"))
    }

    @MainActor
    @Test(arguments: [(false, false), (false, true), (true, false), (true, true)], [false, true])
    func authorizedLinkedRemovalPreservesForceAndDismissOutcome(options: (force: Bool, dismissed: Bool), isPinned: Bool) async throws {
        let (force, dismissed) = options
        var role = WorktreeEntry(path: "/repo/.worktrees/role", branch: "role", state: dismissed ? .stale : .closed)
        role.isPinned = isPinned
        var state = AppState(repos: [RepoEntry(path: "/repo", displayName: "Repo", worktrees: [role])])
        let store = CLIWorktreeRemovalStore()
        var deleted = false
        let response = CLIWorktreeRemovalRequestHandler.begin(
            worktreePath: role.path, force: force, pinned: isPinned,
            appState: Binding(get: { state }, set: { state = $0 }), worktreeRemovals: store,
            wakeWorktree: { path in #expect(path == role.path); return true },
            deleteWorktree: { path, requestedForce in
                #expect(path == role.path)
                #expect(requestedForce == force)
                deleted = true
                return .success(.init(dismissed: dismissed))
            }
        )
        guard case .worktreeRemove(let pending) = response else { Issue.record("expected pending removal"); return }
        let terminal = try await finishedStatus(pending.operationID, in: store)
        #expect(terminal.state == .removed)
        #expect(deleted)
    }

    @MainActor
    @Test func delayedRemovalRechecksAuthoritativePinState() async throws {
        let role = WorktreeEntry(path: "/repo/.worktrees/role", branch: "role")
        var state = AppState(repos: [RepoEntry(path: "/repo", displayName: "Repo", worktrees: [role])])
        let store = CLIWorktreeRemovalStore()
        let response = CLIWorktreeRemovalRequestHandler.begin(
            worktreePath: role.path, force: true, pinned: false,
            appState: Binding(get: { state }, set: { state = $0 }), worktreeRemovals: store,
            wakeWorktree: { _ in true },
            deleteWorktree: { _, _ in Issue.record("pin added after admission must prevent deletion"); return .success(.init(dismissed: false)) }
        )
        #expect(WorktreePinRequestHandler.handle(worktreePath: role.path, isPinned: true, state: &state) == .ok)
        guard case .worktreeRemove(let pending) = response else { Issue.record("expected pending removal"); return }
        let terminal = try await finishedStatus(pending.operationID, in: store)
        #expect(terminal.state == .failed)
        #expect(terminal.error?.contains("--pinned") == true)
        #expect(!terminal.forceAllowed)
        #expect(state.repos[0].worktrees[0].isPinned)
    }

    @MainActor
    @Test("@spec GIT-3.23: When a stale worktree with retained terminal panes is explicitly removed, the application shall release its terminal runtime registrations before removing its model entry, including vanished-directory recovery.")
    func stalePinnedRemovalReleasesRetainedTerminalRuntime() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("graftty-stale-remove-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = try await GitRunner.run(args: ["init"], at: directory.path)
        let home = WorktreeEntry(path: directory.path, branch: "main")
        let pane = PaneSlotID()
        var role = WorktreeEntry(path: directory.appendingPathComponent("vanished-role").path,
                                 branch: "role", state: .running)
        role.isPinned = true
        role.splitTree = SplitTree(root: .leaf(pane))
        role.markStale()
        var state = AppState(repos: [RepoEntry(path: home.path, displayName: "Repo", worktrees: [home, role])])
        let binding = Binding(get: { state }, set: { state = $0 })
        let manager = TerminalManager(socketPath: directory.appendingPathComponent("control.sock").path)
        manager.markRehydrated(pane)
        manager.registerHostManagedPaneCommandHandler(for: pane) { _ in }
        let store = CLIWorktreeRemovalStore()
        let stats = WorktreeStatsStore()
        let prs = PRStatusStore()
        let dispatcher = TeamEventDispatcher(inbox: TeamInbox(rootDirectory: directory.appendingPathComponent("inbox")),
            preferencesProvider: { .init() }, templateProvider: { "" })
        let response = CLIWorktreeRemovalRequestHandler.begin(
            worktreePath: role.path, force: false, pinned: true, appState: binding, worktreeRemovals: store,
            wakeWorktree: { _ in true },
            deleteWorktree: { path, force in
                await DeleteWorktreeFlow.delete(worktreePath: path, force: force, appState: binding,
                    terminalManager: manager, statsStore: stats, prStatusStore: prs, teamEventDispatcher: dispatcher)
            }
        )
        guard case .worktreeRemove(let pending) = response else { Issue.record("expected pending removal"); return }
        let terminal = try await finishedStatus(pending.operationID, in: store)
        #expect(terminal.state == .removed)
        #expect(state.worktree(forPath: role.path) == nil)
        #expect(!manager.wasRehydrated(pane))
        #expect(!manager.routeHostManagedPaneCommand(.close, for: pane))
    }

    @MainActor
    private func finishedStatus(_ operationID: String, in store: CLIWorktreeRemovalStore) async throws -> WorktreeRemoveStatus {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while store.status(operationID: operationID)?.state == .pending, ContinuousClock.now < deadline {
            await Task.yield()
        }
        let status = try #require(store.status(operationID: operationID))
        #expect(status.state != .pending)
        return status
    }

    @MainActor
    @Test("@spec GIT-3.22: If a stale worktree becomes pinned while automatic dismissal discovery is suspended, then the application shall preserve the entry and its surfaces and caches.")
    func automaticDismissalRechecksPinStateAfterDiscovery() async {
        var role = WorktreeEntry(path: "/repo/.worktrees/role", branch: "role", state: .stale)
        let now = Date(timeIntervalSince1970: 10_000)
        role.staleSince = now.addingTimeInterval(-3_600)
        var state = AppState(repos: [RepoEntry(path: "/repo", displayName: "Repo", worktrees: [role])])
        let dismissed = await StaleWorktreeDismissal.dismissExpired(
            appState: Binding(get: { state }, set: { state = $0 }),
            now: now,
            discoverWorktrees: { _ in
                state.repos[0].worktrees[0].isPinned = true
                return []
            },
            destroySurfaces: { _ in Issue.record("pinned surfaces must survive") },
            clearPRStatus: { _ in Issue.record("pinned PR cache must survive") },
            clearStats: { _ in Issue.record("pinned stats must survive") }
        )
        role.isPinned = true
        #expect(dismissed.isEmpty)
        #expect(state.repos[0].worktrees == [role])
    }
}
