#if canImport(UIKit)
import Foundation
import Observation
import SwiftUI
import GrafttyProtocol

/// Observable selection state for the iPad regular-width layout.
/// `selectedHostId` and `sidebarWidth` persist to `UserDefaults`;
/// `selectedWorktreePath`, `focusedPaneId`, and `theme` are in-memory
/// only — they're cheap to re-derive on launch from the persisted
/// host + a fresh worktrees fetch.
///
/// Owned at `RootView` level so values survive size-class transitions
/// (Split View resize from regular → compact and back).
///
/// @spec IPAD-7.2
/// When `horizontalSizeClass` transitions between `.regular` and
/// `.compact`, the application shall preserve `selectedHostId`,
/// `selectedWorktreePath`, and `focusedPaneId` so the user lands on
/// the equivalent leaf in the new layout.
///
/// @spec IPAD-1.4
/// When the user taps a pane child row in the sidebar at iPad regular
/// width, the application shall set `IPadAppState.focusedPaneId` to
/// that leaf's `sessionName` without pushing a new navigation stack
/// frame.
@Observable
@MainActor
public final class IPadAppState {

    public var selectedHostId: UUID? {
        didSet {
            guard oldValue != selectedHostId else { return }
            if let id = selectedHostId {
                defaults.set(id.uuidString, forKey: Keys.selectedHostId)
            } else {
                defaults.removeObject(forKey: Keys.selectedHostId)
            }
        }
    }

    public var selectedWorktreePath: String?
    public var focusedPaneId: String?

    /// Sidebar/detail visibility for the iPad NavigationSplitView.
    /// In-memory only — a fresh launch always lands on both columns
    /// visible; user-driven hide/show during a session lives here so the
    /// binding survives view-tree rebuilds.
    public var columnVisibility: NavigationSplitViewVisibility = .all

    /// Cached `true` iff any worktree (or any pane leaf) in the most
    /// recent `GET /worktrees/panes` snapshot has a non-nil
    /// `attentionText`. Maintained by `IPadRootLayout
    /// .onWorktreeListChanged`. The detail-column toolbar reads this
    /// to decide whether to show an attention dot beside the system
    /// sidebar-toggle button while `columnVisibility != .all`
    /// (IPAD-1.11).
    public var anyWorktreeHasAttention: Bool = false

    public var sidebarWidth: Double {
        didSet {
            guard oldValue != sidebarWidth else { return }
            defaults.set(sidebarWidth, forKey: Keys.sidebarWidth)
        }
    }

    public var theme: GhosttyThemeColors

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        if let idString = defaults.string(forKey: Keys.selectedHostId),
           let id = UUID(uuidString: idString) {
            self.selectedHostId = id
        } else {
            self.selectedHostId = nil
        }

        self.selectedWorktreePath = nil
        self.focusedPaneId = nil

        let savedWidth = defaults.double(forKey: Keys.sidebarWidth)
        self.sidebarWidth = savedWidth > 0 ? savedWidth : 320

        self.theme = .fallback
    }

    private enum Keys {
        static let selectedHostId = "iPadAppState.selectedHostId"
        static let sidebarWidth = "iPadAppState.sidebarWidth"
    }

    // Per-host `RemoteHostConnection`s live in `RemoteConnectionCoordinator`
    // (negotiate-on-demand, in-flight dedup, eviction), not here — `RootView`
    // holds and reads the coordinator directly on both size classes. This
    // type owns only sidebar/detail selection and layout state.
}
#endif
