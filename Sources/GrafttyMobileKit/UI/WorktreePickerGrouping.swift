#if canImport(UIKit)
import GrafttyProtocol

/// Pure grouping helper for `WorktreePickerView`. Extracted from the
/// SwiftUI body so the order-preservation contract (IOS-9.9) can be
/// unit-tested without instantiating any view.
public enum WorktreePickerGrouping {
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
    /// `GET /worktrees/panes` ships entries in, which mirrors the Mac
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
#endif
