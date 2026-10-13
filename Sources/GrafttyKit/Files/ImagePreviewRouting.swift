import Foundation
import GrafttyProtocol

/// Reuses registered pane membership rather than the caller's current directory.
public enum ImagePreviewRouting {
    public struct Scope: Equatable {
        public let worktreePath: String
        public let pane: PaneSlotID
        public let sessionName: String
    }

    public enum Destination: Equatable { case mac, mobile, unavailable }

    public static func scope(path: String, paneSessionName: String?, state: AppState) -> Scope? {
        guard let worktree = OpenResourceRouting.worktree(path: path, paneSessionName: paneSessionName, state: state) else { return nil }
        let pane: PaneSlotID?
        if let name = paneSessionName, !name.isEmpty {
            pane = worktree.paneSlot(forSessionName: name)
        } else if let focused = worktree.focusedPaneSlotID, worktree.splitTree.containsLeaf(focused) {
            pane = focused
        } else {
            pane = worktree.splitTree.root?.allLeaves.first
        }
        guard let pane, worktree.splitTree.containsLeaf(pane), let session = worktree.paneSessions[pane] else { return nil }
        return Scope(worktreePath: worktree.path, pane: pane, sessionName: ZmxLauncher.sessionName(for: session))
    }

    public static func destination(ownerKind: DisplayClientKind?, macIsFollower: Bool) -> Destination {
        switch ownerKind {
        case .ios: return .mobile
        case .web, .preview: return .unavailable
        case .mac: return macIsFollower ? .unavailable : .mac
        case nil: return macIsFollower ? .unavailable : .mac
        }
    }
}
