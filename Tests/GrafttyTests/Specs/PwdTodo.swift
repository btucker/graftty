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
@spec PWD-1.4: While a pane row is rendered in the sidebar (a `running`-state worktree's leaf row per the `STATE` section semantics), the application shall make the row a drag source whose payload identifies the pane. While a worktree row in the same repository is rendered, the application shall make it a drop target that accepts such a payload and route the drop through the same reassignment path as `PWD-1.1` / `PWD-1.3` — i.e. via the manual-routing pipeline in `PWD-2.x`. Drops onto worktree rows in a different repository shall be refused (cross-repo moves are out of scope, matching `PWD-1.3`).
""", .disabled("not yet implemented"))
    func pwd_1_4() async throws { }

    @Test("""
@spec PWD-1.5: While a drag from a pane row is in flight and the user hovers over a worktree row, the application shall render a visual highlight on that worktree row distinct from the active-worktree highlight defined by `LAYOUT-2.11` so the user can see the row is a possible drop target. The highlight is rendered for any hovered worktree row regardless of repo membership; the cross-repo refusal from `PWD-1.4` happens at drop time so the in-flight visual signal isn't required to peek into the payload's source repo.
""", .disabled("not yet implemented"))
    func pwd_1_5() async throws { }

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
