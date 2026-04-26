# Claude Agent Teams — Design Specification

A new Graftty feature that turns a cluster of worktrees into a **Claude agent team**: one lead session in the user's coordinator worktree, one teammate session per other worktree, with the team's worktrees grouped together in the sidebar. Communication between the lead and its teammates happens through the agent-teams machinery already built into Claude Code (shared `~/.claude/teams/<name>/config.json`, mailbox, `SendMessage`); Graftty's job is to author the team file, launch each pane's `claude --team-name <name> --name <member>`, and notify the lead about membership and PR-merge events through the existing `graftty-channel` MCP path.

## Goal

After this ships, this user story works:

> I have a feature epic spread over three branches. I open Graftty in my coordinator worktree, run `graftty team start epic-x`, then start my lead by running the launch command Graftty just printed: `claude --team-name epic-x --name lead --dangerously-load-development-channels server:graftty-channel`. Then from a shell in any pane I run `graftty team add alice --branch feature/x-frontend`, `graftty team add bob --branch feature/x-backend`, `graftty team add carol --branch feature/x-tests`. Graftty creates three worktrees, opens a pane and launches `claude` in each, and posts a channel event to my lead. The sidebar now shows all four worktrees clustered under an "epic-x" team header. From my lead I can `@alice` over `SendMessage` and tell her to start. When carol's PR merges, my lead session gets a `team_pr_merged` channel event so I know to `git pull` in my worktree. When the work's done I run `graftty team end epic-x` and the cluster collapses.

## Scope

**In scope (v1):**

- A `graftty team` CLI subcommand group: `start`, `add`, `remove`, `end`, `list`.
- App-side authoring of `~/.claude/teams/<name>/config.json` (create / append member / remove member / delete directory).
- Graftty-side launch of `claude --team-name <name> --name <member>` (plus the channel flag from CHAN-3.1) in each new pane.
- A `teamName: String?` field on `WorktreeEntry` and a sidebar grouping treatment that visually clusters worktrees with the same `teamName`.
- New channel events delivered via the existing `graftty-channel` MCP server: `team_member_joined`, `team_member_left`, `team_member_status_changed` (idle/exited), `team_pr_merged`, `team_ended`.
- Persistence: team membership survives app restarts via `state.json`.

**Out of scope (v2+):**

- A built-in UI for "add a teammate" — v1 is CLI-only. The sidebar shows the team but has no plus-button affordance. (Future: a sidebar context-menu action.)
- Multiple simultaneous teams in the same Graftty window. v1 supports any number, but the sidebar grouping treats each independently — there is no cross-team coordination.
- Graftty managing the lead's launch flags. The user is responsible for starting `claude` in their coordinator worktree with the right flags (or leaning on `--worktree`-based defaults).
- Plan-approval gating, task-list inspection, or any UI that mirrors Claude Code's internal team-management screens. Graftty surfaces *membership* and *events*; team coordination still happens inside the lead's session.
- Cross-machine teams. The team file is local to `~/.claude/teams/`.
- Spawning teammates with custom subagent types. v1 always spawns a generic interactive `claude` session; the lead can adjust behavior via `SendMessage` after the fact.

## Architecture

The team's coordination plane is **Claude Code's own agent-teams machinery** (file at `~/.claude/teams/<name>/config.json`, inboxes at `<name>/inboxes/`). Graftty's contribution is purely additive: it authors the file, spawns the panes, tags worktrees, and pushes channel events. No daemon. No new long-running service. The existing `ChannelRouter` (CHAN-7) is extended with new event types but otherwise unchanged.

```
                     ┌── User opens lead pane ──┐
                     │  $ graftty team start X  │
                     │  $ graftty team add A …  │
                     └────────────┬─────────────┘
                                  │ unix socket (existing)
┌── Graftty.app ──────────────────┼──────────────────────────────┐
│                                 ▼                              │
│   ┌──────────────┐    ┌────────────────────┐    ┌────────────┐ │
│   │ TeamStore    │◀──▶│ TeamConfigWriter   │    │ Sidebar    │ │
│   │ (in-memory)  │    │ (~/.claude/teams/) │    │ (grouped   │ │
│   │              │    └─────────┬──────────┘    │  by team)  │ │
│   │ {name,       │              │               └────────────┘ │
│   │  worktrees,  │              │ JSON write                   │
│   │  leadPath}   │              ▼                              │
│   └──────┬───────┘    ~/.claude/teams/X/config.json            │
│          │                                                     │
│          │  spawn pane                                         │
│          ▼                                                     │
│   ┌──────────────────┐                                         │
│   │  pane in wt-A    │   (cmd: claude --team-name X --name A)  │
│   └──────────────────┘                                         │
│                                                                │
│   ┌──────────────┐    ┌────────────────────┐                   │
│   │ PRStatusStore│───▶│ ChannelRouter      │                   │
│   │ (existing,   │    │ (existing + new    │                   │
│   │  per-wt)     │    │  team_* events)    │                   │
│   └──────────────┘    └─────────┬──────────┘                   │
│                                 │                              │
│                                 ▼                              │
│                        graftty-channel.sock                    │
└────────────────────────────────┼───────────────────────────────┘
                                 │
                                 ▼
                ┌────────────────────────────────┐
                │ lead's claude session          │
                │ (subscribed to channel events) │
                │ knows: team membership,        │
                │        teammate idle/exit,     │
                │        teammate PR merges      │
                └────────────────────────────────┘
```

### Why this shape

- **Claude does the hard part.** The mailbox, `SendMessage`, `team_name`-aware Agent-tool gating, and the per-team task list are all already in Claude Code. We don't reimplement any of that.
- **Each pane is an independent interactive `claude`.** No headless mode, no daemon shelling out. The pane is exactly what a user would manually type.
- **The team file is plain JSON.** Schema verified against existing midtown teams under `~/.claude/teams/`: `{members: [{name, agentId, agentType}]}`. Graftty appends/removes members in place; no claude session needs to know Graftty exists.
- **Channel events use the path that's already wired up.** CHAN-* already gets PR-state events into running claudes. Adding `team_*` event types is a new payload in the same pipeline — no new MCP server, no new socket.
- **Persistence stays in `state.json`.** The same place repos and worktrees already live; LAYOUT-4.* recovery semantics extend to teams without a separate store.

## Data model

### In-memory (`GrafttyKit/Teams/TeamStore.swift`)

```swift
struct TeamEntry: Codable, Identifiable {
    let name: String              // e.g. "epic-x" — also the team-name on disk
    var leadWorktreePath: String  // absolute path; lead is implicit member 0
    var memberWorktreePaths: [String]  // ordered; sidebar renders in this order
    var createdAt: Date
}

@MainActor
final class TeamStore: ObservableObject {
    @Published private(set) var teams: [TeamEntry]   // persisted to state.json
    func teamFor(worktreePath: String) -> TeamEntry?
    func add(team: TeamEntry)
    func append(member: String /* worktree path */, to teamName: String) throws
    func remove(member: String, from teamName: String) throws
    func remove(team: String) throws
}
```

### On `WorktreeEntry`

Add one field: `var teamName: String?`. Set when the worktree joins a team; cleared on `team remove` or `team end`. The sidebar's grouping logic reads this.

### On disk (`~/.claude/teams/<name>/config.json`)

Schema (matches existing midtown convention, verified by inspecting `~/.claude/teams/midtown-ravioli/config.json`):

```json
{
  "members": [
    {"name": "lead",  "agentId": "lead@<team-name>",  "agentType": "lead"},
    {"name": "alice", "agentId": "alice@<team-name>", "agentType": "coworker"}
  ]
}
```

The `inboxes/` subdirectory is created empty; Claude Code populates it as `SendMessage` traffic flows. We do not touch its contents.

## CLI surface

A new subcommand group registered alongside `Notify`, `Pane`, `MCPChannel` in `Sources/GrafttyCLI/CLI.swift`.

### `graftty team start <name>`

Run from the worktree the user wants as the team's coordinator (lead).

- Errors if `<name>` is already in use (file at `~/.claude/teams/<name>/config.json` exists OR `TeamStore` knows about it).
- Errors if the current worktree is already in another team.
- Creates `~/.claude/teams/<name>/config.json` with the lead as member 0, `agentType: lead`, `name: lead`.
- Creates `~/.claude/teams/<name>/inboxes/`.
- Adds a `TeamEntry` to `TeamStore` and stamps the current `WorktreeEntry.teamName`.
- **Does not launch the lead.** v1 assumes the user starts `claude` in the coordinator pane themselves *after* running this command. The CLI prints the exact launch line they need: `claude --team-name <name> --name lead --dangerously-load-development-channels server:graftty-channel`. (If the user runs `team start` while a lead claude is already running without `--team-name`, that running session is not part of the team — they'd need to `/quit` and relaunch with the flags. Graftty does not auto-restart their session.)

### `graftty team add <member-name> --branch <branch> [--from <ref>] [--prompt <text>]`

Run from any worktree that already belongs to a team.

- `--branch <branch>` is required. Mirrors `WEB-7.2`'s `branchName`.
- `--from <ref>` is optional; defaults to the lead worktree's `HEAD`. Passed to `git worktree add -b <branch> <path> <ref>`.
- `--prompt <text>` is the initial assignment given to the new teammate via `--append-system-prompt`.
- Creates a sibling worktree under the repository's existing `<repo>/.worktrees/<branch>/` convention (same as `IOS-9.3`).
- Appends `{name: <member-name>, agentId: <member-name>@<team-name>, agentType: "coworker"}` to the team file.
- Updates `TeamStore` and stamps the new `WorktreeEntry.teamName`.
- Opens a pane in the new worktree and launches `claude --team-name <team-name> --name <member-name> --dangerously-load-development-channels server:graftty-channel --append-system-prompt "<prompt>"` (the trailing prompt is omitted when `--prompt` isn't passed).
- Pushes a `team_member_joined` channel event to the lead's worktree.

### `graftty team remove <member-name>`

Run from any worktree that belongs to the same team.

- Closes the panes in the member's worktree (existing pane-stop machinery).
- Removes the member from the team file.
- Clears `WorktreeEntry.teamName` for that worktree.
- Pushes `team_member_left` to the lead.
- **Does not** `git worktree remove` automatically. The user can always do it via the existing sidebar context menu (`GIT-4.4`) once they're satisfied with the work; auto-removal would conflict with the post-merge cleanup dialog (`PR-* / GIT-4.*`).

### `graftty team end <name>`

Run from anywhere.

- Closes panes in every member worktree of the team. Panes in the lead's worktree are left alone (they belong to the user's interactive session).
- Removes `WorktreeEntry.teamName` from the lead and all members.
- Removes the `TeamEntry` from `TeamStore`.
- Deletes `~/.claude/teams/<name>/` (the directory and its inboxes).
- Pushes `team_ended` to the lead.

### `graftty team list`

Prints a one-team-per-line summary: `<name>  lead=<path>  members=<count>`. Read-only; for scripting and diagnostic use.

## Sidebar grouping (LAYOUT extension)

A new visual treatment applied **inside** the existing repository → worktree hierarchy. Worktrees in the same team get a colored left-edge stripe (one accent color per active team, consistent across the worktree's row and its pane sub-rows) and a sticky team header label rendered immediately above the group.

- A worktree without a `teamName` renders unchanged.
- A team's worktrees are reordered to be contiguous within the repository, with the lead first and members in `TeamStore` order. Other worktrees in the repo retain their alphabetical position around the team block.
- The header label is the team name, dimmed, with a tiny "team" icon. Right-clicking the header reveals a context menu: "End Team" (`graftty team end`) and "Copy Team Name."
- The accent color is deterministically derived from the team name (hash → color palette index). Stable across restarts.

Existing LAYOUT-2.x rules continue to apply unchanged within a team's worktree rows.

## Channel events (extends CHAN-* / `notifications/claude/channel`)

Five new event types are introduced into the existing `graftty-channel` MCP path. Each follows the same wrapper as the existing CHAN events; only `type` and `attrs` differ.

### `team_member_joined`

Fired when `graftty team add` succeeds. Delivered to the lead's worktree only.

| Attribute       | Example                                       |
| --------------- | --------------------------------------------- |
| `team`          | `epic-x`                                      |
| `member`        | `alice`                                       |
| `worktree`      | `/repos/acme/.worktrees/feature-x-frontend`   |
| `branch`        | `feature/x-frontend`                          |
| `assignment`    | (the `--prompt` text, if provided)            |

Body: `Teammate "alice" joined team "epic-x" working on feature/x-frontend.`

### `team_member_left`

Fired by `graftty team remove` *and* by abnormal pane exit (the pane's terminal process closes for any reason while the worktree is part of a team).

| Attribute     | Example                                       |
| ------------- | --------------------------------------------- |
| `team`        | `epic-x`                                      |
| `member`      | `alice`                                       |
| `reason`      | `removed`, `exited`                           |

### `team_member_status_changed`

Fired when a teammate's pane goes quiet (no shell-integration activity for >30s) or comes back active. Mirrors the agent-teams "idle notification" model but at the Graftty pane level — it tells the lead what's *happening in the terminal*, not what the claude inside it claims.

| Attribute    | Example          |
| ------------ | ---------------- |
| `team`       | `epic-x`         |
| `member`     | `alice`          |
| `status`     | `idle`, `active` |

### `team_pr_merged`

Fired when `PRStatusStore` observes a transition to `.merged` for a worktree whose `teamName` is set. Delivered to the **lead's** worktree (not the merged branch's worktree, which is about to disappear anyway). This is the event that fulfills the user's stated goal of "lead knows when to pull."

| Attribute    | Example                                       |
| ------------ | --------------------------------------------- |
| `team`       | `epic-x`                                      |
| `member`     | `alice`                                       |
| `pr_number`  | `42`                                          |
| `branch`     | `feature/x-frontend`                          |
| `merge_sha`  | `abc1234…`                                    |

Body: `Teammate "alice"'s PR #42 (feature/x-frontend) merged. You may want to git pull in your worktree.`

### `team_ended`

Fired by `graftty team end`. Delivered to the lead's worktree only. The lead's session can use this to wrap up its own bookkeeping.

| Attribute   | Example       |
| ----------- | ------------- |
| `team`      | `epic-x`      |
| `members`   | `["alice","bob","carol"]` |

## Data flows

### Adding a teammate

1. User runs `graftty team add alice --branch feature/x-frontend --prompt "Build the login form, see issue #112"` from inside the lead's worktree.
2. CLI resolves the current worktree path via `WorktreeResolver.resolve()` (existing).
3. CLI sends `addTeamMember(teamName, memberName, branch, fromRef, prompt)` to the app over the existing socket.
4. App-side handler (`TeamStore.append`):
   - Looks up the team from `WorktreeEntry.teamName` of the caller's worktree.
   - Runs `git worktree add -b feature/x-frontend <repo>/.worktrees/feature-x-frontend HEAD`. On failure, returns the captured stderr to the CLI (parity with `WEB-7.4`).
   - Appends to `~/.claude/teams/epic-x/config.json` atomically (write-temp + rename).
   - Adds the new `WorktreeEntry` to the repo's worktree list, with `teamName: "epic-x"`.
   - Persists `state.json`.
   - Opens a pane in the new worktree and launches `claude --team-name epic-x --name alice --dangerously-load-development-channels server:graftty-channel --append-system-prompt "Build the login form, see issue #112"`.
   - Pushes `team_member_joined` to the lead's worktree via `ChannelRouter`.
5. CLI exits 0.

### A teammate's PR merges

1. Existing `PRStatusStore` polling observes the transition to `.merged` for `feature/x-frontend`.
2. The new `onTransition` callback (see CHAN data flow §) fires with `pr_state_changed`. The existing logic handles the worktree-cleanup dialog.
3. **New code**: a sibling check runs — if the worktree has a `teamName`, also enqueue a `team_pr_merged` event addressed to the **lead's** worktree (not the merged worktree).
4. `ChannelRouter` fans out to the lead's subscriber.
5. Lead's `claude` session sees the channel tag on its next turn and behaves per the user's prompt — typically running `git pull` and reporting what changed.

### Team end during an in-flight PR

1. User runs `graftty team end epic-x` while alice's PR is still under review.
2. App closes alice's pane (and bob's, carol's). Lead's pane untouched.
3. Team file deleted. `TeamStore` updated. `WorktreeEntry.teamName` cleared everywhere.
4. `team_ended` event delivered to lead.
5. Worktrees themselves remain on disk and remain in Graftty's sidebar (now ungrouped). User can `git worktree remove` later via the existing context menu, or just leave them alone.

## Persistence (extends PERSIST-*)

`TeamStore.teams` is appended to `state.json`. On restore (LAYOUT-4.*-style):

1. For each persisted team, verify `~/.claude/teams/<name>/config.json` still exists. If not, the team is dropped (orphaned because the user manually deleted the file or copied state.json across machines).
2. For each member worktree, verify the `WorktreeEntry` resolves on disk (existing GIT-3.* and bookmark cascades apply). If a member worktree is now missing, drop just that member from `TeamStore` and append a `team_member_left` event with `reason: stale` for the next session start.
3. The lead worktree must resolve. If it doesn't, the entire team is dropped.

Teams are not auto-relaunched on app startup (the panes inside are; the team metadata just survives).

## Edge cases

- **User runs `graftty team start` with `<name>` matching a team that's already on disk but unknown to `TeamStore`** (e.g., an orphaned midtown team or stale state). CLI errors with the conflicting path; the user can rename or `rm -rf` manually.
- **User manually edits `~/.claude/teams/<name>/config.json`** to add a member Graftty doesn't know about. Graftty does not poll the file; the next `graftty team add` will *append* and may reintroduce duplicate names. v1 accepts this footgun; v2 may add a verify-then-merge step.
- **Lead pane is closed by the user** (Cmd+W on the pane, or shell `exit`). The team is **not** auto-disbanded. A team without a live lead pane still exists; the user can re-`claude --team-name <name> --name lead` to rejoin. The sidebar grouping continues to render.
- **Member pane crashes.** Graftty fires `team_member_left` with `reason: exited`. The team file is *not* updated — the member entry stays so the lead can `SendMessage` to a future restart with the same name. v1 leaves cleanup to the user; the sidebar shows the worktree as `closed` per STATE-1.2, still grouped under the team.
- **Two teams in the same repository.** Supported. Each team gets its own accent stripe and header. The repository's worktree ordering interleaves teams' contiguous blocks alphabetically by team name; non-team worktrees keep their existing alphabetical positions.
- **`graftty team add` invoked from a worktree that isn't part of any team.** Errors with `not part of a team — run 'graftty team start' first`.
- **Team name conflicts with existing midtown team prefix.** Graftty refuses any name starting with `midtown-` to avoid stomping the user's existing midtown teams. (Defensive — there's no functional collision since the file paths would differ, but the namespace pollution is bad UX.)
- **Channel feature disabled** (CHAN-2.x). The team CLI still works; the configuration page surfaces the channel-flag reminder more loudly. Without channels, the lead doesn't get notified of PR merges or member status changes — the user has to look at the sidebar. v1 does not block team usage on channels being on.

## Components

### New files

| File                                                          | Purpose                                                                          |
| ------------------------------------------------------------- | -------------------------------------------------------------------------------- |
| `Sources/GrafttyKit/Teams/TeamStore.swift`                    | In-memory team registry + state.json codability.                                 |
| `Sources/GrafttyKit/Teams/TeamConfigWriter.swift`             | Writes/mutates `~/.claude/teams/<name>/config.json` atomically.                  |
| `Sources/GrafttyKit/Teams/TeamPaneLauncher.swift`             | Builds the `claude --team-name … --name … …` argv and hands off to existing pane-spawn machinery. |
| `Sources/GrafttyKit/Teams/TeamChannelEvents.swift`            | `Codable` types for the five new `team_*` events.                                |
| `Sources/Graftty/Sidebar/TeamGroupHeaderView.swift`           | SwiftUI view for the sticky team header label + accent stripe.                   |
| `Sources/GrafttyCLI/Team.swift`                               | `graftty team` subcommand (`start`, `add`, `remove`, `end`, `list`).             |
| `Tests/GrafttyKitTests/Teams/TeamStoreTests.swift`            | Add/append/remove/persistence-restore tests.                                     |
| `Tests/GrafttyKitTests/Teams/TeamConfigWriterTests.swift`     | JSON round-trip + atomic-rename tests; conflict-detection tests.                 |
| `Tests/GrafttyCLITests/TeamCLITests.swift`                    | End-to-end CLI tests with a stub socket.                                         |

### Modified files

| File                                                          | Change                                                                           |
| ------------------------------------------------------------- | -------------------------------------------------------------------------------- |
| `Sources/GrafttyKit/Models/WorktreeEntry.swift`               | Add `var teamName: String?`. Codable migration: nil for pre-`TEAM` state files.  |
| `Sources/GrafttyKit/Persistence/StateStore.swift`             | Encode/decode `TeamStore.teams` alongside repos.                                 |
| `Sources/GrafttyKit/PRStatus/PRStatusStore.swift`             | When firing `pr_state_changed` for a worktree whose `teamName != nil`, also enqueue a `team_pr_merged` event addressed to that team's lead. |
| `Sources/GrafttyKit/Channels/ChannelRouter.swift`             | Add the five `team_*` event types to the routing table.                          |
| `Sources/GrafttyKit/Notification/NotificationMessage.swift`   | Add `addTeamMember`, `removeTeamMember`, `startTeam`, `endTeam`, `listTeams` cases. |
| `Sources/Graftty/Sidebar/SidebarView.swift`                   | Apply team grouping per LAYOUT extension (above).                                |
| `Sources/Graftty/GrafttyApp.swift`                            | Instantiate `TeamStore` at the same lifecycle point as `RepositoryStore`.        |
| `Sources/GrafttyCLI/CLI.swift`                                | Register `Team` subcommand alongside the existing three.                         |
| `SPECS.md`                                                    | Add the `TEAM-*` section. New requirements `TEAM-1.x` through `TEAM-7.x`.        |

## Open questions

These are flagged for verification during implementation but are not blocking the design.

- **Q1.** Does an interactive `claude --team-name <name>` running in the lead pane automatically pick up *new* members appended to `~/.claude/teams/<name>/config.json` after launch, or does it cache the roster at startup? **Mitigation regardless:** the `team_member_joined` channel event is delivered to the lead's session via the same path that already feeds it PR-state events, so even if the file isn't auto-reloaded, the lead's claude knows about the new member. If the file *is* auto-reloaded, the channel event is just confirmation — harmless.
- **Q2.** Does `--teammate-mode in-process` mean anything for a teammate that's launched standalone (not as a child of a lead's terminal)? Reading the binary suggests it controls *display takeover* of the launching terminal. v1 omits the flag entirely; the teammate's claude will pick its display mode from the session's settings/`teammateMode` default. If this turns out to cause weird behavior in Graftty panes, a follow-up is to set `--teammate-mode in-process` (which should be a no-op when the parent is a Graftty pane host) or a future Graftty-specific value.
- **Q3.** Does `claude --team-name <name>` error or warn if `<name>`'s config file lists this `--name` as `agentType: lead` but a lead already has the file open? Worth verifying — could affect the "user closed lead pane and wants to rejoin" flow.

## SPECS.md identifier reservations

This work introduces a new top-level section `## N. Claude Agent Teams` with subsections covering: data model and persistence (`TEAM-1.*`), `graftty team` CLI (`TEAM-2.*`), team config file authoring (`TEAM-3.*`), pane launching (`TEAM-4.*`), sidebar grouping (`TEAM-5.*`), team channel events (`TEAM-6.*`), and edge-case behaviors (`TEAM-7.*`). The exact requirement text is added by the implementation PR per the project's CLAUDE.md convention, not by this design doc.
