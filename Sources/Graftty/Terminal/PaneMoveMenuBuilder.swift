import AppKit
import GrafttyKit

/// Snapshot of the model facts the Move-to-worktree menu builder needs.
/// Both call sites build one via `resolve(...)` so context-gathering
/// stays in one place — see the factory below.
struct PaneMoveMenuContext {
    let currentWorktree: WorktreeEntry
    let currentRepo: RepoEntry
    /// Pre-resolved cwd → worktree match per PWD-1.1, or nil when no
    /// known worktree path is a prefix of the shell's cwd. Nil
    /// collapses the entry to the disabled "Move to current worktree"
    /// form per PWD-1.2.
    let cwdMatch: (repo: RepoEntry, worktree: WorktreeEntry)?

    /// Builds a context for `terminalID` from the live model. Returns
    /// nil when no worktree currently hosts the pane (mid-reassignment
    /// race, or the pane was just removed) — callers should skip the
    /// Move section in that case.
    static func resolve(
        terminalID: TerminalID,
        appState: AppState,
        shellCwd: String?
    ) -> PaneMoveMenuContext? {
        guard let host = appState.indicesOfWorktreeContaining(terminalID: terminalID) else {
            return nil
        }
        let repo = appState.repos[host.repo]
        let match = shellCwd
            .flatMap { appState.worktreeIndicesMatching(path: $0) }
            .map { (repo: appState.repos[$0.repo],
                    worktree: appState.repos[$0.repo].worktrees[$0.worktree]) }
        return PaneMoveMenuContext(
            currentWorktree: repo.worktrees[host.worktree],
            currentRepo: repo,
            cwdMatch: match
        )
    }
}

/// Builds the `[NSMenuItem]` for the Move-to-worktree section of a
/// pane's right-click menu. Shared by:
///   - The sidebar pane row (`SidebarView.swift`), which wraps these
///     items in its own `NSMenu`.
///   - The terminal surface menu (`SurfaceContextMenu.swift`), which
///     splices them into the surface menu between the Splits block
///     and the Reset block.
///
/// Returned items are in display order (no leading separator). Caller
/// owns `NSMenu` construction and any surrounding separators.
enum PaneMoveMenuBuilder {
    static func items(
        terminalID: TerminalID,
        context: PaneMoveMenuContext,
        onMove: @escaping (TerminalID, String) -> Void
    ) -> [NSMenuItem] {
        var out: [NSMenuItem] = []

        // PWD-1.1 / PWD-1.2: cwd-driven auto-detect, or disabled fallback.
        out.append(currentWorktreeItem(
            terminalID: terminalID,
            context: context,
            onMove: onMove
        ))

        // PWD-1.3: same-repo siblings as a submenu. Suppressed when
        // there are no siblings — the submenu would otherwise render
        // empty and confuse the user.
        let siblings = context.currentRepo.worktrees.filter {
            $0.id != context.currentWorktree.id
        }
        if !siblings.isEmpty {
            out.append(siblingsSubmenu(
                terminalID: terminalID,
                siblings: siblings,
                repo: context.currentRepo,
                onMove: onMove
            ))
        }

        return out
    }

    private static func currentWorktreeItem(
        terminalID: TerminalID,
        context: PaneMoveMenuContext,
        onMove: @escaping (TerminalID, String) -> Void
    ) -> NSMenuItem {
        if let match = context.cwdMatch,
           match.worktree.id != context.currentWorktree.id {
            let label = SidebarWorktreeLabel.text(
                for: match.worktree,
                inRepoAtPath: match.repo.path,
                siblingPaths: match.repo.worktrees.map(\.path)
            )
            return ClosureMenuItem(title: "Move to \(label)") {
                onMove(terminalID, match.worktree.path)
            }
        }
        // PWD-1.2: keep the slot visible but disabled so the user can
        // see *why* there's no auto-target instead of having the item
        // disappear entirely.
        let item = NSMenuItem(title: "Move to current worktree", action: nil, keyEquivalent: "")
        item.isEnabled = false
        item.toolTip = "Shell cwd is not under another known worktree"
        return item
    }

    private static func siblingsSubmenu(
        terminalID: TerminalID,
        siblings: [WorktreeEntry],
        repo: RepoEntry,
        onMove: @escaping (TerminalID, String) -> Void
    ) -> NSMenuItem {
        let parent = NSMenuItem(title: "Move to worktree", action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: "Move to worktree")
        let allPaths = repo.worktrees.map(\.path)
        for sibling in siblings {
            let label = SidebarWorktreeLabel.text(
                for: sibling,
                inRepoAtPath: repo.path,
                siblingPaths: allPaths
            )
            let item = ClosureMenuItem(title: label) {
                onMove(terminalID, sibling.path)
            }
            submenu.addItem(item)
        }
        parent.submenu = submenu
        return parent
    }
}
