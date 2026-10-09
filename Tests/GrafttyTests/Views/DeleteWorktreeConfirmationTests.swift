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
}
