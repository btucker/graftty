import Foundation
import SwiftUI
import Testing
import GrafttyKit
import GrafttyProtocol
@testable import Graftty

/// A web or paired-device delete reaches `WorktreeManagement.delete` without
/// the admission check the sidebar and `graftty worktree remove` make. Before
/// #640 it pruned a row whose creation was still running (the directory does
/// not exist yet, so GIT-4.13 treated it as vanished), and the new worktree
/// was then left on disk untracked.
@MainActor
struct WorktreeManagementInFlightDeleteTests {
    @MainActor
    private final class StateBox {
        var state: AppState
        init(_ state: AppState) { self.state = state }
        var binding: Binding<AppState> { Binding(get: { self.state }, set: { self.state = $0 }) }
    }

    @Test("@spec WEB-7.16: If a web or paired-device client asks to delete a worktree whose creation or removal is still in progress, then the application shall refuse it as a failure that a forced retry cannot resolve, without running Git or changing the worktree's row.",
          arguments: [WorktreeState.creating, .deleting])
    func refusesAnInFlightWorktree(state: WorktreeState) async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("graftty-in-flight-delete-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try await GitRunner.run(args: ["init"], at: root.path)
        var inFlight = WorktreeEntry(path: root.appendingPathComponent(".worktrees/new").path, branch: "new")
        inFlight.state = state
        let box = StateBox(AppState(repos: [RepoEntry(path: root.path, displayName: "repo", worktrees: [
            WorktreeEntry(path: root.path, branch: "main"), inFlight,
        ])]))
        let inbox = TeamInbox(rootDirectory: root.appendingPathComponent("inbox"))
        let service = WorktreeManagement(
            appState: box.binding,
            terminalManager: TerminalManager(socketPath: root.appendingPathComponent("control.sock").path),
            teamInbox: inbox,
            teamEventDispatcher: TeamEventDispatcher(inbox: inbox, preferencesProvider: { TeamEventRoutingPreferences() },
                                                     templateProvider: { "" }),
            worktreeMonitor: WorktreeMonitor(), statsStore: WorktreeStatsStore(), prStatusStore: PRStatusStore(),
            remoteBranchStore: RemoteBranchStore(), worktreeCreations: CLIWorktreeCreationStore(),
            worktreeRemovals: CLIWorktreeRemovalStore(),
            localOrigin: WorktreeOrigin(deviceID: .init(value: "mac"), deviceLabel: "Mac", relayDepth: 0)
        )

        let result = await GrafttyApp.$appStatePersisterOverride.withValue(
            AppStatePersister(directory: root.appendingPathComponent("state"))
        ) {
            await service.delete(worktreePath: inFlight.path, force: false)
        }

        #expect(result == .failure(.gitFailedFinal("a worktree operation is already in progress")))
        #expect(box.state.worktree(forPath: inFlight.path)?.state == state)
        // What each transport now sends for it.
        #expect(WebServer.DeleteWorktreeOutcome(result) == .gitFailedFinal("a worktree operation is already in progress"))
        #expect(WorktreeManagementResponse(removal: result) == .error(
            code: "git-failed", message: "a worktree operation is already in progress", forceAllowed: false, shortStatus: nil))
    }
}
