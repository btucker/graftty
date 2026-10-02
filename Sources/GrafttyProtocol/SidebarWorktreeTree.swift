import Foundation

/// Keeps hosts without membership metadata on their existing flat layout.
public struct SidebarWorktreeSections: Sendable {
    public let tasks: [WorktreePanes]
    public let team: [WorktreePanes]
    public let hasMembershipMetadata: Bool

    public init(_ worktrees: [WorktreePanes]) {
        tasks = worktrees.filter { $0.isMainCheckout || $0.sidebar?.isTeamMember != true }
        team = worktrees.filter { !$0.isMainCheckout && $0.sidebar?.isTeamMember == true }
        hasMembershipMetadata = worktrees.contains { $0.sidebar?.isTeamMember != nil }
    }
}

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
            let folderID = worktree.sidebar?.folderID(at: depth) ?? folder
            guard emitted.insert(folderID).inserted else { continue }
            let descendants = worktrees.filter { row in
                row.sidebar?.folderID(at: depth) == folderID
            }
            result.append(.init(id: SidebarProjection.projectID(worktree) + ":folder:" + folderID,
                                name: folder, children: nodes(descendants, depth: depth + 1)))
        }
        return result
    }
}
