// Auto-generated inventory of unimplemented specs in this section.
// Promote a @Test(.disabled(...)) entry to a real @Test in a *Tests.swift
// file before implementing the behavior, then delete the entry from this
// inventory file. SPECS.md is regenerated from these markers by
// scripts/generate-specs.py.

import Testing

@Suite("PWD — pending specs")
struct PwdTodo {
    @Test("""
@spec PWD-1.1: When the user opens the right-click context menu on a pane in the sidebar, the application shall offer a "Move to <worktree-name>" entry that targets the worktree whose filesystem path is the longest prefix of the pane's inner-shell working directory across all repos. The shell's working directory is resolved by reading the inner-shell PID from the zmx session log at `<ZMX_DIR>/logs/<session>.log` (falling back to the rotated sibling `<ZMX_DIR>/logs/<session>.log.old` when the spawn line is no longer in the current file) and querying its current working directory via `proc_pidinfo(PROC_PIDVNODEPATHINFO)`.
""", .disabled("not yet implemented"))
    func pwd_1_1() async throws { }

    @Test("""
@spec PWD-1.2: If no worktree path is a prefix of the inner-shell working directory, or the matching worktree is the pane's current host, then the application shall render the entry from `PWD-1.1` as a disabled "Move to current worktree" item so the user can see *why* the action is unavailable rather than have it disappear.
""", .disabled("not yet implemented"))
    func pwd_1_2() async throws { }

    @Test("""
@spec PWD-1.3: When the user opens the right-click context menu on a pane, the application shall additionally offer a "Move to worktree" submenu listing every other worktree in the same repository as the pane's current host. Selecting an entry shall move the pane to that worktree regardless of the pane's current shell working directory. Cross-repository moves are out of scope — the submenu shall not list worktrees from other repos.
""", .disabled("not yet implemented"))
    func pwd_1_3() async throws { }

    @Test("""
@spec PWD-2.1: When the destination worktree differs from the current worktree, the application shall remove the pane from the source worktree's split tree and insert it into the destination worktree's split tree.
""", .disabled("not yet implemented"))
    func pwd_2_1() async throws { }

    @Test("""
@spec PWD-2.2: When a reassignment leaves the source worktree with no remaining panes, the application shall transition the source worktree to the closed state.
""", .disabled("not yet implemented"))
    func pwd_2_2() async throws { }

    @Test("""
@spec PWD-2.4: When the destination worktree was previously in the closed state, the application shall transition it to the running state as part of the reassignment.
""", .disabled("not yet implemented"))
    func pwd_2_4() async throws { }

    @Test("""
@spec PWD-3.1: Before removing a pane from a source worktree, the application shall record its split-tree position — an anchor leaf, split direction, and before/after placement — keyed by `(terminalID, worktreePath)`.
""", .disabled("not yet implemented"))
    func pwd_3_1() async throws { }

    @Test("""
@spec PWD-3.2: When reinserting a pane into a worktree for which a remembered position exists and whose anchor leaf is still present, the application shall restore the pane adjacent to that anchor with the recorded direction and placement.
""", .disabled("not yet implemented"))
    func pwd_3_2() async throws { }

    @Test("""
@spec PWD-3.3: If no usable remembered position exists for the destination worktree, the application shall insert the pane at the first available leaf with a horizontal split as a fallback.
""", .disabled("not yet implemented"))
    func pwd_3_3() async throws { }

    @Test("""
@spec PWD-3.4: Position memory shall be maintained in-process only and not persisted across app restarts.
""", .disabled("not yet implemented"))
    func pwd_3_4() async throws { }
}
