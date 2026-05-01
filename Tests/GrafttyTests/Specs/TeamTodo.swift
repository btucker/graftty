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
@spec TEAM-1.6: The Agent Teams Settings pane shall expose **two** user-editable Stencil-templated text areas, each pre-populated with a non-empty default (`DefaultPrompts.sessionPrompt` and `DefaultPrompts.eventPrompt`) registered into `UserDefaults.standard` at app startup so non-binding readers see the same default until the user overrides. Clearing a field to the empty string disables that prompt. The first, `teamSessionPrompt` (`@AppStorage("teamSessionPrompt")`, String) — rendered once at session start against the `agent` context; only `agent.branch` and `agent.lead` are meaningful at session start (`agent.this_worktree` and `agent.other_worktree` are always `false`), and the pane's variable-list disclosure deliberately omits the latter two. The rendered text is appended after a blank line to the auto-generated team-aware instructions text returned by `graftty team hook`. The second, `teamPrompt` (`@AppStorage("teamPrompt")`, String) — rendered per inbox-row write against the full four-field `agent` context evaluated against the recipient agent; the rendered text is prepended after a blank line to the inbox row's body before the row is appended to the recipient's `messages.jsonl`. Both templates use the same `agent` struct shape: `branch` (String), `lead` (Bool), `this_worktree` (Bool), `other_worktree` (Bool). The previously-defined `teamLeadPrompt` and `teamCoworkerPrompt` AppStorage keys are removed.
""", .disabled("not yet implemented"))
    func team_1_6() async throws { }

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
@spec TEAM-2.3: A team's *lead* shall be the worktree where `worktree.path == repo.path` (the repository's main checkout per `LAYOUT-2.3`). All other worktrees of the team are *coworkers*.
""", .disabled("not yet implemented"))
    func team_2_3() async throws { }

    @Test("""
@spec TEAM-2.4: Team identity, membership, and lead designation are derived live from `AppState`. The application shall not persist any team-specific data beyond `agentTeamsEnabled` itself.
""", .disabled("not yet implemented"))
    func team_2_4() async throws { }

    @Test("""
@spec TEAM-3.2: The application shall render the *lead variant* of the team-aware instructions when the viewer's worktree is the team's lead (per TEAM-2.3), and the *coworker variant* otherwise. Both variants name the team (by repo display name), the agent (by member name), and list the team's other members by name and worktree.
""", .disabled("not yet implemented"))
    func team_3_2() async throws { }

    @Test("""
@spec TEAM-3.3: Two separate user templates contribute to what each agent sees. **Hook session-start instructions**: the auto-generated team-aware text from `TeamInstructionsRenderer` is followed (after a blank line) by the rendered `teamSessionPrompt` template, evaluated against the agent's session-start context. If the template is empty, whitespace-only after render, or fails to render (Stencil throws), the appended portion is omitted and a render-failure error is logged via `os_log`. **Per inbox-row delivery**: the rendered `teamPrompt` template is rendered into each inbox row's body at write time per recipient (followed by a blank line, prepended to the event body). The same render/empty/failure rules apply. This covers every team event written via `TeamEventDispatcher.dispatchRoutableEvent` — PR/CI/merge events as routed by the matrix, plus `team_message`, `team_member_joined`, and `team_member_left`.
""", .disabled("not yet implemented"))
    func team_3_3() async throws { }

    @Test("""
@spec TEAM-4.1: The application shall provide a CLI subcommand group `graftty team` with two subcommands: `msg <member-name> "<text>"` and `list`.
""", .disabled("not yet implemented"))
    func team_4_1() async throws { }

    @Test("""
@spec TEAM-4.2: `graftty team msg <member-name> "<text>"` shall resolve the calling process's worktree via `WorktreeResolver.resolve()`, look up the team for that worktree, find a teammate matching `<member-name>`, and write a `team_message` inbox row addressed to that teammate's worktree with `from.member = <calling-worktree's member name>` and body `<text>`. The CLI shall exit non-zero with a stderr message if (a) team mode is disabled, (b) the calling worktree has no team, or (c) `<member-name>` is not a teammate of the caller. In case (c) the error shall list the current teammates' member names.
""", .disabled("not yet implemented"))
    func team_4_2() async throws { }

    @Test("""
@spec TEAM-4.3: `graftty team list` shall print one line per team member of the caller's team to stdout: `<member-name>  branch=<branch>  worktree=<path>  role=<lead|coworker>  running=<true|false>`. The first printed line shall be a header `team=<repo-display-name>  members=<count>`. The CLI shall exit non-zero with a stderr message if team mode is disabled or the calling worktree has no team.
""", .disabled("not yet implemented"))
    func team_4_3() async throws { }

    @Test("""
@spec TEAM-5.2: The application shall write a `team_member_joined` inbox row when a worktree is added to a team (a new worktree appears in a team-enabled repo, or a single-worktree repo gains a second worktree). Routing: addressed to the team's lead's worktree only. Attributes: `team`, `member` (joiner's member name), `branch`, `worktree` (joiner's path).
""", .disabled("not yet implemented"))
    func team_5_2() async throws { }

    @Test("""
@spec TEAM-5.3: The application shall write a `team_member_left` inbox row when a worktree is removed from a team (the worktree is deleted, or the team-enabled repo collapses to one worktree). Routing: addressed to the team's lead's worktree only. Attributes: `team`, `member` (departing member's name), `reason` (`removed` or `exited`).
""", .disabled("not yet implemented"))
    func team_5_3() async throws { }

    @Test("""
@spec TEAM-6.1: While `agentTeamsEnabled` is true and a `RepoEntry` has two or more worktrees, the sidebar shall render that repo with a small "team" icon (SF Symbol `person.2.fill`) adjacent to its disclosure header. No per-worktree accent stripe is applied; the header icon is sufficient to indicate team membership.
""", .disabled("not yet implemented"))
    func team_6_1() async throws { }

    @Test("""
@spec TEAM-6.2: Right-clicking any team-enabled worktree's row shall include a *Show Team Members…* context-menu item. Selecting it shall display a popover listing each team member by name, branch, and role (lead / coworker), populated from the same source as `graftty team list`.
""", .disabled("not yet implemented"))
    func team_6_2() async throws { }
}
