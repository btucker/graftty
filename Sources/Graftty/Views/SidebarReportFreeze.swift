import Foundation
import GrafttyCommandUI
import GrafttyProtocol

/// Holds the sidebar's rows in place while a report popover is open, so a row
/// does not move out from under the report that points at it.
struct SidebarReportFreeze {
    /// Row positions as they stood when the first report opened.
    struct Snapshot {
        var worktreeOrder: [UUID: [UUID]] = [:]
        var pins: [UUID: Bool] = [:]
        var remoteRows: [RemoteMacIdentity: [WorktreePanes]] = [:]
        var mergedOrder: [String: [String]] = [:]
        var activity: [String: WorktreeActivitySections.Hold] = [:]
    }

    /// `nil` while no report is open. A snapshot with nothing in it is still a freeze.
    private(set) var snapshot: Snapshot?

    /// Captures once when a report opens, keeps that capture while the user
    /// moves between reports, and releases it when the last one closes.
    mutating func reportChanged(isOpen: Bool, capture: () -> Snapshot) {
        guard isOpen else { snapshot = nil; return }
        if snapshot == nil { snapshot = capture() }
    }
}
