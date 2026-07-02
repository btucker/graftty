#if canImport(UIKit)
import Foundation
import Observation
import os
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

    // MARK: - RemoteHostConnection wiring (R4)
    //
    // SUPERSEDED by `RemoteConnectionCoordinator` (W3 Task 2), which owns
    // real negotiate-on-demand + in-flight dedup + eviction against
    // production signaling. This cache and its accessors are kept as-is
    // for now — `RootView.swift`'s `openWebSocket()` (:444) still reads
    // `remoteHostConnection(for:)` — because rewiring that call site to
    // `await coordinator.connection(for:)` is UI wiring that belongs to
    // Task 3, not this one. `setRemoteHostConnection` has no production
    // caller (the negotiation half never landed against this cache); Task
    // 3 removes all of this once `RootView` reads from the coordinator
    // instead.

    /// Per-host `RemoteHostConnection` cache keyed by `Host.id`. iPad's
    /// `SessionClient.live` calls reach for these via
    /// `remoteHostConnection(for:)` so terminal traffic rides
    /// SSH-over-WebRTC when a paired connection is available, falling
    /// back to `/ws` when not.
    ///
    /// Today this cache stays empty: nothing populates it — see the
    /// "SUPERSEDED" note above.
    @ObservationIgnored
    private var remoteHostConnectionsByHostId: [UUID: RemoteHostConnection] = [:]

    /// Returns the `RemoteHostConnection` for `host` if one has been
    /// negotiated, or `nil` otherwise (which causes
    /// `SessionClient.live` to use the `/ws` fallback). Call sites on
    /// the iPad path log when this returns nil so a wiring regression
    /// after signaling lands is visible in console.
    public func remoteHostConnection(for host: Host) -> RemoteHostConnection? {
        remoteHostConnectionsByHostId[host.id]
    }

    /// Setter for the connection cache. See the "SUPERSEDED" note above —
    /// no production code calls this; `RemoteConnectionCoordinator` is the
    /// real registry now.
    public func setRemoteHostConnection(_ connection: RemoteHostConnection?, for host: Host) {
        if let connection {
            remoteHostConnectionsByHostId[host.id] = connection
        } else {
            remoteHostConnectionsByHostId.removeValue(forKey: host.id)
        }
    }

    /// Shared `os.Logger` for iPad WebRTC wiring diagnostics. Surfaces
    /// the nil-fallback warning when the iPad ends up on `/ws` because
    /// no `RemoteHostConnection` is registered for the active host.
    public static let remoteWiringLogger = Logger(
        subsystem: "com.quotably.graftty",
        category: "ipad-remote-wiring"
    )
}
#endif
