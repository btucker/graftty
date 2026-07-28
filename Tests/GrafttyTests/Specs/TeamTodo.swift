// Auto-generated inventory of unimplemented specs in this section.
// Promote a @Test(.disabled(...)) entry to a real @Test in a *Tests.swift
// file before implementing the behavior, then delete the entry from this
// inventory file. SPECS.md is regenerated from these markers by
// scripts/generate-specs.py.

import Testing

@Suite("TEAM — pending specs")
struct TeamTodo {
    @Test("""
@spec TEAM-1.1: The application shall provide a Settings tab named "Agent Teams" containing one boolean toggle, *Enable agent teams*, persisted via `@AppStorage("agentTeamsEnabled")` (Bool, default false).
""", .disabled("not yet implemented"))
    func team_1_1() async throws { }

    @Test("""
@spec TEAM-1.2: While `agentTeamsEnabled` is false, the application shall not write any team event rows to the inbox and `graftty team hook` shall return no-op responses; the agent team feature is fully gated by this flag.
""", .disabled("not yet implemented"))
    func team_1_2() async throws { }

    @Test("""
@spec TEAM-1.5: `agentTeamsEnabled` plus the `teamEventRoutingPreferences` JSON struct (see TEAM-1.8) supersede the previous coupled `teamPRNotificationsEnabled` flag. Inbox events are written only when `agentTeamsEnabled` is true; per-event recipient sets are taken from the matrix in `teamEventRoutingPreferences`.
""", .disabled("not yet implemented"))
    func team_1_5() async throws { }

    @Test("""
@spec TEAM-1.8: The Agent Teams Settings pane shall render a 4×3 matrix of toggles (rows: PR state changed / PR merged / CI conclusion changed / Mergability changed; columns: Root agent / Worktree agent / Other worktree agents). Each cell binds to one bit of a `RecipientSet` field on the persisted `TeamEventRoutingPreferences` `Codable` struct. Defaults: state-changed/CI/mergability → worktree only; merged → root only. The matrix is rendered as its own Section between the main toggle and the prompt sections.
""", .disabled("not yet implemented"))
    func team_1_8() async throws { }

    @Test("""
@spec TEAM-1.9: When `PRStatusStore` fires a transition that produces a routable team event (`pr_state_changed`, `ci_conclusion_changed`, `merge_state_changed`), the application shall consult `teamEventRoutingPreferences` for the corresponding row and write one inbox row per recipient resolved by `TeamEventRouter.recipients`. The router classifies `pr_state_changed` events with `attrs.to == "merged"` as the *PR merged* row; all other `pr_state_changed` events are the *PR state changed* row. Single-worktree repos (no team) receive the event only when the relevant row's `Worktree agent` cell is set; root and other-worktree cells are no-ops there.
""", .disabled("not yet implemented"))
    func team_1_9() async throws { }

    @Test("""
@spec TEAM-2.1: A *team* is implicit in any `RepoEntry` with two or more `WorktreeEntry` children, while `agentTeamsEnabled` is true. A repo with one worktree (or with team mode off) has no team and no team-aware behavior.
""", .disabled("not yet implemented"))
    func team_2_1() async throws { }

    @Test("""
@spec TEAM-2.2: A team's *member name* for a given worktree shall be `WorktreeNameSanitizer(worktree.branch)`, the same sanitization rule used for new worktree names per `GIT-5.1`.
""", .disabled("not yet implemented"))
    func team_2_2() async throws { }

    @Test("""
@spec TEAM-2.3: A team's main worktree shall be the worktree where `worktree.path == repo.path` (the repository's main checkout per `LAYOUT-2.3`). Every other member is a linked worktree.
""", .disabled("not yet implemented"))
    func team_2_3() async throws { }

    @Test("""
@spec TEAM-2.4: Team identity, membership, and main-worktree designation are derived live from `AppState`. The application shall not persist any team-specific data beyond `agentTeamsEnabled` itself.
""", .disabled("not yet implemented"))
    func team_2_4() async throws { }

    @Test("""
@spec TEAM-4.1: The application shall provide a `graftty team` CLI group with direct-message, broadcast, inbox, and member-list commands. Direct-message and broadcast commands shall accept message text from standard input via `--stdin`.
""", .disabled("not yet implemented"))
    func team_4_1() async throws { }

    @Test("""
@spec TEAM-4.2: `graftty team send [--urgent] [--stdin] <member-name> [text]` shall resolve the calling process's worktree via `WorktreeResolver.resolve()`, look up the team for that worktree, find a teammate matching `<member-name>`, and write a `team_message` inbox row addressed to that teammate's worktree with `from.member = <calling-worktree's member name>` and the supplied body. The CLI shall exit non-zero with a stderr message if (a) team mode is disabled, (b) the calling worktree has no team, (c) `<member-name>` is not a teammate of the caller, or (d) no non-empty body is supplied. In case (c) the error shall list the current teammates' member names.
""", .disabled("not yet implemented"))
    func team_4_2() async throws { }

    @Test("""
@spec TEAM-4.3: `graftty team list` shall print one line per team member of the caller's team to stdout: `<member-name>  branch=<branch>  worktree=<path>  main=<true|false>  running=<true|false>`. The first printed line shall be a header `team=<repo-display-name>  members=<count>`. The CLI shall exit non-zero with a stderr message if team mode is disabled or the calling worktree has no team.
""", .disabled("not yet implemented"))
    func team_4_3() async throws { }

    @Test("""
@spec TEAM-5.2: The application shall write a `team_member_joined` inbox row when a worktree is added to a team (a new worktree appears in a team-enabled repo, or a single-worktree repo gains a second worktree). Routing: addressed to the repository's main worktree only. Attributes: `team`, `member` (joiner's member name), `branch`, `worktree` (joiner's path).
""", .disabled("not yet implemented"))
    func team_5_2() async throws { }

    @Test("""
@spec TEAM-5.3: The application shall write a `team_member_left` inbox row when a worktree is removed from a team (the worktree is deleted, or the team-enabled repo collapses to one worktree). Routing: addressed to the repository's main worktree only. Attributes: `team`, `member` (departing member's name), `reason` (`removed` or `exited`).
""", .disabled("not yet implemented"))
    func team_5_3() async throws { }

}
