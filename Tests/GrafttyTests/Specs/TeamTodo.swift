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
@spec TEAM-1.6: The Agent Teams Settings pane shall expose **two** user-editable Stencil-templated text areas registered into `UserDefaults.standard` at app startup so non-binding readers see the same defaults until the user overrides. Clearing a field to the empty string disables that prompt. The first, `teamSessionPrompt` (`@AppStorage("teamSessionPrompt")`, String), defaults to empty because the auto-generated team-aware instructions already include stable session context; when non-empty, it is rendered once at session start against the `agent` context. Only `agent.branch` and `agent.main_worktree` are meaningful at session start (`agent.this_worktree` and `agent.other_worktree` are always `false`), and the pane's variable-list disclosure deliberately omits the latter two. The rendered text is appended after a blank line to the auto-generated team-aware instructions text returned by `graftty team hook`. The second, `teamPrompt` (`@AppStorage("teamPrompt")`, String), is pre-populated with a non-empty default (`DefaultPrompts.eventPrompt`) and rendered for each automated-event inbox-row write against the full four-field `agent` context evaluated against the recipient agent, plus a top-level `body` variable carrying the original event body and a top-level `event` object exposing `event.type` (the wire-format event-type string, e.g. `"merge_state_changed"`), `event.attrs` (the event's attribute dictionary), and `event.body` (a duplicate of the top-level `body`). Authored `team_message` rows bypass this template and store no `agent_prompt`. The rendered automated-event output is stored in the inbox row's `agent_prompt` field. If the template does not reference `{{ body }}` the renderer appends `\n\n{{ body }}` to the template before rendering, so templates that pre-date the `body` variable continue to surface the event content to the agent. Hook-context delivery (via `TeamHookRenderer.format`) emits authored messages as a compact `worktree message from <address>:` envelope using the raw `body`; the address is a stable reply address documented in the session primer. For automated events it emits `agent_prompt` when present and falls through to `body` otherwise. The inbox row's `body` field stores content unchanged so consumers other than the agent (activity log, `graftty team inbox`, watcher wake summaries) read it without the template prelude. Both templates use the same `agent` struct shape: `branch` (String), `main_worktree` (Bool), `this_worktree` (Bool), `other_worktree` (Bool). Previously-defined role-specific prompt keys are removed.
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
@spec TEAM-2.3: A team's main worktree shall be the worktree where `worktree.path == repo.path` (the repository's main checkout per `LAYOUT-2.3`). Every other member is a linked worktree.
""", .disabled("not yet implemented"))
    func team_2_3() async throws { }

    @Test("""
@spec TEAM-2.4: Team identity, membership, and main-worktree designation are derived live from `AppState`. The application shall not persist any team-specific data beyond `agentTeamsEnabled` itself.
""", .disabled("not yet implemented"))
    func team_2_4() async throws { }

    @Test("""
@spec TEAM-3.2: The application shall render the main-worktree variant of the team-aware instructions when the viewer's worktree is the repository's main worktree (per TEAM-2.3), and the linked-worktree variant otherwise. Both variants name the team (by repo display name), the agent (by member name), and list the team's other members by name and worktree.
""", .disabled("not yet implemented"))
    func team_3_2() async throws { }

    @Test("""
@spec TEAM-3.3: Two separate user templates contribute to what each agent sees. **Hook session-start instructions**: the auto-generated team-aware text from `TeamInstructionsRenderer` is followed (after a blank line) by the rendered `teamSessionPrompt` template, evaluated against the agent's session-start context. If the template is empty, whitespace-only after render, or fails to render (Stencil throws), the appended portion is omitted and a render-failure error is logged via `os_log`. **Per automated-event delivery**: the rendered `teamPrompt` template is stored separately from the unchanged event body at write time per recipient. The same render/empty/failure rules apply. This covers PR/CI/merge events routed by `TeamEventDispatcher.dispatchRoutableEvent`, plus `team_member_joined` and `team_member_left`; authored `team_message` rows bypass the automated-event template.
""", .disabled("not yet implemented"))
    func team_3_3() async throws { }

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
