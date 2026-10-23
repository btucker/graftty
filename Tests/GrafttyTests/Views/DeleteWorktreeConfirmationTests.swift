import AppKit
import SwiftUI
import Testing
import GrafttyKit
@testable import Graftty

@Suite("Sidebar worktree deletion confirmation", .serialized)
@MainActor
struct DeleteWorktreeConfirmationTests {
    @Test("@spec GIT-4.20: When Delete Worktree is invoked on an unselected local sidebar worktree, the application shall present confirmation on that row's owning window after menu tracking ends and delete the requested path without changing selection first.", arguments: [true, false])
    func unselectedWorktreeConfirmsOnOwningWindow(confirm: Bool) async throws {
        let selectedPath = "/repo"
        let targetPath = "/repo/.worktrees/task"
        var state = AppState(repos: [RepoEntry(path: selectedPath, displayName: "Project", worktrees: [
            WorktreeEntry(path: selectedPath, branch: "main"),
            WorktreeEntry(path: targetPath, branch: "task")
        ])], selectedWorktreePath: selectedPath)
        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 480, height: 300),
                              styleMask: .titled, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.orderFront(nil)
        defer {
            if let sheet = window.attachedSheet { window.endSheet(sheet, returnCode: .alertSecondButtonReturn) }
            window.orderOut(nil)
        }
        #expect(NSApp.mainWindow !== window, "The test window must not rely on global main-window selection")
        var deleted: [String] = []
        var confirmationWindow: NSWindow?
        DeleteWorktreeConfirmation.present(worktreePath: targetPath, on: window) { path, host in
            confirmationWindow = host
            deleted.append(path)
            state.removeWorktree(atPath: path)
        }
        #expect(window.attachedSheet == nil, "The menu action must return before the sheet opens")
        try await Task.sleep(for: .milliseconds(150))
        let sheet = try #require(window.attachedSheet)
        #expect(state.selectedWorktreePath == selectedPath)
        #expect(deleted.isEmpty)
        window.endSheet(sheet, returnCode: confirm ? .alertFirstButtonReturn : .alertSecondButtonReturn)
        try await Task.sleep(for: .milliseconds(100))
        #expect(deleted == (confirm ? [targetPath] : []))
        #expect(confirm ? confirmationWindow === window : confirmationWindow == nil)
        #expect(state.selectedWorktreePath == selectedPath)
        #expect(state.worktree(forPath: selectedPath) != nil)
        #expect((state.worktree(forPath: targetPath) == nil) == confirm)
    }

    /// The menu hides Delete Worktree for an in-flight row, but the
    /// confirmation and Force Delete sheets are asynchronous: a web,
    /// paired-device or CLI removal can start while one is open.
    @Test("@spec GIT-4.21: If the user confirms Delete Worktree or Force Delete for a worktree whose creation or removal is already in progress, then the application shall refuse the deletion with a single-button error alert, without running Git or changing the worktree's row.",
          arguments: [WorktreeState.creating, .deleting], [false, true])
    func confirmedDeletionOfAnInFlightWorktreeIsRefused(state: WorktreeState, force: Bool) async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("graftty-confirmed-in-flight-delete-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try await GitRunner.run(args: ["init"], at: root.path)
        var inFlight = WorktreeEntry(path: root.appendingPathComponent(".worktrees/new").path, branch: "new")
        inFlight.state = state
        var appState = AppState(repos: [RepoEntry(path: root.path, displayName: "repo", worktrees: [
            WorktreeEntry(path: root.path, branch: "main"), inFlight,
        ])])
        let binding = Binding(get: { appState }, set: { appState = $0 })
        let inbox = TeamInbox(rootDirectory: root.appendingPathComponent("inbox"))

        let result = await GrafttyApp.$appStatePersisterOverride.withValue(
            AppStatePersister(directory: root.appendingPathComponent("state"))
        ) {
            await DeleteWorktreeFlow.delete(
                worktreePath: inFlight.path, force: force, appState: binding,
                terminalManager: TerminalManager(socketPath: root.appendingPathComponent("control.sock").path),
                statsStore: WorktreeStatsStore(), prStatusStore: PRStatusStore(),
                teamEventDispatcher: TeamEventDispatcher(inbox: inbox, preferencesProvider: { TeamEventRoutingPreferences() },
                                                         templateProvider: { "" })
            )
        }

        guard case .failure(.gitFailedFinal(let message)) = result else {
            Issue.record("expected a final refusal, got \(result)")
            return
        }
        #expect(message == WorktreeRemovalError.operationInProgressMessage)
        #expect(ForceDeleteAlert.gitFailedFinalConfiguration(message: message).secondaryButton == nil)
        #expect(appState.worktree(forPath: inFlight.path)?.state == state)
    }
}
