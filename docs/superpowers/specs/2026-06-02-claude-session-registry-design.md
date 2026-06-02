# Claude session registry + pane-level status

**Date:** 2026-06-02
**Branch:** `claude-agent-ui-api`
**Spec prefix:** `AGENT-`

## Summary

Claude Code now ships native multi-agent features — an **Agent View** (`claude agents`,
with a scriptable `claude agents --json`), **Agent Teams** (`~/.claude/teams/<name>/`),
and a shared task list (`~/.claude/tasks/`). Graftty has long maintained its own
~6,800 LOC of agent-coordination machinery (team inbox, presence, hooks, notify) that
overlaps this territory.

This work does the one consolidation that is *safe and high-value today*: it makes
`claude agents --json` the source of truth for **claude session liveness/activity**,
and uses the result to drive **pane-level status pills** in the sidebar. As a
deliberate side effect, it moves agent status pills off the worktree row and onto the
pane they actually belong to — which is only now possible because of the
session→pane join this feature introduces.

Everything here is **read-only** with respect to Claude Code: Graftty observes
`claude agents --json`; it does not write Claude's team/task state.

## Goals

1. Surface, per pane, whether the claude agent in that pane is **busy** (model turn in
   progress) or **idle/waiting**, derived natively from `claude agents --json` — no
   reliance on Graftty's hook wrapper firing.
2. Move **agent status pills to the pane level**. Today the "needs input" pill renders
   on the worktree row because the agent-stop path only knows the worktree; the
   session→pane join fixes that.
3. Extend `graftty notify` so a notification can target a specific pane
   (`--session`) or worktree (`--worktree`), and so a no-flag in-pane call targets the
   caller's pane automatically.
4. Begin retiring Graftty's hook-based *inference* of claude activity in favor of the
   native signal.

## Non-goals (explicitly out of scope)

- Replacing Graftty's team messaging / inbox with Claude's native Agent Teams. Claude's
  mailbox has **no headless control API** (it is driven by the in-session, experimental
  `SendMessage` tool behind `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1`), is **claude-only**
  (Graftty supports codex as a load-bearing runtime), and backs Graftty's GUI + iPad
  surfaces. Betting load-bearing code on it today is not justified. Revisit if/when a
  stable headless surface appears.
- Touching the codex activity/idle-delivery path (`CodexHomeMirror`,
  `IdleDeliveryService`, `WorktreeAgentStateRegistry` codex branch).
- Replacing `TeamPresenceMonitor.kernelIsAlive` (`kill(pid, 0)`); it is a 5-line
  runtime-agnostic liveness check that `--json` does not improve on.

## Key facts established by investigation

- `claude agents --json` (claude **2.1.160**) emits a flat array of
  `{ pid, cwd, kind, sessionId, startedAt, status }`. `status` is only `"busy"` or
  `"idle"` — the Agent View's richer "needs input / completed / failed" grouping is
  **not** in the JSON. So `--json` is a *passive liveness* signal; Graftty's existing
  `notify` / stop-hook path remains the *semantic* layer, and the two compose.
- Every `claude` launched inside a Graftty pane inherits
  `ZMX_SESSION=graftty-<8hex>`, which is exactly `ZmxLauncher.sessionName(PaneSessionID)`
  — the same string stored in `WorktreeEntry.paneSessions[PaneSlotID]` and carried on
  `PaneLayoutNode.leaf(sessionName:)`. So the **session→pane join** is
  `--json` pid → `ps eww` env → `ZMX_SESSION` → pane. Verified resolving 19/20 live
  sessions; the miss was a claude running outside any Graftty pane (correctly ignored).
  The join key `graftty-<8hex>` is space-free, so it survives `ps eww` word-splitting.
- `recordAgentStop` (`Sources/Graftty/GrafttyApp.swift`) **already receives**
  `paneSessionName` (threaded from the `.teamHook` message) and ignores it, writing
  worktree-scoped `attention`. Re-homing to the pane is a small change, not new plumbing.
- The build template already exists: **`PRStatusStore`** — an `@MainActor @Observable`
  store that polls an external CLI per tick, keys results by worktree, surfaces a badge
  on the shared `WorktreePanes` wire model (reaching iPad for free), with stale-fetch
  generation guards. The new registry is a structural sibling.

## Architecture

### Component 1 — `ClaudeSessionRegistry`

`Sources/GrafttyKit/AgentLiveness/ClaudeSessionRegistry.swift`

- `@MainActor @Observable`, modeled on `PRStatusStore`.
- Holds `livenessBySession: [String /* zmx session name */ : AgentLiveness]`,
  where `AgentLiveness` is `enum { case busy, idle }`.
- On an injected `PollingTickerLike` tick (default **2 s**), via an injected
  `CLIExecutor`:
  1. Run `claude agents --json`.
  2. Run one batched `ps eww -o pid=,command= -p <pid1,pid2,…>` for the returned pids.
  3. Hand both raw strings to the pure parsing layer (below) → `[sessionName: AgentLiveness]`.
- Stale-fetch / generation guard copied from `PRStatusStore.RepoFetchState` so a stuck
  poll cannot overwrite a newer result.
- Resolves the `claude` binary the same way `CLIRunner` resolves `git`/host CLIs.

### Component 2 — `AgentLivenessParsing` (pure, no I/O)

`Sources/GrafttyKit/AgentLiveness/AgentLivenessParsing.swift`

Free functions turning `(rawAgentsJSON, rawPsOutput)` into `[sessionName: AgentLiveness]`:

- Parse `--json` into `[(pid, status)]`.
- Parse `ps` output into `[pid: zmxSession]` by extracting the `ZMX_SESSION=graftty-…`
  token from each line.
- Join on pid; drop sessions with no `ZMX_SESSION` (claude outside a Graftty pane).
- This is where ~all spec tests point — strings in, dict out, no mocks.

### Component 3 — shared session→pane join

`WorktreeEntry.paneSlot(forSessionName:) -> PaneSlotID?`

Inverts `paneSessions` through `ZmxLauncher.sessionName`. Four consumers share it:
busy/idle rendering, "needs input" re-homing, no-flag notify, and `--session` notify.

### Component 4 — pane busy/idle surface (the merge)

The single leaf builder in `Sources/Graftty/GrafttyApp.swift` (the `case .leaf(id)`
that constructs `PaneLayoutNode` for the wire model) becomes:

```swift
case let .leaf(id):
    let session = paneSessions[id].map(ZmxLauncher.sessionName)
    let effective = paneAttention[id]?.text                     // 1. live notify ping wins
        ?? registry.busyText(forSession: session)               // 2. else "working…" if busy
    return .leaf(…, attentionText: effective)                   // 3. else nil
```

`busyText` returns `"working…"` for `.busy`, `nil` for `.idle`. **Notify-wins**
precedence falls out for free: a live ping in `paneAttention` short-circuits and is never
overwritten; when it clears, the next render falls through to busy/idle. The derived
state is never written into `WorktreeEntry.paneAttention`, so `state.json` stays clean
and there is no "restore the ping" problem. The string trivially passes
`Attention.isValidText`. Because it rides the existing capsule, it reaches the sidebar,
web UI, and the iPad `panes_state` channel with **zero new wire fields and no new UI**.

### Component 5 — "needs input" → pane

`recordAgentStop` resolves its existing `paneSessionName` via
`WorktreeEntry.paneSlot(forSessionName:)` and writes `paneAttention[slot]` instead of
`worktree.attention`. It falls back to `worktree.attention` only when there is no pane
session (an agent not running inside a Graftty pane), so the pill stays visible in that
edge case.

### Component 6 — `graftty notify` target grammar

```
graftty notify <text> [--session <zmx-session>] [--worktree <wt>] [--clear] [--clear-after N]
```

`--session` and `--worktree` are mutually exclusive (validated). Resolution:

| Invocation | Scope |
|---|---|
| `--session graftty-abc12345` | **pane** `graftty-abc12345` (resolved across all worktrees) |
| `--worktree <wt>` | **worktree** `<wt>` |
| no flag, `$ZMX_SESSION` set | **pane** = caller's current pane |
| no flag, no `$ZMX_SESSION` | **worktree** (CWD) — unchanged behavior |

`text` remains the sole positional, so `graftty notify "done"` is untouched.

Wire: `.notify` and `.clear` gain an optional `paneSessionName` (back-compat via
`decodeIfPresent`). When present, the app resolves the slot and writes
`paneAttention[slot]` (and the matching pane-scoped clear) via the existing
`setAttentionForTerminal` path; otherwise it uses the worktree path as today. A
`--session` that resolves to no live pane errors with a copy-pasteable hint, matching
the `pane`-resolver convention.

### Component 7 — consolidation hook

For **claude**, `WorktreeAgentStateRegistry`'s active/idle is sourced from the registry's
busy/idle rather than inferred from `PostToolUse`/`Stop` hook events. Codex keeps its
hook-driven path untouched. This makes claude activity sensing hook-independent (robust
even if the wrapper/hooks misfire) and is groundwork to later drop claude's
`PostToolUse`-for-activity reliance. No code is deleted in this change; this is the
foundation.

### Component 8 — auto-clear stale "needs input" (optional)

When the registry observes an idle→busy transition for a pane, clear any "needs input"
`paneAttention` on that pane (the agent resumed), complementing click-to-clear
(STATE-2.4). Implement only if it falls out cleanly; otherwise defer.

## Data flow

```
2s ticker ─► ClaudeSessionRegistry
              ├─ CLIExecutor: claude agents --json        → [(pid, status)]
              ├─ CLIExecutor: ps eww -o pid=,command= …   → [pid: ZMX_SESSION]
              └─ AgentLivenessParsing(json, ps)           → [sessionName: busy/idle]
                         │
                         ▼ (@Observable mutation)
   leaf builder (GrafttyApp): attentionText =
        paneAttention[id]?.text ?? registry.busyText(forSession: session)
                         │
                         ▼
   existing render path ─► sidebar pane rows · web UI · iPad panes_state channel
```

## Error handling

- `claude` missing / nonzero exit / unparseable JSON → treat as "no data"; keep
  last-known state one cadence, then decay to empty. Never crash, never spam. Mirrors
  `PRStatusStore` failure handling.
- `ps` returns nothing for a pid (process exited mid-tick) → that session drops out →
  pane falls back to notify/nil. Correct.
- A `ZMX_SESSION` matching no live pane (stale/closed) → ignored.
- Multiple claude sessions resolving to one pane (rare) → pane is busy if **any** is busy.

## Testing (TDD, `AGENT-` specs)

Swift Testing, title-as-spec. Backlog entries start as `@Test(.disabled(...))` in
`Tests/GrafttyTests/Specs/AgentTodo.swift`, promoted to real tests as implemented.
All logic flows through the pure `AgentLivenessParsing` layer and a fake
`CLIExecutor`/ticker — no real subprocesses.

- `AGENT-1.0` — doc comment on the `AgentLiveness` enum (structural).
- `AGENT-1.1` — parse `--json`+`ps` into busy/idle keyed by inherited `ZMX_SESSION`.
- `AGENT-1.2` — a session with no `ZMX_SESSION` is ignored.
- `AGENT-1.3` — a `ZMX_SESSION` matching no live pane is ignored.
- `AGENT-1.4` — multiple sessions in one pane → busy if any is busy.
- `AGENT-2.1` — a live notify ping takes precedence over derived busy at the merge.
- `AGENT-2.2` — with no ping, a busy session renders `working…`; idle renders nothing.
- `AGENT-2.3` — failed/empty `claude agents` output yields no overlays and no crash.
- `AGENT-3.1` — `recordAgentStop` with a resolvable `paneSessionName` writes
  `paneAttention[slot]`, not `worktree.attention`.
- `AGENT-3.2` — `recordAgentStop` with no pane session falls back to `worktree.attention`.
- `AGENT-4.1` — `notify --session <zmx-session>` writes pane attention on the matching pane.
- `AGENT-4.2` — `notify` with no flag and `$ZMX_SESSION` set targets the caller's pane.
- `AGENT-4.3` — `notify` with no flag and no `$ZMX_SESSION` targets the CWD worktree.
- `AGENT-4.4` — `notify --session`/`--worktree` are mutually exclusive (validation error).
- `AGENT-4.5` — `notify --session` with no matching live pane errors with a hint.

Existing specs whose EARS text must be updated to match the new pane-scoped behavior:
the `recordAgentStop` "needs input" spec and the `notify` worktree-attention spec
(`STATE-2.3` and neighbors). Run `scripts/generate-specs.py` and commit the regenerated
`SPECS.md`.

## Rollout / risk

- Purely additive at runtime (a new poller + a merge + a notify flag); no behavior is
  removed except the location of agent status pills (worktree → pane), which is the
  intended change.
- Worktree-row capsule is retained for explicit `--worktree` notify and the
  no-pane-session fallback, so nothing becomes invisible.
- `macOS swift test` does not exercise iOS-guarded code; pane-pill rendering on iPad is
  via the shared `panes_state` channel and must be confirmed against iOS CI.
