import GrafttyProtocol
import GrafttyCommandUI

/// Pure grouping helper for `WorktreePickerView`. Extracted from the
/// SwiftUI body so the order-preservation contract (IOS-9.9) can be
/// unit-tested without instantiating any view.
public enum WorktreePickerGrouping {
    struct Region: Identifiable, Sendable {
        enum Kind: Hashable, Sendable { case pinned, tasks, search }
        let kind: Kind
        let groups: [Group]
        var id: Kind { kind }
        var sidebarSection: SidebarWorktreeSection {
            switch kind {
            case .pinned: .pinned
            case .tasks: .tasks
            case .search: .all
            }
        }
    }

    /// Match the Mac's membership regions across projects, with one flat
    /// result list during search. Older hosts remain in the task region.
    static func regions(_ list: [WorktreePanes], searching: Bool) -> [Region] {
        let groups = grouped(list)
        guard !groups.isEmpty else { return [] }
        if searching { return [Region(kind: .search, groups: groups)] }
        return [Region.Kind.pinned, .tasks].compactMap { kind in
            let members = groups.compactMap { group -> Group? in
                let sections = SidebarWorktreeSections(group.worktrees)
                let rows = kind == .pinned ? sections.pinned : sections.tasks
                guard !rows.isEmpty else { return nil }
                // Keep the complete group so section rendering can recognize
                // metadata even when only its main checkout lacks a pin flag.
                return group
            }
            return members.isEmpty ? nil : Region(kind: kind, groups: members)
        }
    }

    public struct Group: Identifiable, Sendable, Equatable {
        public struct ID: Hashable, Sendable {
            public let ownerID: String
            public let repositoryID: String
        }

        public let id: ID
        public let title: String
        public let worktrees: [WorktreePanes]
    }

    /// Group `list` by owning Mac + repository identity, preserving each key's
    /// first-occurrence order. This matches the order
    /// The authenticated panes-state channel ships entries in Mac sidebar
    /// sidebar's `appState.repos` ordering — so the mobile picker
    /// looks "the same" as the desktop sidebar.
    public static func grouped(_ list: [WorktreePanes]) -> [Group] {
        let remoteOrigins = list.compactMap { worktree -> WorktreeOrigin? in
            guard let origin = worktree.origin, origin.relayDepth > 0 else {
                return nil
            }
            return origin
        }
        let ownersByLabel = Dictionary(grouping: remoteOrigins) {
            $0.deviceLabel
        }.mapValues { Set($0.map(\.deviceID.value)).count }
        var order: [Group.ID] = []
        var groups: [Group.ID: [WorktreePanes]] = [:]
        var titles: [Group.ID: String] = [:]
        for wt in list {
            let ownerID: String
            let title: String
            if let origin = wt.origin, origin.relayDepth > 0 {
                ownerID = "remote:\(origin.deviceID.value)"
                let ownerLabel: String
                if ownersByLabel[origin.deviceLabel, default: 0] > 1 {
                    ownerLabel = "\(origin.deviceLabel) (\(shortID(origin.deviceID.value)))"
                } else {
                    ownerLabel = origin.deviceLabel
                }
                title = "\(ownerLabel) · \(wt.repoDisplayName)"
            } else {
                ownerID = "local:connected-mac"
                title = wt.repoDisplayName
            }
            let key = Group.ID(
                ownerID: ownerID,
                repositoryID: wt.repositoryID ?? wt.repoDisplayName
            )
            if groups[key] == nil {
                order.append(key)
                titles[key] = title
            }
            groups[key, default: []].append(wt)
        }
        return order.map {
            Group(
                id: $0,
                title: titles[$0] ?? "",
                worktrees: groups[$0] ?? []
            )
        }
    }

    private static func shortID(_ value: String) -> String {
        String(value.prefix(6))
    }
}

/// Trailing destructive action surfaced on swipe. Nil for rows that
/// cannot be removed via the picker (main checkout, `.creating`).
public enum WorktreePickerSwipeAction: Equatable {
    case delete    // non-stale, non-main rows: runs `git worktree remove`
    case dismiss   // `.stale` rows: prunes the orphan admin entry

    public var buttonLabel: String {
        switch self {
        case .delete: return "Delete"
        case .dismiss: return "Dismiss"
        }
    }

    public var dialogTitle: String {
        switch self {
        case .delete: return "Delete Worktree?"
        case .dismiss: return "Dismiss Worktree?"
        }
    }

    public var dialogBody: String {
        switch self {
        case .delete: return "This will delete the worktree but not the branch."
        case .dismiss: return "This will remove this stale entry from Graftty."
        }
    }
}

extension WorktreePickerGrouping {
    /// IOS-9.6 rule: main checkout and in-flight rows have no swipe
    /// affordance — the first can't be deleted; the latter are
    /// mid-flight on the server. `.stale` rows offer Dismiss;
    /// everything else offers Delete.
    public static func swipeAction(for wt: WorktreePanes) -> WorktreePickerSwipeAction? {
        if wt.isMainCheckout { return nil }
        if wt.state.isInFlight { return nil }
        if wt.state == .stale { return .dismiss }
        return .delete
    }
}
