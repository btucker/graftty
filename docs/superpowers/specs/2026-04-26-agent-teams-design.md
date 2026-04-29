# Agent Teams — Design Specification

A new Graftty feature that turns every Claude session in a repo into a member of an implicit team, with the **repo's root worktree** (the main checkout, LAYOUT-2.3) acting as the team's **lead**. When the **Enable agent teams** Settings toggle is on, every claude pane Graftty auto-launches connects to the existing `graftty-channel` MCP server (CHAN-*); that server's `initialize` response carries `instructions` naming the agent and its peers, telling it whether it's the lead or a coworker, and teaching it to message teammates via `graftty team msg <member> "<text>"`. Cross-pane delivery rides the same channel as new `team_*` event types. **Status events** (member joined / left / PR merged) route to the **lead only**, which can choose to redistribute to coworkers via direct messages. **Direct messages** between any two members stay point-to-point. There is no team-naming UI, no "start team" flow — the lead is implicit (the root worktree) and team membership is implicit (every worktree of a team-enabled repo).

## Goal

After this ships, this user story works:

> I open **Settings → Agent Teams** and turn on **Enable agent teams** (Graftty also turns on Channels; my Default Command field becomes read-only). My main checkout's pane is now the **lead**. I click **+** to add a worktree on `feature/login`; the new pane's claude connects to its own `graftty-channel` MCP subprocess, which on init reports: *"you're 'feature-login' (a coworker) on team 'acme-web'; your lead is 'main'; here's how to send a message to a teammate."* My lead's pane simultaneously gets a `team_member_joined` channel event for `feature-login`. I tell my lead's claude my coordination policy in plain conversation — e.g., *"please ask each coworker for a status update every 15 minutes"* or *"keep coworkers in sync on PR merges"* — and from there the agents decide when to message each other. When alice's PR merges, **only the lead** gets a `team_pr_merged` event; what the lead does with it (pull, broadcast, ignore, prompt for input) is governed by my conversation with it, not by Graftty.

## Scope

**In scope (v1):**

- A new Graftty Settings pane, **Agent Teams**, with one global toggle: *Enable agent teams*. Off by default. Every team behavior below is gated on this toggle.
- While enabled, Graftty **manages the default command** for every auto-launched pane: `claude --dangerously-load-development-channels server:graftty-channel`. (Identical to the channels-only line — no `--append-system-prompt` ever; team awareness is delivered through the MCP server's `instructions` field instead.) The Default Command field in Settings becomes read-only.
- A **purely-mechanistic** MCP-instructions template with two variants — *lead* and *coworker* — that the `graftty mcp-channel` subprocess renders dynamically at MCP `initialize` time. The instructions describe *what* the agent has access to (peers, the `graftty team msg` command, the channel events it will receive) and *nothing about when or whether to use them*. Coordination policy — when to message the lead, what to do on a PR merge, whether to pull, whether to broadcast — is the user's to define, through normal interaction with the agent or through project files like `CLAUDE.md` / `AGENTS.md`. The subprocess fetches its data over the existing app socket so it sees the live worktree list.
- New channel events delivered via the existing `graftty-channel` MCP server: `team_message` (point-to-point, sender → recipient), `team_member_joined` / `team_member_left` / `team_pr_merged` (status events, routed **to the lead only** — the lead can redistribute via direct messages if its user-defined policy says so).
- A `graftty team` CLI subcommand group with two members: `msg <member> "<text>"` (the agent-to-agent messaging primitive used from inside a session via Bash) and `list` (read-only diagnostic).
- A sidebar grouping treatment that visually clusters the worktrees of a team-enabled repo with an accent stripe and a small "team" header.
- Persistence: nothing new beyond the global toggle in `state.json`. Membership is derived from the live worktree list at all times.

**Out of scope (v2+):**

- Per-repo opt-out (a checkbox to mark a specific repo as not-a-team while team mode is on globally). v1 is all-or-nothing.
- Per-worktree opt-out (a checkbox in the Add Worktree sheet to make this one worktree non-team). v1 has no Team picker; every worktree of a team-enabled repo is in.
- Cross-repo teams. A team is implicitly scoped to one repository.
- Manually choosing a team name. The team's identity is the repo's identity.
- The agent-teams orchestration features in Claude Code (plan approval, shared task list, agent-spawn-via-Agent-tool, etc.). We do not use Claude's experimental `--team-name` machinery.
- Iterating with non-Claude agents. The architecture is vendor-neutral at the team layer (it's just shell + MCP channels), but the channel push remains Claude-specific in v1; codex/qwen-code support is a follow-up.
- A user-customized launch line while team mode is on. v1 takes the simple stance: team mode owns the default command. Power users who need a different invocation should disable team mode.

## Architecture

A team is implicit in a repo's worktree list. Coordination happens via two existing primitives — shell commands (the agent runs `graftty team msg <member> "<text>"` from inside its session) and MCP channels (Graftty pushes a `team_message` event to the recipient's pane). No `~/.claude/teams/` file. No daemon. No new long-running service. No `TeamStore` registry — the data model is the repo's `WorktreeEntry` list, plus a `claudeAgentTeamsEnabled` global flag.

```
       ┌── UI ──────────────────┐    ┌── CLI (used by agents) ───┐
       │ Settings → Agent Teams │    │ $ graftty team msg A "…"  │
       │   toggle (global)      │    │ $ graftty team list       │
       │ Add Worktree (existing │    └────────────┬──────────────┘
       │   sheet, unchanged)    │                 │ unix socket (existing)
       └──────────┬─────────────┘                 ▼
                  │                  ┌─────────────────────────────────┐
                  ▼                  │   GrafttyApp                    │
            settings flag            │ (gated on agentTeamsEnabled)    │
                  │                  │                                 │
                  ▼                  │  ┌────────────────────────┐     │
        DefaultCommandDecision ◀────▶│  │ ChannelRouter          │     │
        (when team mode on,          │  │ (existing + new        │     │
         emit team-aware claude line)│  │  team_* event types)   │     │
                  │                  │  └────────────┬───────────┘     │
                  │                  │               │ socket          │
                  ▼                  │               ▼                 │
        ┌─────────────────┐          │       graftty-channel.sock      │
        │ pane in wt-A    │          │               │                 │
        │ (claude with    │ shell ───┼───────────────┘                 │
        │ team prompt)    │          │  push event                     │
        └────────┬────────┘          └───────────────┬─────────────────┘
                 │                                   │
                 │ agent runs:                       ▼
                 │  $ graftty team msg B "..."     ┌─────────────────────┐
                 └─────────────────────────────────▶│ pane in wt-B        │
                                                   │ sees <channel       │
                                                   │  type=team_message  │
                                                   │  from="A"…> tag     │
                                                   └─────────────────────┘
```

### Why this shape

- **No new data structure.** The team is a view over the existing `WorktreeEntry` list filtered by repo. Adding/removing a worktree (via the existing sheet, unchanged) implicitly adds/removes a member.
- **No team-naming UI; no lead-picking UI.** Identity = repo identity. Member name = sanitized branch name. Lead = root worktree (LAYOUT-2.3). The user never names or designates anything.
- **Lead is the single point of status routing.** Status events (joined / left / pr_merged) route only to the lead. Direct `team msg` between any two members stays point-to-point. The user defines team-wide coordination policy in one place (the lead's session) instead of every pane separately.
- **Team awareness is delivered through MCP server instructions, not a system-prompt flag.** The `graftty mcp-channel` subprocess sees its host worktree (existing `WorktreeResolver`) and asks the app for the team context, returning the rendered `instructions` in the MCP `initialize` response. The launch line is plain `claude --dangerously-load-development-channels server:graftty-channel` — identical inside and outside team mode.
- **No reliance on Claude's experimental agent-teams.** No `--team-name` flag, no `~/.claude/teams/`, no `SendMessage` tool. We use only the stable channels capability.
- **Vendor-agnostic at the team layer.** Replacing `claude` with another MCP-channel-aware agent requires no changes to the launch line and only the rendered MCP instructions.
- **Persistence stays in `state.json`.** Worktrees and the global toggle live there; team membership and the lead identity are derived from them at runtime.

## Data model

Two changes only.

### `agentTeamsEnabled: Bool` global flag

Stored in the top-level Graftty settings (next to `channelsEnabled` per CHAN-2). Persisted to `state.json`. When toggled on, Graftty also turns on Channels (and refuses to turn Channels off until team mode is turned off again).

### Member identity (and the lead) is derived

A "team member" is just a `WorktreeEntry` whose owning repo is in a team-enabled mode. Member name is `WorktreeNameSanitizer(worktree.branch)` — branch names are already unique within a repo (git enforces it) and already sanitized for use as worktree names per GIT-5.1. The **lead** is the repo's root worktree (the entry whose `path == repo.path`, i.e. the main checkout per LAYOUT-2.3); every other worktree is a **coworker**.

There is no separate `TeamStore`, no separate `TeamEntry`, no separate `TeamMember`. The runtime can compute the team for a worktree from its repo, the peer list of a worktree from its repo's other team-enabled worktrees, and the lead from `repo.path`. A small helper:

```swift
struct TeamView {
    let repoPath: String
    let repoDisplayName: String      // used as the team's display name
    let members: [TeamMember]        // derived live; not persisted; lead is members[0] by convention

    static func team(for worktree: WorktreeEntry, in app: AppState) -> TeamView?
    var lead: TeamMember { get }     // members.first(where: { $0.isLead })
    func memberNamed(_ name: String) -> TeamMember?
    func peers(of worktree: WorktreeEntry) -> [TeamMember]
}

struct TeamMember {
    let name: String                 // sanitized branch name
    let worktreePath: String
    let branch: String
    let isLead: Bool                 // true iff worktreePath == repo.path
    let isRunning: Bool              // worktree's run state per STATE-1
}
```

`TeamView.team(for:)` returns nil when team mode is off or when the worktree's repo has only one worktree (a team of one is no team). Single-worktree repos do not get team-aware MCP instructions.

### Team-aware MCP-instructions template

Rendered fresh by the `graftty mcp-channel` subprocess at MCP `initialize` time, returned in the `initialize` response's `instructions` field. The subprocess fetches its team context from the app over the existing socket. Two variants — chosen by the subprocess based on `member.isLead`:

#**Mechanism only.** Both variants describe the available communication primitives and the events the agent will receive. They contain no behavioral prescription — no "you must…", no suggested response policy. The user defines coordination behavior separately, through normal conversation with the agent or through project files like `CLAUDE.md` / `AGENTS.md`.

#### Lead variant

```
You are "<your-name>" — the LEAD worktree of Graftty agent team for repo
"<repo-display-name>", running in worktree <worktree-path> on branch <branch>.

Your coworkers (other worktrees of this repo with a Claude session):
  - "<peer-name>" — branch <peer-branch>, worktree <peer-path>
  - …

To send a message to any teammate, run this shell command:
  graftty team msg <teammate-name> "<your message>"

You will receive these channel events that coworkers do NOT receive directly
(routed to the lead so the user has a single point to define team-wide
coordination policy):
  - team_member_joined — a new coworker joined; attrs: team, member, branch, worktree.
  - team_member_left   — a coworker left;   attrs: team, member, reason (removed | exited).
  - team_pr_merged     — a coworker's PR merged; attrs: team, member, pr_number, branch, merge_sha.

You will also receive direct messages from coworkers (or from the user) as:
  <channel source="graftty-channel" type="team_message" from="<sender>">…text…</channel>

To see the current roster at any time:
  graftty team list
```

#### Coworker variant

```
You are "<your-name>" — a coworker on Graftty agent team for repo
"<repo-display-name>", running in worktree <worktree-path> on branch <branch>.

Your lead: "<lead-name>" — worktree <lead-path>, branch <lead-branch>.
Your peer coworkers (you may message these directly too):
  - "<peer-name>" — branch <peer-branch>, worktree <peer-path>
  - …

To send a message to the lead or any peer, run this shell command:
  graftty team msg <recipient-name> "<your message>"

You will receive incoming messages as:
  <channel source="graftty-channel" type="team_message" from="<sender>">…text…</channel>

You do NOT receive status events about other coworkers — those route to the lead.

To see the current roster at any time:
  graftty team list
```

Re-rendered on each pane spawn so a teammate's roster reflects current membership. Membership changes that happen later are delivered via channel events to the lead.

## Settings & enablement

A new top-level Settings pane, **Agent Teams**, sits alongside the existing **Channels** pane. It contains:

- A single toggle, **Enable agent teams**. Off by default.
- A read-only display of the **managed default command** that Graftty will use for new team-aware panes.
- A short explanatory footer: "Turning this on auto-enables Channels (required) and locks the Default Command field. Every Claude pane Graftty launches in a multi-worktree repo will connect to graftty-channel, which delivers team-aware instructions on connect."

### Enablement preconditions and side effects

When the user flips **Enable agent teams** to on:

1. If Channels is off, Graftty turns it on as well. (Required: team coordination rides the channel pipeline.)
2. The Default Command field on the existing Settings → Default Command pane becomes **read-only**. Any user-customized value is preserved in storage but not applied; while team mode is on, Graftty's launcher emits the managed line. Flipping team mode back off restores the user's previous custom default command.
3. Already-running panes are not relaunched. The toggle takes effect on next pane spawn. (Existing claude sessions are already connected to `graftty-channel` and continue to receive `team_*` events; what they're missing is the team-aware MCP instructions, which were sent only at their initial `initialize` handshake. They'll get the new instructions when their pane is next opened.)

### Managed default command

The managed default command is **the same line in and out of team mode** — `claude --dangerously-load-development-channels server:graftty-channel`. The team-awareness mechanism lives entirely inside the MCP subprocess: when the subprocess starts, it asks the app for the calling worktree's team context (or learns there is none) and renders the appropriate `instructions` field for the MCP `initialize` response.

This means `DefaultCommandDecision` is unaffected by team membership at the launch-line level. Team mode being on just means *channels-mode-on plus the MCP subprocess uses the team-instructions renderer*; team mode off means *channels-mode-on with empty instructions*. Either way, the launch line is the same.

While team mode is on, the user cannot type a different command into the Default Command field. (They can still type whatever they want into a manually-opened shell prompt; this only governs Graftty's auto-launched panes.)

## UI surface

Surprisingly small.

### Add Worktree sheet — unchanged

The existing sheet (`Sources/Graftty/Views/AddWorktreeSheet.swift`, with iOS-9 / WEB-7 endpoints) is **unchanged**. No Team picker. No team-name field. Adding a worktree to a team-enabled repo automatically makes it a team member by virtue of being in the repo. Adding the second worktree to a single-worktree repo makes both worktrees team members on their next pane spawn.

### Sidebar grouping (LAYOUT extension)

When team mode is on, every team-enabled repo (≥ 2 worktrees) gets a small visual treatment:

- A "team" icon next to the repository's name in its header row.
- An accent stripe along the left edge of all worktrees within the repo, plus their pane sub-rows.
- An optional dimmed footer label under the repo's worktrees: "agent team — N members." Right-clicking the label or any team member's row exposes one diagnostic action: **Show Team Members…**, which opens a small popover listing each member by name and branch (this is just `graftty team list` rendered as a UI panel).

Existing LAYOUT-2.x rules continue to apply unchanged within the rows themselves; the team styling is purely additive.

There is **no Start Team / End Team / Remove from Team UI**. Team membership is governed by the global toggle and the repo's worktree list. To "remove a teammate," remove the worktree (existing GIT-3.* / GIT-4.* / sidebar context menu).

## CLI surface

A `graftty team` subcommand group, registered alongside `Notify`, `Pane`, `MCPChannel` in `Sources/GrafttyCLI/CLI.swift`. The CLI **respects the same enablement gate**: every team subcommand errors with `team mode is disabled — enable it in Graftty Settings → Agent Teams` when the toggle is off.

| Subcommand                                          | Purpose                                                                                              |
| --------------------------------------------------- | ---------------------------------------------------------------------------------------------------- |
| `graftty team msg <member-name> "<text>"`           | Send a message to another member of this worktree's team. Resolves the current worktree to its repo, finds `<member-name>` among the other worktrees, sends a `team_message` channel event to that worktree. Errors if `<member-name>` is not a peer or if the current worktree is not in a team-enabled repo. |
| `graftty team list`                                 | Read-only diagnostic. Prints `<member-name>  branch=<branch>  worktree=<path>  running=<bool>` per peer of the calling worktree, plus a header line with the repo name. |

Both commands are intentionally **read-only at the team-membership layer**: they don't add or remove anyone. Membership is governed by the worktree list, which is mutated through existing GIT-5 / GIT-3 / sidebar surfaces.

The agent inside a pane learns about `graftty team msg` from the team-aware system prompt and runs it via Bash. There is no scenario in which a human user would normally type these commands themselves; they're an internal API for the agents. (`team list` is the exception — useful for human debugging.)

## Channel events (extends CHAN-* / `notifications/claude/channel`)

Four new event types on the existing `graftty-channel` MCP path. Each follows the same wrapper as the existing CHAN events; only `type`, `attrs`, and routing differ. Routing is documented per event.

### `team_message` *(the agent-to-agent messaging primitive)*

Fired by `graftty team msg <member> "<text>"`. Delivered to the recipient's worktree only — strict point-to-point.

| Attribute | Example  |
| --------- | -------- |
| `team`    | `acme-web` (repo name) |
| `from`    | `main`   |

Body: the message text passed to the CLI.

### `team_member_joined`

Fired when a worktree is added to a team-enabled repo and its team-aware pane spawns (or when team mode is toggled on with multiple worktrees already present — each existing worktree's first relaunch counts as joining for purposes of telling the lead). Delivered to **the lead only**.

| Attribute  | Example                                  |
| ---------- | ---------------------------------------- |
| `team`     | `acme-web`                               |
| `member`   | `feature-login` (sanitized branch name)  |
| `branch`   | `feature/login`                          |
| `worktree` | `/repos/acme-web/.worktrees/feature-login` |

Body: `Coworker "feature-login" joined.`

### `team_member_left`

Fired when a team-enabled worktree is removed from the repo (sidebar Remove Worktree, GIT-4.*, etc.) **or** when the team-aware pane in that worktree exits abnormally. Delivered to **the lead only**. The lead may notify other coworkers via direct messages if it judges they need to know.

| Attribute | Example                                  |
| --------- | ---------------------------------------- |
| `team`    | `acme-web`                               |
| `member`  | `feature-login`                          |
| `reason`  | `removed`, `exited`                      |

### `team_pr_merged`

Fired when `PRStatusStore` observes a transition to `.merged` for a worktree in a team-enabled repo. Delivered to **the lead only**. The lead's response is user-defined.

| Attribute   | Example                                   |
| ----------- | ----------------------------------------- |
| `team`      | `acme-web`                                |
| `member`    | `feature-login`                           |
| `pr_number` | `42`                                      |
| `branch`    | `feature/login`                           |
| `merge_sha` | `abc1234…`                                |

Body: `Coworker "feature-login"'s PR #42 (feature/login) merged.`

## Data flows

### Adding a coworker (just adding a worktree)

1. User clicks **+** under a team-enabled repo and fills in the Add Worktree sheet (unchanged from GIT-5).
2. Existing flow: `git worktree add` runs; `WorktreeEntry` appended; sheet closes.
3. Graftty opens a pane in the new worktree and launches `claude --dangerously-load-development-channels server:graftty-channel` (same line as channels-only mode).
4. claude spawns the `graftty mcp-channel` subprocess. The subprocess resolves its host worktree, queries the app for its team context, sees that the worktree's repo has ≥ 2 worktrees, identifies itself as a coworker (worktree path ≠ repo root), and renders the **coworker** MCP-instructions variant in its `initialize` response. claude reads the `instructions` field and the agent now knows its name, lead, peers, and the report-on-commit / report-on-decision rules.
5. Graftty also pushes a `team_member_joined` channel event addressed to **the lead's worktree only** (CHAN-7 fan-out by path). The lead's claude sees the new coworker on its next turn and may welcome it via `team msg`.

### Sending a team message

1. Some claude (lead or coworker) wants to deliver a message. Following its MCP instructions, it runs `graftty team msg feature-login "build the login form"` via Bash.
2. The CLI resolves the current worktree to its repo, finds `feature-login` among the other worktrees, and sends a `teamMessage(from: <self>, to: feature-login, text: "build the login form")` socket message to the app.
3. The app pushes a `team_message` channel event addressed to `feature-login`'s worktree only.
4. The recipient's claude sees `<channel source="graftty-channel" type="team_message" from="<self>">build the login form</channel>` on its next turn and acts on it.

### A coworker's PR merges

1. Existing `PRStatusStore` polling observes the transition to `.merged` for `feature/login`.
2. The new `onTransition` callback fires with `pr_state_changed`. The existing logic handles the worktree-cleanup dialog.
3. **New code**: if the worktree is part of a team-enabled repo, also enqueue a `team_pr_merged` event addressed to **the lead's worktree only**.
4. `ChannelRouter` delivers to the lead's subscriber.
5. The lead's claude sees the channel tag on its next turn. What it does in response — pull, broadcast, ignore, ask the user — is governed by user-defined policy, not by Graftty.

### Toggling team mode on while panes are already running

1. User flips Settings → Agent Teams → on.
2. Graftty also enables Channels if it wasn't (CHAN-2 cascades).
3. Settings sheet shows a non-blocking footer: "Already-running Claude sessions won't have team-aware MCP instructions until you relaunch them. Newly opened panes will."
4. New panes opened from this point use the managed default command and the MCP subprocess renders team instructions on connect. Existing panes keep running; they're already connected to `graftty-channel` via CHAN, so they continue to *receive* team events — but the agent doesn't know what those events mean (the instructions field was empty when it connected). They learn either by being relaunched or by being told via a regular user message.

### Toggling team mode off

1. User flips Settings → Agent Teams → off.
2. The Default Command field becomes editable again; the user's previously-stored custom value is restored.
3. Already-running panes keep the team instructions they were given on connect (the field was already in their context) and continue to send/receive `team_*` events as long as channels remains on. (Toggling team mode off does NOT turn Channels off — that has to be done explicitly.)
4. Newly opened panes use the user's custom default command (or the channels-aware fallback) and the MCP subprocess returns empty `instructions`.

## Persistence (extends PERSIST-*)

Only the global `agentTeamsEnabled` flag is added to `state.json`. No team registry, no membership records — those are all derived from the live worktree list.

LAYOUT-4.* recovery semantics (worktree relocation, bookmark refresh) require no changes. A relocated repo's team is automatically the relocated repo's team because membership tracks the worktree entries.

## Edge cases

- **Branch-name collisions across repos.** Two different repos can each have a `feature/login` worktree. They're in different teams (different repos), so member-name uniqueness is only required *within* a team, not globally. `graftty team msg` resolves through the caller's repo — there's no ambiguity.
- **The lead's pane crashes or is closed.** The team continues; coworkers' messages to the lead are still routed (they'll be delivered when the lead's pane is reopened — CHAN's per-pane subscriber map handles re-subscribe). The lead's MCP instructions are re-rendered on relaunch; if the lead has been gone for a while it will see queued team_member_joined / pr_merged events on reconnect (or, if the channel mechanism doesn't queue, the lead can run `graftty team list` and `git fetch && gh pr list` to catch up).
- **The root worktree itself doesn't exist** (truly headless repo: no main checkout, only linked worktrees). v1 does not support this configuration. The Settings pane disables the toggle for any repo without a root worktree and surfaces an explanation. (In practice, `git` always creates a main worktree when you initialize a repo, so this is rare.)
- **A coworker's pane crashes.** Existing STATE-1 / GIT-3 semantics apply. Graftty fires `team_member_left` with `reason: exited` to the lead. The worktree itself remains in the repo (still listed in the sidebar as `closed`), so when the user reopens its pane the agent rejoins. A `team_member_joined` fires to the lead on rejoin.
- **A coworker's branch is renamed.** The agent's member name (sanitized branch name) changes too. Graftty fires `team_member_left` with the old name and `team_member_joined` with the new name to the lead, both on the next pane spawn. The coworker's MCP instructions update with its new name on relaunch.
- **All worktrees but the root are removed.** The team naturally collapses to a one-member team. The single-worktree-no-team rule kicks in: the root's MCP subprocess returns empty instructions on its next launch. The lead's previously-rendered instructions are stale until relaunch.
- **`graftty team msg` to a non-existent member.** CLI errors with `<member> is not a teammate of this worktree; current teammates: <list>`. The error helps the agent self-correct on its next turn.
- **`graftty team msg` from outside a team-enabled context.** CLI errors with one of: `team mode is disabled` (toggle off), `not inside a tracked worktree` (outside a known repo), `your repo has no other team members yet` (only one worktree).
- **A repo with hundreds of worktrees.** The lead's MCP instructions grow linearly with coworker count (each coworker is named in the lead variant). At ~50 it's fine; at 500+ it'd be a noticeable chunk of the lead's context budget. v1 doesn't truncate; the user is expected to disable team mode for such repos. v2 could paginate or omit non-running coworkers.

## Components

### New files

| File                                                          | Purpose                                                                          |
| ------------------------------------------------------------- | -------------------------------------------------------------------------------- |
| `Sources/GrafttyKit/Teams/TeamView.swift`                     | Read-only helpers (`TeamView`, `TeamMember`) computed from `AppState`. Includes `lead` computation (root worktree). |
| `Sources/GrafttyKit/Teams/TeamInstructionsRenderer.swift`     | Renders the lead and coworker MCP-instructions variants from a `TeamView`.       |
| `Sources/GrafttyKit/Teams/TeamChannelEvents.swift`            | `Codable` types for the four `team_*` events.                                    |
| `Sources/Graftty/Views/Settings/AgentTeamsSettingsPane.swift` | SwiftUI view for the Settings pane (toggle + managed-default-command preview + footer). |
| `Sources/Graftty/Sidebar/TeamRepoBadge.swift`                 | The "team" icon next to a repo header + the "agent team — N members" footer + Show Team Members… popover. |
| `Sources/GrafttyCLI/Team.swift`                               | `graftty team` subcommand (`msg`, `list`).                                       |
| `Tests/GrafttyKitTests/Teams/TeamViewTests.swift`             | Membership-derivation tests across various AppState shapes; lead identification. |
| `Tests/GrafttyKitTests/Teams/TeamInstructionsRendererTests.swift` | Snapshot tests for both lead and coworker variants across team sizes.         |
| `Tests/GrafttyCLITests/TeamCLITests.swift`                    | End-to-end CLI tests with a stub socket; gating-when-disabled tests.             |

### Modified files

| File                                                          | Change                                                                           |
| ------------------------------------------------------------- | -------------------------------------------------------------------------------- |
| `Sources/GrafttyKit/Settings/Settings.swift`                  | Add `agentTeamsEnabled: Bool` (default false).                                   |
| `Sources/GrafttyKit/Persistence/StateStore.swift`             | Encode/decode `agentTeamsEnabled` alongside the existing global flags.           |
| `Sources/GrafttyKit/PRStatus/PRStatusStore.swift`             | When firing `pr_state_changed` for a worktree in a team-enabled repo with peers, also enqueue a `team_pr_merged` event addressed to the team's lead. |
| `Sources/GrafttyKit/Channels/ChannelRouter.swift`             | Add the four `team_*` event types to the routing table; helper to "address to the lead of <repo>". |
| `Sources/GrafttyKit/DefaultCommandDecision.swift`             | When `agentTeamsEnabled` is on, ignore the user-stored default command and emit the managed line — same line whether the repo has peers or not. (The MCP subprocess decides whether to render team instructions; the launcher does not.) |
| `Sources/GrafttyCLI/MCPChannel.swift`                         | On `initialize`, query the app for the calling worktree's team context (or absence thereof) and render `instructions` from `TeamInstructionsRenderer` (lead or coworker variant). Existing event-routing logic is unchanged. |
| `Sources/GrafttyKit/Notification/NotificationMessage.swift`   | Add `teamContextRequest(callerWorktree)` (used by the MCP subprocess on init), `teamMessage(from, to, text)`, `teamList(callerWorktree)` cases. |
| `Sources/Graftty/Views/Settings/DefaultCommandSettingsPane.swift` | Lock the field (read-only + footnote) while team mode is on; show the managed line in dimmed text. |
| `Sources/Graftty/Views/SettingsView.swift`                    | Register `AgentTeamsSettingsPane` alongside Channels and Default Command tabs.   |
| `Sources/Graftty/Sidebar/SidebarView.swift`                   | Apply team styling (when team mode is on and the repo has ≥ 2 worktrees); add the Show Team Members… context-menu item. |
| `Sources/Graftty/AppState.swift`                              | On worktree add/remove, fire the corresponding `team_member_joined` / `team_member_left` channel events when the surrounding repo is in a team-enabled state. |
| `Sources/GrafttyCLI/CLI.swift`                                | Register `Team` subcommand alongside the existing three.                         |
| `SPECS.md`                                                    | Add the `TEAM-*` section. New requirements `TEAM-1.x` through `TEAM-5.x` (see SPECS reservations below). |

## Open questions

There are no significant open questions remaining for v1. The previously-flagged uncertainties (Claude's `~/.claude/teams/` config-file refresh behavior, `--teammate-mode` semantics, lead-rejoin behavior) are all moot — we don't depend on Claude's experimental agent-teams machinery at all. Implementation can proceed.

## SPECS.md identifier reservations

This work introduces a new top-level section `## N. Agent Teams` with subsections covering: settings & enablement (`TEAM-1.*`), managed default command + MCP-instructions delivery (`TEAM-2.*`), the lead/coworker role split and routing semantics (`TEAM-3.*`), `graftty team msg` / `graftty team list` CLI (`TEAM-4.*`), team channel events (`TEAM-5.*`), sidebar visual treatment and edge-case behaviors (`TEAM-6.*`). The exact requirement text is added by the implementation PR per the project's CLAUDE.md convention, not by this design doc.
