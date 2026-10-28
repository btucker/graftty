import Foundation
import GrafttyProtocol

/// Client-owned placeholders survive snapshots that predate the create request.
/// Host identifiers are opaque, so bind to the returned path after creation.
struct MobileWorktreeCreation {
    private struct Pending {
        let id: UUID
        let placeholder: WorktreePanes
        let knownPaths: Set<String>
        let generation: UInt64
        var worktreePath: String?

        func matches(_ row: WorktreePanes) -> Bool {
            if let worktreePath { return row.path == worktreePath }
            return !knownPaths.contains(row.path)
                && row.repositoryID == placeholder.repositoryID
                && row.origin?.deviceID == placeholder.origin?.deviceID
                && row.repoDisplayName == placeholder.repoDisplayName
                && row.displayBranch == placeholder.displayBranch
        }

        func creatingRow(path: String) -> WorktreePanes {
            WorktreePanes(
                path: path, displayName: placeholder.displayName,
                repoDisplayName: placeholder.repoDisplayName,
                repositoryID: placeholder.repositoryID,
                displayBranch: placeholder.displayBranch, state: .creating,
                isMainCheckout: false, prBadge: nil, stats: nil,
                attentionText: nil, layout: nil, origin: placeholder.origin,
                sidebar: placeholder.sidebar
            )
        }
    }

    private var pending: [Pending] = []
    var isEmpty: Bool { pending.isEmpty }

    mutating func begin(placeholder: WorktreePanes, knownPaths: Set<String>, generation: UInt64) -> UUID {
        let id = UUID()
        pending.append(Pending(id: id, placeholder: placeholder, knownPaths: knownPaths, generation: generation))
        return id
    }

    mutating func complete(_ id: UUID, worktreePath: String) {
        guard let index = pending.firstIndex(where: { $0.id == id }) else { return }
        pending[index].worktreePath = worktreePath
    }

    mutating func fail(_ id: UUID) {
        pending.removeAll { $0.id == id }
    }

    func rows(in snapshot: [WorktreePanes]) -> [WorktreePanes] {
        var rows = snapshot
        for item in pending {
            if let index = rows.firstIndex(where: item.matches) {
                // Prefer host progress once the placeholder has a matching row.
                // In particular, never hide its failed/interrupted outcome.
                if rows[index].creationProgress == nil {
                    rows[index] = item.creatingRow(path: rows[index].path)
                }
            } else {
                rows.append(item.creatingRow(path: item.worktreePath ?? item.placeholder.path))
            }
        }
        return rows
    }

    /// Pending rows outside the currently selected project must use the same
    /// authoritative progress as rows in the main list.
    func pendingRows(in snapshot: [WorktreePanes]) -> [WorktreePanes] {
        pending.map { item in
            if let row = snapshot.first(where: item.matches), row.creationProgress != nil { return row }
            return item.creatingRow(path: item.worktreePath ?? item.placeholder.path)
        }
    }

    mutating func takeReadySelection(in snapshot: [WorktreePanes], generation: UInt64) -> WorktreePanes? {
        var selected: WorktreePanes?
        pending.removeAll { item in
            guard let path = item.worktreePath,
                  let row = snapshot.first(where: { $0.path == path }),
                  row.state == .running,
                  row.layout?.leaves.isEmpty == false else { return false }
            if item.generation == generation { selected = row }
            return true
        }
        return selected
    }
}
