# Agent Team Presence & Idle Delivery — Design

**Date:** 2026-05-05
**Branch context:** `codex-hooks`
**Status:** Design approved; ready for implementation planning

## Motivation

Hook-based delivery (`SessionStart` / `PostToolUse` / `Stop`) only fires on agent activity. An idle agent parked at its input prompt receives nothing until the user (or its own tool use) drives the next turn — so a teammate's message can sit unread indefinitely. Two missing pieces close this gap:

1. **Presence** — distinguishing "worktree exists on disk" from "an agent is alive and listening in it." Without presence, graftty has no signal that lets it decide whether a directed nudge is meaningful or whether a destination is even reachable.
2. **Idle delivery** — a way to push a pending message into a session that is otherwise dormant. The current hook architecture is reactive on agent activity; a parked agent never sees its inbox.

Both runtimes (Claude, Codex) need to participate. Codex hook wiring is incomplete on this branch and is a hard prerequisite.

## Scope

### In scope

- Wrapper-scoped hook installation for both Claude and Codex with no global file pollution and no project-tree pollution.
- A team-protocol primer injected at session start so agents understand the inbox/registration/send model.
- A `graftty team register` CLI for agents to announce presence on startup.
- Idle delivery for Claude via Claude Code's `asyncRewake` async-hook mechanism.
- Idle delivery for Codex via zmx-send with a typing-state gate.
- Observability events for registration, watcher lifecycle, and nudge attempts.
- Removal of the now-redundant sidebar team-UX (`TeamRepoBadge`, "Show Team Members…" popover).

### Out of scope

- A real "skill"-form delivery of the protocol primer (kept inline for simplicity; revisit if it grows).
- Codex auto-trust automation (revisit if Codex exposes its trust state shape).
- Capability/identity-rich registration (presence is liveness only in v1).
- Claude Code's built-in `TeammateIdle` event integration — that is tied to Claude Code's own teams concept, not graftty's worktree-derived teams.
- Bracketed paste mode for the zmx nudge (could revisit if the plain-text injection proves visually jarring).

## Components

### 1. Codex hook completion via `CODEX_HOME` mirror

The Codex wrapper sets `CODEX_HOME` to a graftty-controlled directory that mirrors the user's real `~/.codex/` via symlinks for every entry except `hooks.json` and `config.toml`, which graftty generates. Feature, plugin, marketplace, and MCP administration is routed to the durable home instead of the generated snapshot; a later managed-session launch refreshes the snapshot and symlinks any newly created plugin cache.

```
~/.graftty/agent-hooks/codex-home/
├── auth.json        -> ~/.codex/auth.json        (symlink)
├── sessions/        -> ~/.codex/sessions/        (symlink)
├── history.jsonl    -> ~/.codex/history.jsonl    (symlink)
├── sqlite/          -> ~/.codex/sqlite/          (symlink)
├── plugins/         -> ~/.codex/plugins/         (symlink)
├── skills/          -> ~/.codex/skills/          (symlink)
├── … (all other ~/.codex entries symlinked)
├── hooks.json       (graftty-owned: union merge of user's + graftty's hooks)
└── config.toml      (graftty-owned snapshot of durable user configuration)
```

**Wrapper script:**

```sh
GRAFTTY_HOME="$HOME/.graftty/agent-hooks/codex-home"

cleanup() { graftty team unregister --runtime codex 2>/dev/null || true; }
trap cleanup EXIT

if [ "${GRAFTTY_DISABLE_AGENT_HOOKS:-}" != "1" ]; then
  [ "${CODEX_HOME:-}" = "$GRAFTTY_HOME" ] || graftty internal sync-codex-home
  if is_config_administration "$@"; then
    ( exec env CODEX_HOME="$HOME/.codex" "$real_codex" --enable hooks "$@" )
    # Print reload guidance here only when the successful command mutated state.
  else
    ( exec env CODEX_HOME="$GRAFTTY_HOME" "$real_codex" --enable hooks "$@" )
  fi
else
  ( exec "$real_codex" "$@" )
fi
exit $?
```

The subshell with `exec` preserves the lifecycle semantics (signals propagate to the agent, the wrapper holds no extra state) while keeping the parent shell alive long enough to fire the `EXIT` trap. The `cleanup` function runs on any exit path the trap can observe — normal exit, `SIGINT` from Ctrl-C, `SIGTERM`, `SIGHUP`. `SIGKILL` is the only path it can't catch; for that case, graftty's process monitor (which knows the agent's PID from launch) is the fallback that clears stale presence on next observation.

**`graftty internal sync-codex-home`** is fast (directory walk + symlink ops), idempotent, and runs when entering a managed Codex session. A wrapper invoked from an existing managed session inherits the same `CODEX_HOME` and skips the redundant write, which also avoids attempting an Application Support write from inside the active agent sandbox:

1. For every entry in `~/.codex/`, ensure a symlink in graftty home pointing to it. Skip `hooks.json` and `config.toml`.
2. Build `<graftty home>/hooks.json` as the union merge of user's `~/.codex/hooks.json` (if any) and graftty's hooks for `SessionStart`, `PostToolUse`, `Stop`. Sentinel-based: graftty's entries are the ones whose handler `command` starts with the literal `graftty team hook codex`. On rebuild, strip stale graftty entries first, then append fresh ones.
3. Snapshot durable `config.toml` into the managed home. On the first upgrade from the legacy generated config, migrate a newer legacy copy while restoring the user's durable `features.hooks` setting; if the durable file is newer, preserve the legacy bytes as a backup rather than overwriting newer configuration.
4. Prune dangling symlinks (entries the user has since deleted from `~/.codex/`).

The wrapper enables Codex hooks with the launch-scoped `--enable hooks` override. It prints reload guidance after successful feature, plugin, marketplace, or MCP mutations because running sessions discover configuration and tools at startup. A sandboxed agent may still require the normal filesystem approval to mutate user-global `~/.codex` state; the wrapper does not bypass that security boundary.

**Why this shape:**

- Wrapper-scoped: only graftty-launched Codex sessions see graftty's hooks. Plain `codex` outside the wrapper is unaffected (no `CODEX_HOME` set).
- Normal Codex configuration commands run against the durable home, while ordinary managed sessions consume a snapshot and Graftty-owned hook file.
- Concurrent sessions are safe: graftty home is static between rebuilds; multiple sessions read the same files via the same symlinks.
- Crash-safe: nothing to restore on abnormal exit.
- User's own hooks still fire (union-merged into graftty's `hooks.json`).
- Project-layer hooks (`<repo>/.codex/hooks.json`) still work — `CODEX_HOME` only redirects the user layer.

### 1b. Claude hook completion via inline `--settings`

The Claude wrapper passes the entire hook configuration as an inline JSON string via `--settings`, which Claude Code documents as "load **additional** settings from" (additive, not replacing).

```sh
cleanup() { graftty team unregister --runtime claude 2>/dev/null || true; }
trap cleanup EXIT

if [ "${GRAFTTY_DISABLE_AGENT_HOOKS:-}" != "1" ]; then
  ( exec "$real_claude" --settings "$GRAFTTY_CLAUDE_SETTINGS_JSON" "$@" )
else
  ( exec "$real_claude" "$@" )
fi
exit $?
```

Same trap-and-subshell pattern as the Codex wrapper. The cleanup is identical except for the `--runtime claude` argument.

The inline JSON is generated at install time and embedded directly in the wrapper script. This eliminates `~/.graftty/agent-hooks/claude-settings.json` from the on-disk surface — there is no separate settings file to keep in sync.

**Why this is asymmetric with Codex:**

Claude's `--settings` is documented as additive (layered with user settings); Codex's `-c` is documented as overriding (replaces values). Each runtime gets the mechanism that respects user config. The asymmetry is principled, not incidental.

### 2. Team protocol primer (always-on injection)

Extend `TeamHookRenderer.codexSessionStart` (which `claudeSessionStart` already aliases) so the `additionalContext` it returns includes a small protocol primer **before** the existing inbox content. Approximate shape:

```
You are a graftty agent team participant. Your worktree is "<name>", your runtime is "<claude|codex>".

First action this session: run `graftty team register` in the shell. This announces presence to your teammates.

Inbox commands:
- `graftty team inbox` — read new messages
- `graftty team send <recipient> <message>` — send a message to a teammate
- `graftty team status` — list registered teammates

[ …existing unread-messages section… ]
```

Small (~250 tokens) and identical for both runtimes — the renderer already produces the same JSON shape.

### 3. Presence / registration

**Storage:** `~/.graftty/teams/<teamID>/presence/<worktree>.<runtime>.json` — records `pid`, `registeredAt`, `runtime`, `worktree`. One file per (worktree, runtime) pair.

**Set:** new CLI subcommand `graftty team register` (companion to existing `graftty team hook ...`). Reads worktree + team from cwd. Writes the presence file. Idempotent. The agent runs this as its first action; the SessionStart-injected protocol primer instructs it to.

**Clear:** layered cleanup, in order of likelihood:

1. **Wrapper trap.** The wrapper script registers an `EXIT` trap that runs `graftty team unregister --runtime <claude|codex>` whenever the wrapper exits, including signal-induced exits (`SIGINT`/`SIGTERM`/`SIGHUP`). This is the primary cleanup path and handles every clean and most signal-driven shutdowns.
2. **Graftty process monitor (fallback).** If the wrapper itself is killed with `SIGKILL` (or otherwise dies before its trap can fire), the trap doesn't run and presence stays on disk pointing at a dead PID. Graftty's process monitor — which already tracks each agent's PID from launch — clears the presence record on its next observation cycle.

A new CLI subcommand `graftty team unregister --runtime <claude|codex>` reads the worktree from cwd and removes the matching presence file. Idempotent (no-op if the file is already gone, e.g. when the agent never registered before being killed). No heartbeat.

**Consumed by:**

- Idle delivery — both backends gate on "is this recipient registered?" before attempting.
- Team UI — surface registered/unregistered state per worktree.
- A future `graftty team status` CLI subcommand.

### 4. Idle delivery, Claude path: asyncRewake watcher

Add a **second** Stop hook entry alongside the existing `team hook claude stop`:

```json
{
  "type": "command",
  "command": "graftty team watch-inbox claude",
  "async": true,
  "asyncRewake": true,
  "timeout": 86400
}
```

The `watch-inbox` subcommand:

1. Reads `session_id` and `cwd` from the hook's stdin JSON.
2. Writes its own PID to `~/.graftty/teams/<id>/watchers/<session>.<runtime>.pid`. SIGTERMs whatever PID was previously there (one watcher per session, deterministically — the next Stop firing supersedes the prior watcher).
3. Tails the inbox JSONL via FSEvents (reuse `TeamInboxObserver`), filtered to messages addressed to this recipient.
4. On a new unread message, exits with code 2 and a short message summary on stderr. Claude's harness wakes the session and surfaces the stderr as a system reminder.

**No 1-minute delay on this path** — asyncRewake operates within Claude's process and does not interfere with the user's readline buffer the way `zmx send-keys` would.

### 5. Idle delivery, Codex path: zmx-send with typing gate

Codex has no asyncRewake equivalent, so we fall back to keystroke injection.

A new graftty-side service:

- Polls each registered Codex agent's inbox cursor every ~10s.
- For any unread message **older than 1 min**, attempts a send-keys-style nudge into the agent's zmx session.

**Gating preconditions** (all must hold):

1. Agent is registered (presence file exists, PID alive).
2. zmx session is currently attached.
3. **No uncommitted user input** since the last `\r` in the session's input stream.

For (3), zmx (graftty-owned) gets a small instrumentation patch: track per-session bytes-since-last-newline. Exposed via the existing zmx daemon protocol. If the count is non-zero, do not send.

**Nudge content:** a single line like

```
[graftty] You have 2 unread team messages from <senders>. Run `graftty team inbox` to read.
```

followed by `\r`. Doesn't duplicate message bodies; preserves inbox as the source of truth.

**Debounce:** once-per-stale-state. Once a nudge fires for a session, do not re-fire until either the inbox cursor advances (agent read it) or a new message arrives that itself crosses the 1-min threshold.

### 6. Observability

Append-only `~/.graftty/teams/<id>/events.jsonl` records:

- Registrations and deregistrations.
- Watcher lifecycle (spawn, supersede, exit-2 wake, clean exit).
- Nudge attempts (success and reason for skip — not registered, typing, no message stale enough, etc.).

Used for: debugging, the existing Team Activity Log window (TEAM-7.*), and future blindspots-style introspection.

### 7. Sidebar team-UX cleanup

The sidebar currently shows a "team" badge icon next to repo headers (TEAM-6.1) and a "Show Team Members…" right-click action that opens a member-list popover (TEAM-6.2). Both pre-date the inbox/hooks rework and don't carry their weight in the current model — the badge is purely decorative, and the popover duplicates information the user can get from `graftty team list`. Remove them as part of this work.

**Out of scope of this removal:**

- The Team Activity Log window and its sidebar entry point (TEAM-7.1, TEAM-7.2). The activity log is the natural surface for the new `events.jsonl` observability (Section 6) and stays.
- The `agentTeamsEnabled` UserDefaults flag and the `AgentTeamsSettingsPane` toggle. The flag still gates whether team behavior is active at all; only the visual sidebar pieces are removed.
- All `Teams/*` model code, hook plumbing, inbox machinery. The removal is UI-only.

**Files removed:**

- `Sources/Graftty/Views/TeamRepoBadge.swift` — entire file.
- `TeamMembersPopover` private struct and the `.popover` modifier in `Sources/Graftty/Views/SidebarView.swift`.
- The `teamPopoverWorktreePath` `@State` property in `SidebarView`.
- The "Show Team Members…" `ClosureMenuItem` and its surrounding setup in `buildWorktreeMenu`.

**Files modified:**

- `Sources/Graftty/Views/SidebarView.swift` — drop the `TeamRepoBadge(repoPath: repo.path)` invocation in the disclosure-header `HStack`. Drop the popover. Trim `buildWorktreeMenu` to keep only the activity-log entry under the team-aware separator.

**Spec hygiene:**

Per `CLAUDE.md`'s "When removing features" workflow:

1. Delete `@spec TEAM-6.1` and `@spec TEAM-6.2` entries in `Tests/GrafttyTests/Specs/TeamTodo.swift`.
2. Re-run `scripts/generate-specs.py` and commit the updated `SPECS.md`.
3. The "TEAM-6.2 / TEAM-7.2" comment in `SidebarView.swift` collapses to "TEAM-7.2: team-aware activity-log entry."

## Architectural decisions

- **One design, two delivery backends.** `IdleDeliveryService` exposes a uniform "deliver pending" interface; the asyncRewake watcher and zmx-send poller are implementations of it, keyed on runtime. Future runtimes plug in here.
- **Registration is presence, not identity.** v1 carries no capabilities, role, or model metadata — just liveness. Identity-rich registration can layer in later as additional fields without changing the storage shape.
- **Process-death is the only deregister signal.** No heartbeats, no TTLs. Graftty owns the launcher; if a stale presence file points at a dead PID, graftty cleans it on next observation.
- **Asymmetric runtime mechanisms are principled.** Claude's wrapper uses inline `--settings` (additive). Codex's wrapper uses `CODEX_HOME` redirection to a synthesized mirror dir (because `-c` overrides rather than merges). Each runtime gets the cleanest fit.

## Limitations / open questions to validate during implementation

- **`sync-codex-home` startup latency.** Should be ms-scale but worth measuring; if visible, cache a fingerprint of `~/.codex/` and skip the rebuild when nothing changed.
- **Symlinked active state.** Files like `state_5.sqlite-wal` and `auth.json` are accessed by Codex while it runs. POSIX symlink semantics should make this transparent (concurrent sessions access the same underlying inode), but smoke-test two parallel graftty Codex sessions to confirm SQLite WAL behaves correctly.
- **Watcher race on rapid Stop firings.** If a watcher's PID-file write races with the next Stop hook's SIGTERM-then-spawn, ordering must be: SIGTERM old → wait for exit → write new PID → start tailing. Atomic file rename for the PID file plus a short polling loop on `kill -0` should be sufficient.
- **Codex first-time UX.** First Codex run through graftty's wrapper triggers Codex's normal startup paths against the synthesized home; if Codex performs any interactive setup against a fresh `CODEX_HOME` directory it cannot find, that needs handling. The pre-populated symlink farm should make graftty home indistinguishable from a real `~/.codex/`, but verify.

## Proposed `@spec` requirements

(Numbering to be slotted into the existing `TEAM-*.*` block during implementation; the `TEAM-PRESENCE-*` and `TEAM-IDLE-*` prefixes below are placeholder families for clarity.)

- **TEAM-PRESENCE-1.1** — When an agent session starts, the application shall inject a team protocol primer in the SessionStart `additionalContext`.
- **TEAM-PRESENCE-1.2** — When the agent runs `graftty team register`, the application shall persist a presence record at `~/.graftty/teams/<id>/presence/<worktree>.<runtime>.json`.
- **TEAM-PRESENCE-1.3** — When the agent wrapper script exits, the application shall remove the presence record via `graftty team unregister`.
- **TEAM-PRESENCE-1.4** — When an agent process exits without its wrapper trap firing (e.g. SIGKILL), the application's process monitor shall clear the stale presence record on next observation.
- **TEAM-IDLE-1.1** — When Graftty synthesizes a managed CODEX_HOME, the application shall union the user's Codex hooks with Graftty's current SessionStart hook and remove stale Graftty delivery hooks.
- **TEAM-IDLE-1.2** — When the Claude wrapper runs with `GRAFTTY_DISABLE_AGENT_HOOKS != 1`, the application shall exec `claude --settings '<inline JSON>'` so graftty's hooks layer additively over the user's settings.
- **TEAM-IDLE-1.3** — When Claude's Stop hook fires, the application shall spawn an `asyncRewake` inbox watcher coalesced per session.
- **TEAM-IDLE-1.4** — When the watcher observes a new unread message addressed to its session, it shall exit with code 2 and a stderr summary.
- **TEAM-IDLE-2.1** — While a Codex agent is registered and idle, the application shall poll its inbox and, when an unread message has been waiting for more than 60 seconds, deliver it via zmx-send.
- **TEAM-IDLE-2.2** — If the user's zmx input has uncommitted bytes since the last newline, then the application shall not send-keys.
- **TEAM-IDLE-2.3** — When a stale message would trigger a nudge, the application shall send at most one nudge until either the inbox cursor advances or another message crosses the 60-second threshold.

## Files to create / modify

### Deleted

- `Sources/Graftty/Views/TeamRepoBadge.swift` — entire file (TEAM-6.1).

### New

- `Sources/GrafttyKit/Teams/TeamPresence.swift` — presence model and registration storage.
- `Sources/GrafttyKit/Teams/InboxWatcher.swift` — long-lived watcher loop used by `graftty team watch-inbox`.
- `Sources/GrafttyKit/Teams/IdleDeliveryService.swift` — background poller for the Codex zmx-send path.
- `Sources/GrafttyKit/Teams/CodexHomeMirror.swift` — synthesizes `~/.graftty/agent-hooks/codex-home/` from `~/.codex/` plus graftty's overrides; backs the `graftty internal sync-codex-home` CLI.
- `Sources/GrafttyKit/Zmx/ZmxInputState.swift` — tracks per-session typed-but-uncommitted bytes for the typing gate.
- `Tests/GrafttyTests/Specs/TeamPresenceTests.swift`, `InboxWatcherTests.swift`, `IdleDeliveryTests.swift`, `CodexHomeMirrorTests.swift`.

### Modified

- `Sources/GrafttyKit/Teams/TeamHookRenderer.swift` — add the protocol primer to `SessionStart` `additionalContext`.
- `Sources/GrafttyKit/Teams/AgentHookInstaller.swift` — switch Claude wrapper to inline `--settings` (drop the on-disk settings file); rewrite Codex wrapper to set `CODEX_HOME` and call `graftty internal sync-codex-home`.
- `Sources/GrafttyCLI/Team.swift` — new subcommands: `register`, `unregister`, `watch-inbox`. New `internal sync-codex-home` subcommand (under an `internal` group not surfaced to users).
- `Sources/GrafttyKit/Zmx/ZmxRunner.swift` — instrument input forwarding to track uncommitted bytes per session; expose via daemon protocol.
- `Sources/Graftty/Views/SidebarView.swift` — drop `TeamRepoBadge` invocation, "Show Team Members…" menu item, `TeamMembersPopover` struct, and the `teamPopoverWorktreePath` state.
- `Tests/GrafttyTests/Specs/TeamTodo.swift` — delete the `@spec TEAM-6.1` and `@spec TEAM-6.2` entries.
- `SPECS.md` — regenerated from updated `@spec` annotations.
- Add a TOML parsing dependency (e.g. `swift-toml` or similar) if one is not already available, for the `config.toml` merge in `CodexHomeMirror`.

## Open follow-ups (not blocking v1)

- Cache fingerprint of `~/.codex/` to skip `sync-codex-home` rebuilds when nothing changed.
- Pre-trust per-worktree `.codex/` if a user has any (currently a non-issue with `CODEX_HOME` design but worth tracking).
- Identity/capability registration as a v2 extension to the presence record.
- Filing a Codex feature request for an additive `--config-file <path>` flag, which would let the Codex side collapse to inline config the way Claude does.
