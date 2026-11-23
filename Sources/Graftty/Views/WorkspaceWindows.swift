import AppKit
import GrafttyKit
import Observation

@MainActor
@Observable
final class WorkspaceWindowSelection {
    fileprivate(set) var worktreeID: UUID?
    var remotePaneID: PaneSlotID?
    @ObservationIgnored fileprivate(set) weak var window: NSWindow?
    @ObservationIgnored var isReady = false

    func bringForward() {
        window?.deminiaturize(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}

/// A local Ghostty surface has one NSView. Each local worktree can be
/// presented in only one workspace window at a time.
@MainActor
@Observable
final class WorkspaceWindows {
    @ObservationIgnored private var selections: [ObjectIdentifier: WorkspaceWindowSelection] = [:]
    private(set) weak var active: WorkspaceWindowSelection?

    /// Only the first open workspace restores the shared saved frame and
    /// selection, including when a workspace is reopened from the Dock.
    @discardableResult
    func attach(_ selection: WorkspaceWindowSelection, to window: NSWindow) -> Bool {
        selections = selections.filter { $0.value.window != nil }
        let first = selections.isEmpty
        selection.window = window
        selections[ObjectIdentifier(window)] = selection
        return first
    }

    func detach(_ selection: WorkspaceWindowSelection, from window: NSWindow) {
        guard selection.window === window else { return }
        selections.removeValue(forKey: ObjectIdentifier(window))
        selection.window = nil
        selection.isReady = false
        selection.worktreeID = nil
        if active === selection { active = nil }
    }

    func makeActive(_ selection: WorkspaceWindowSelection) {
        if active !== selection { active = selection }
    }

    func windowShowing(_ worktreeID: UUID) -> WorkspaceWindowSelection? {
        selections.values.first { $0.window != nil && $0.worktreeID == worktreeID }
    }

    @discardableResult
    func select(_ worktreeID: UUID?, in selection: WorkspaceWindowSelection) -> Bool {
        if let worktreeID, let other = windowShowing(worktreeID), other !== selection {
            other.bringForward()
            return false
        }
        selection.worktreeID = worktreeID
        return true
    }
}
