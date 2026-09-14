import Foundation

/// Folder ancestry is presentation metadata supplied by the owning host.
/// Resource routes remain opaque even when they resemble filesystem paths.
public struct SidebarWorktreeTree: Identifiable, Sendable {
    public var id: String
    public var name: String
    public var worktree: WorktreePanes?
    public var children: [SidebarWorktreeTree]?

    public static func nodes(_ worktrees: [WorktreePanes], depth: Int = 0) -> [SidebarWorktreeTree] {
        var emitted: Set<String> = []
        var result: [SidebarWorktreeTree] = []
        for worktree in worktrees {
            let folders = worktree.sidebar?.folders ?? []
            guard depth < folders.count else {
                result.append(.init(id: worktree.sidebar?.id ?? worktree.path, name: worktree.displayBranch, worktree: worktree))
                continue
            }
            let folder = folders[depth]
            guard emitted.insert(folder).inserted else { continue }
            let descendants = worktrees.filter { row in
                let ancestry = row.sidebar?.folders ?? []
                return ancestry.count > depth && ancestry[depth] == folder
            }
            result.append(.init(id: SidebarProjection.projectID(worktree) + ":folder:" + folders.prefix(depth + 1).joined(separator: "/"),
                                name: folder, children: nodes(descendants, depth: depth + 1)))
        }
        return result
    }
}
