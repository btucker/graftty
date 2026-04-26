# Claude Agent Teams — Design Specification

A new Graftty feature that turns a cluster of worktrees into a **Claude agent team**: one lead session in the user's coordinator worktree, one teammate session per other worktree, with the team's worktrees grouped together in the sidebar. Communication between the lead and its teammates happens through the agent-teams machinery already built into Claude Code (shared `~/.claude/teams/<name>/config.json`, mailbox, `SendMessage`); Graftty's job is to author the team file, launch each pane's `claude --team-name <name> --name <member>`, and notify the lead about membership and PR-merge events through the existing `graftty-channel` MCP path.

## Goal

After this ships, this user story works:

> I have a feature epic spread over three branches. First-time setup: I open **Settings → Agent Teams** and turn on **Enable Claude agent teams** (Graftty also turns on Channels for me, since teams ride on the channel pipeline; my Default Command field becomes read-only). Then I right-click my repository's root worktree in the sidebar and pick **"Start Team…"**. The sheet asks for a team name — I type `epic-x`. Graftty opens a fresh pane in the root worktree running `claude --team-name epic-x --name lead --dangerously-load-development-channels server:graftty-channel`; that's my lead. To add a teammate I click the "+" button under the repository (the existing Add Worktree action), fill in the branch name `feature/x-frontend`, and in the sheet's new **Team** section I pick *"Add to team: epic-x"*. The sheet creates the worktree, opens a pane, launches `claude --team-name epic-x --name <member>` in it, and posts a `team_member_joined` channel event to my lead. (Alternatively, in the same sheet I could have picked *"Start new team…"* and the new worktree would have become the lead instead of an existing one.) I repeat for `feature/x-backend` and `feature/x-tests`. The sidebar now clusters all four worktrees under an `epic-x` team header. From my lead I can `@alice` over `SendMessage` and tell her to start. When carol's PR merges, my lead session gets a `team_pr_merged` channel event so I know to `git pull` in my worktree. When the work's done I right-click the team header → **"End Team"** and the cluster collapses.

## Scope

**In scope (v1):**

- A new Graftty Settings pane, **Agent Teams**, with one toggle: *Enable Claude agent teams*. The team feature — every UI element, every CLI subcommand, every channel event below — is **gated** on this toggle. While disabled, none of the surfaces in this design are visible or invokable.
- While enabled, Graftty **manages the default command**: the Default Command field in Settings becomes read-only and Graftty's launcher prepends the team-aware `claude` invocation (including the channel flag) automatically. The user trades default-command flexibility for working team semantics.
- A new sidebar context-menu action **Start Team…** on any worktree row, opening a sheet that asks for a team name and (on confirm) makes that worktree the lead.
- An extension to the existing **Add Worktree** sheet (macOS): a **Team** section with three options — *None* (current behavior), *Start new team…* (the new worktree becomes the team's lead), *Add to team: \<name\>* (the new worktree joins as a coworker).
- A new sidebar context-menu action **End Team** on a team's group header.
- App-side authoring of `~/.claude/teams/<name>/config.json` (create / append member / remove member / delete directory).
- Graftty-side launch of `claude --team-name <name> --name <member>` (plus the channel flag from CHAN-3.1) in each pane Graftty itself opens.
- A `teamName: String?` field on `WorktreeEntry` and a sidebar grouping treatment that visually clusters worktrees with the same `teamName`.
- New channel events delivered via the existing `graftty-channel` MCP server: `team_member_joined`, `team_member_left`, `team_member_status_changed` (idle/exited), `team_pr_merged`, `team_ended`.
- A parallel **`graftty team` CLI** subcommand group (`start`, `add`, `remove`, `end`, `list`) that mirrors every UI action — same socket dispatch, same effect. Useful for scripting; not required for daily use.
- Persistence: team membership survives app restarts via `state.json`.

**Out of scope (v2+):**

- Adding a worktree to a team from the **iOS** or **web** clients. The `POST /worktrees` request shape (WEB-7.2 / IOS-9.3) is unchanged; team parameters are macOS-only for v1.
- Multi-machine teams. The team file is local to `~/.claude/teams/`.
- Plan-approval gating, task-list inspection, or any UI that mirrors Claude Code's internal team-management screens. Graftty surfaces *membership* and *events*; team coordination still happens inside the lead's session.
- Spawning teammates with custom subagent types. v1 always spawns a generic interactive `claude` session; the lead can adjust behavior via `SendMessage` after the fact.
- Cross-team coordination. Graftty supports multiple simultaneous teams but treats each independently.
- A user-customized launch line while team mode is on. v1 takes the simple stance: team mode owns the default command. Power users who need a different invocation should disable team mode.

## Architecture

The team's coordination plane is **Claude Code's own agent-teams machinery** (file at `~/.claude/teams/<name>/config.json`, inboxes at `<name>/inboxes/`). Graftty's contribution is purely additive: it authors the file, spawns the panes, tags worktrees, and pushes channel events. No daemon. No new long-running service. The existing `ChannelRouter` (CHAN-7) is extended with new event types but otherwise unchanged.

```
       ┌── UI ──────────────────┐    ┌── CLI ────────────────────┐
       │ Sidebar context menu   │    │ $ graftty team start X    │
       │ Add Worktree sheet     │    │ $ graftty team add A …    │
       │ Settings → Agent Teams │    │  (parallel surface;       │
       │   toggle               │    │   same handlers)          │
       └──────────┬─────────────┘    └────────────┬──────────────┘
                  │ in-process                    │ unix socket (existing)
                  ▼                               ▼
┌── Graftty.app ──────────────────────────────────────────────────┐
│              (gated on `claudeAgentTeamsEnabled` setting)       │
│                                                                 │
│   ┌──────────────┐    ┌────────────────────┐    ┌─────────────┐ │
│   │ TeamStore    │◀──▶│ TeamConfigWriter   │    │ Sidebar     │ │
│   │ (in-memory)  │    │ (~/.claude/teams/) │    │ (grouped    │ │
│   │              │    └─────────┬──────────┘    │  by team)   │ │
│   │ {name,       │              │               └─────────────┘ │
│   │  worktrees,  │              │ JSON write                    │
│   │  leadPath}   │              ▼                               │
│   └──────┬───────┘    ~/.claude/teams/X/config.json             │
│          │                                                      │
│          │  spawn pane (managed default cmd)                    │
│          ▼                                                      │
│   ┌──────────────────┐                                          │
│   │  pane in wt-A    │  (claude --team-name X --name A          │
│   └──────────────────┘   --dangerously-load-development-…)      │
│                                                                 │
│   ┌──────────────┐    ┌────────────────────┐                    │
│   │ PRStatusStore│───▶│ ChannelRouter      │                    │
│   │ (existing,   │    │ (existing + new    │                    │
│   │  per-wt)     │    │  team_* events)    │                    │
│   └──────────────┘    └─────────┬──────────┘                    │
│                                 │                               │
│                                 ▼                               │
│                        graftty-channel.sock                     │
└────────────────────────────────┼────────────────────────────────┘
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

## Settings & enablement

A new top-level Settings pane, **Agent Teams**, sits alongside the existing **Channels** pane. It contains:

- A single toggle, **Enable Claude agent teams**. Off by default. Persisted to `state.json` (or wherever Channels' `channelsEnabled` lives, for parity).
- A read-only display of the **managed default command** that Graftty will use for new team-aware panes. The user cannot edit it while team mode is on.
- A short explanatory footer noting that this feature requires the Channels feature (CHAN-2.*) and that turning it on auto-enables Channels if not already on.

### Enablement preconditions and side effects

When the user flips **Enable Claude agent teams** to on:

1. If Channels is off, Graftty turns it on as well. (The team feature relies on the channel-flag mechanism to deliver `team_*` events; without Channels, the lead never hears about teammates joining or PRs merging.)
2. The Default Command field on the existing Settings → Default Command pane becomes **read-only**. Any user-customized value is preserved in storage but not applied; while team mode is on, Graftty's launcher emits its managed line instead. Flipping team mode back off restores the user's previous custom default command.
3. The team UI surfaces (Start Team… context menu, Team section in the Add Worktree sheet, End Team header action) become visible.

When team mode is off, none of those surfaces are visible, the Default Command field is editable, and the existing CHAN-2 / CHAN-3 / DefaultCommand semantics apply unchanged.

### Managed default command

While team mode is on, the default command Graftty injects into a new pane depends on whether the pane's worktree has a `teamName`:

- **Worktree has `teamName`**: `claude --team-name <teamName> --name <memberName> --dangerously-load-development-channels server:graftty-channel`. `<memberName>` is read from `TeamStore` and equals the entry that was added when the worktree joined the team.
- **Worktree has no `teamName`**: `claude --dangerously-load-development-channels server:graftty-channel` (the existing channels-aware default). The user can later turn this worktree into a team via Start Team… and the next pane will pick up team flags.

This is the only way claude gets launched while team mode is on — the user cannot type a different command into the Default Command field. (They can still type whatever they want into a manually-opened shell prompt; this only governs Graftty's auto-launched panes.)

## UI surface

All actions below are gated on the **Enable Claude agent teams** toggle being on.

### Start Team… (sidebar context menu)

Right-clicking any worktree row reveals a new menu item, **Start Team…**, when (a) team mode is on and (b) the worktree is not already part of a team. Selecting it presents a small sheet:

- A **Team Name** field, sanitized by the existing `WorktreeNameSanitizer` (GIT-5.1) for consistency.
- A **Start Team** button (disabled while the field is empty after trim, per GIT-5.3).
- A Cancel button.

On submit:

- Errors if the entered name is already in use (file at `~/.claude/teams/<name>/config.json` exists OR `TeamStore` knows about it). The sheet stays open and renders the error inline.
- Otherwise: Graftty creates the team file with this worktree as member 0 (`agentType: lead`, `name: lead`), creates `inboxes/`, adds a `TeamEntry` to `TeamStore`, and stamps the worktree's `teamName`.
- Graftty opens **a new pane** in this worktree (split using the existing pane-add machinery — direction `right` by default) and launches `claude --team-name <name> --name lead --dangerously-load-development-channels server:graftty-channel` in it. Pre-existing panes in this worktree are not touched. The freshly launched team-aware pane is the lead.
- The sidebar regroups the worktree under a new team header (see Sidebar grouping below).

### Add Worktree sheet — Team section (extends GIT-5.* / IOS-9.* / WEB-7.*)

When team mode is on, the macOS Add Worktree sheet (`Sources/Graftty/Views/AddWorktreeSheet.swift`) gets a new **Team** section between the existing Branch field and the Create button. It contains a single picker with three modes:

1. **None (no team)** — current behavior unchanged. The new worktree is created without a `teamName`; the launcher uses the no-team managed default command.
2. **Add to team: \<existing-name\>** — one option per existing team in `TeamStore`. The new worktree is created with `teamName = <name>` and added as a coworker. Graftty appends `{name: <memberName>, agentId, agentType: "coworker"}` to the team file. `<memberName>` is derived from the worktree name (sanitized; GIT-5.1).
3. **Start new team…** — reveals an additional **Team Name** field below the picker (same sanitization rules as Start Team…). The new worktree becomes the lead of the freshly created team.

When the picker is anything other than *None*, the new pane Graftty opens for the worktree on submit launches `claude --team-name <name> --name <memberName> --dangerously-load-development-channels server:graftty-channel`. A `team_member_joined` channel event is pushed to the lead's worktree afterward.

The picker is **only present in the macOS sheet**. The iOS and web sheets (IOS-9, WEB-7) keep their current shape; their `POST /worktrees` requests still take only `{repoPath, worktreeName, branchName}`.

### End Team (team-header context menu)

Right-clicking the team's group header in the sidebar reveals **End Team**. Selecting it shows a confirmation alert (`"This closes all teammate panes and removes the team. Worktrees remain on disk."`). On confirm:

- Closes all panes in every member worktree (lead's worktree is **not** touched — the user's interactive session there is preserved).
- Clears `WorktreeEntry.teamName` from lead and members.
- Removes the `TeamEntry` from `TeamStore`.
- Deletes `~/.claude/teams/<name>/`.
- Pushes a `team_ended` channel event to the lead's worktree (delivered before the lead's pane is left ungrouped).

### Remove member from team (per-worktree context menu)

Right-clicking a non-lead member worktree row, while it's in a team, reveals **Remove from Team**. Selecting it (no confirmation alert — non-destructive) closes the worktree's panes, removes the member from the team file, clears its `teamName`, and pushes `team_member_left` to the lead. The worktree itself remains on disk and in the sidebar (now ungrouped); the user can `git worktree remove` later via the existing context menu (GIT-4.4).

## Parallel CLI surface

A `graftty team` subcommand group, registered alongside `Notify`, `Pane`, `MCPChannel` in `Sources/GrafttyCLI/CLI.swift`. Every CLI action is a 1:1 mirror of a UI action — same socket dispatch, same handler, same effect — so power users can script team operations without clicking. The CLI **respects the same enablement gate**: every team subcommand errors with `team mode is disabled — enable it in Graftty Settings → Agent Teams` when the toggle is off.

| Subcommand                                                          | UI equivalent                                                                                                |
| ------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------ |
| `graftty team start <name>`                                         | Right-click worktree → Start Team… (run from inside the worktree to be the lead).                            |
| `graftty team add <member> --branch <branch> [--from <ref>] [--prompt <text>]` | Add Worktree sheet with Team section set to "Add to team: \<current-team\>" (run from a team's worktree).    |
| `graftty team remove <member>`                                      | Right-click member worktree → Remove from Team.                                                              |
| `graftty team end <name>`                                           | Right-click team header → End Team.                                                                          |
| `graftty team list`                                                 | (no UI equivalent; read-only diagnostic). Prints `<name>  lead=<path>  members=<count>` per line.            |

`--prompt <text>` (on `team add`) is passed through `--append-system-prompt` when the new teammate's pane is launched; the UI sheet does **not** expose this in v1 (room for a future "Initial assignment" text area).

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

Both the UI sheet and the CLI converge on the same app-side handler.

**Origin (UI):** user opens the Add Worktree sheet, fills in branch `feature/x-frontend`, picks **Add to team: epic-x**, hits Create. The view sends `addTeamMember(teamName: "epic-x", memberName: <derived from worktree name>, branch: "feature/x-frontend", fromRef: nil, prompt: nil)` to `AddWorktreeFlow`.

**Origin (CLI):** user runs `graftty team add alice --branch feature/x-frontend --prompt "Build the login form, see issue #112"` from inside any worktree currently in `epic-x`. The CLI resolves the worktree via `WorktreeResolver.resolve()` and sends the same `addTeamMember(...)` socket message.

**App-side handler (shared):**

1. Looks up the team from the caller's `WorktreeEntry.teamName` (CLI) or the picker selection (UI).
2. Runs `git worktree add -b feature/x-frontend <repo>/.worktrees/feature-x-frontend HEAD`. On failure, returns the captured stderr to the originator (parity with `WEB-7.4`); the UI sheet renders it inline, the CLI prints it on stderr and exits non-zero.
3. Appends `{name: "alice", agentId: "alice@epic-x", agentType: "coworker"}` to `~/.claude/teams/epic-x/config.json` atomically (write-temp + rename).
4. Adds the new `WorktreeEntry` to the repo's worktree list, with `teamName: "epic-x"`. Persists `state.json`.
5. Opens a pane in the new worktree. The launcher reads `claudeAgentTeamsEnabled = true` and `teamName = "epic-x"`, so the managed default command is `claude --team-name epic-x --name alice --dangerously-load-development-channels server:graftty-channel`. Appends `--append-system-prompt "<prompt>"` if a prompt was provided (CLI only in v1).
6. Pushes `team_member_joined` to the lead's worktree via `ChannelRouter`.

### A teammate's PR merges

1. Existing `PRStatusStore` polling observes the transition to `.merged` for `feature/x-frontend`.
2. The new `onTransition` callback (see CHAN data flow §) fires with `pr_state_changed`. The existing logic handles the worktree-cleanup dialog.
3. **New code**: a sibling check runs — if the worktree has a `teamName`, also enqueue a `team_pr_merged` event addressed to the **lead's** worktree (not the merged worktree).
4. `ChannelRouter` fans out to the lead's subscriber.
5. Lead's `claude` session sees the channel tag on its next turn and behaves per the user's prompt — typically running `git pull` and reporting what changed.

### Team end during an in-flight PR

1. User right-clicks the team's group header in the sidebar and selects **End Team** (or runs `graftty team end epic-x`) while alice's PR is still under review.
2. The confirmation alert is shown (UI path only); user confirms.
3. App closes panes in alice's, bob's, and carol's worktrees. Panes in the lead's worktree are not touched.
4. Team file deleted. `TeamStore` updated. `WorktreeEntry.teamName` cleared everywhere.
5. `team_ended` event delivered to lead's worktree.
6. Worktrees themselves remain on disk and remain in Graftty's sidebar (now ungrouped). User can `git worktree remove` later via the existing context menu (`GIT-4.4`), or just leave them alone.

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
| `Sources/Graftty/Views/Settings/AgentTeamsSettingsPane.swift` | SwiftUI view for the new Settings pane (toggle + managed-default-command preview + footer). |
| `Sources/Graftty/Views/StartTeamSheet.swift`                  | The "Start Team…" sheet (team-name field + sanitization + create button).        |
| `Sources/Graftty/Views/AddWorktreeSheet+Team.swift`           | Extension to the Add Worktree sheet adding the Team-section picker.              |
| `Sources/Graftty/Sidebar/TeamGroupHeaderView.swift`           | SwiftUI view for the sticky team header label + accent stripe + End Team menu.   |
| `Sources/GrafttyCLI/Team.swift`                               | `graftty team` subcommand (`start`, `add`, `remove`, `end`, `list`).             |
| `Tests/GrafttyKitTests/Teams/TeamStoreTests.swift`            | Add/append/remove/persistence-restore tests.                                     |
| `Tests/GrafttyKitTests/Teams/TeamConfigWriterTests.swift`     | JSON round-trip + atomic-rename tests; conflict-detection tests.                 |
| `Tests/GrafttyKitTests/Teams/TeamPaneLauncherTests.swift`     | Argv-construction tests for both team-aware and non-team default commands.       |
| `Tests/GrafttyCLITests/TeamCLITests.swift`                    | End-to-end CLI tests with a stub socket; gating-when-disabled tests.             |

### Modified files

| File                                                          | Change                                                                           |
| ------------------------------------------------------------- | -------------------------------------------------------------------------------- |
| `Sources/GrafttyKit/Models/WorktreeEntry.swift`               | Add `var teamName: String?`. Codable migration: nil for pre-`TEAM` state files.  |
| `Sources/GrafttyKit/Persistence/StateStore.swift`             | Encode/decode `TeamStore.teams` and `claudeAgentTeamsEnabled` alongside repos.   |
| `Sources/GrafttyKit/PRStatus/PRStatusStore.swift`             | When firing `pr_state_changed` for a worktree whose `teamName != nil`, also enqueue a `team_pr_merged` event addressed to that team's lead. |
| `Sources/GrafttyKit/Channels/ChannelRouter.swift`             | Add the five `team_*` event types to the routing table.                          |
| `Sources/GrafttyKit/DefaultCommandDecision.swift`             | When `claudeAgentTeamsEnabled` is on, ignore the user-stored default command and emit the managed line. Picks the team-aware variant when the worktree's `teamName != nil`, else the no-team channels-aware variant. |
| `Sources/GrafttyKit/Notification/NotificationMessage.swift`   | Add `startTeam`, `addTeamMember`, `removeTeamMember`, `endTeam`, `listTeams` cases. |
| `Sources/Graftty/AddWorktreeFlow.swift`                       | Carry the sheet's Team-picker selection through `git worktree add` → pane spawn → team file mutation → channel event. |
| `Sources/Graftty/Views/AddWorktreeSheet.swift`                | Render the new Team section when team mode is on; pass the selection into `AddWorktreeFlow`. |
| `Sources/Graftty/Views/Settings/DefaultCommandSettingsPane.swift` | Lock the field (read-only + footnote) while team mode is on; show the managed line in dimmed text. |
| `Sources/Graftty/Views/SettingsView.swift`                    | Register `AgentTeamsSettingsPane` alongside Channels and Default Command tabs.   |
| `Sources/Graftty/Sidebar/SidebarView.swift`                   | Apply team grouping (when team mode is on); add Start Team… / Remove from Team / End Team context-menu items. |
| `Sources/Graftty/GrafttyApp.swift`                            | Instantiate `TeamStore` at the same lifecycle point as `RepositoryStore`.        |
| `Sources/GrafttyCLI/CLI.swift`                                | Register `Team` subcommand alongside the existing three.                         |
| `SPECS.md`                                                    | Add the `TEAM-*` section. New requirements `TEAM-1.x` through `TEAM-8.x` (see SPECS reservations below). |

## Open questions

These are flagged for verification during implementation but are not blocking the design.

- **Q1.** Does an interactive `claude --team-name <name>` running in the lead pane automatically pick up *new* members appended to `~/.claude/teams/<name>/config.json` after launch, or does it cache the roster at startup? **Mitigation regardless:** the `team_member_joined` channel event is delivered to the lead's session via the same path that already feeds it PR-state events, so even if the file isn't auto-reloaded, the lead's claude knows about the new member. If the file *is* auto-reloaded, the channel event is just confirmation — harmless.
- **Q2.** Does `--teammate-mode in-process` mean anything for a teammate that's launched standalone (not as a child of a lead's terminal)? Reading the binary suggests it controls *display takeover* of the launching terminal. v1 omits the flag entirely; the teammate's claude will pick its display mode from the session's settings/`teammateMode` default. If this turns out to cause weird behavior in Graftty panes, a follow-up is to set `--teammate-mode in-process` (which should be a no-op when the parent is a Graftty pane host) or a future Graftty-specific value.
- **Q3.** Does `claude --team-name <name>` error or warn if `<name>`'s config file lists this `--name` as `agentType: lead` but a lead already has the file open? Worth verifying — could affect the "user closed lead pane and wants to rejoin" flow.

## SPECS.md identifier reservations

This work introduces a new top-level section `## N. Claude Agent Teams` with subsections covering: settings & enablement (`TEAM-1.*`), data model and persistence (`TEAM-2.*`), UI surfaces — Start Team sheet, Add Worktree sheet Team section, sidebar context menus (`TEAM-3.*`), `graftty team` CLI (`TEAM-4.*`), team config file authoring (`TEAM-5.*`), pane launching with managed default command (`TEAM-6.*`), sidebar grouping visual treatment (`TEAM-7.*`), and team channel events + edge-case behaviors (`TEAM-8.*`). The exact requirement text is added by the implementation PR per the project's CLAUDE.md convention, not by this design doc.
