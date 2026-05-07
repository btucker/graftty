# Event-driven Codex idle delivery via zmx-send

**Status:** Draft
**Date:** 2026-05-06
**Replaces parts of:** `2026-05-05-agent-team-presence-and-idle-delivery-design.md` (the IdleDeliveryService section)

## Why

Today, normal-priority team messages addressed to a Codex agent have **no live delivery path**:

- The synchronous Stop hook returns `{}` for both runtimes (the Stop schema doesn't accept `hookSpecificOutput.additionalContext`).
- `PostToolUse` filters to urgent only.
- `SessionStart` doesn't read the inbox (only injects the team primer).
- Claude has the `asyncRewake` watcher (`team watch-inbox claude`) to bridge the post-Stop / pre-next-turn gap. **Codex has no equivalent.**
- `IdleDeliveryService` exists with a 10s polling loop and 60s staleness threshold, but `ZmxNudgeSender.send` is an `NSLog` stub.

Net effect, observed today: a `team msg` to `main` (running Codex) gets written to `messages.jsonl` and never surfaces to the agent unless the user manually runs `graftty team inbox`. Even after recently fixing the cursor-advance regression on Stop, the message has nowhere to land live.

This design replaces the polling-based stub with a precise, event-driven mechanism that uses signals we already receive (Stop / SessionStart / PostToolUse hook events) and keystroke observation at the libghostty input boundary.

## Goals

1. **Codex receives normal-priority messages mid-session** without restarting or running CLI commands by hand.
2. **Never corrupt the user's input buffer.** When the user is composing in the pane, defer delivery until they've stopped typing.
3. **No polling.** Every transition is driven by an explicit signal (hook event, keystroke, timer fire after a known last-input).
4. **Architecturally minimal.** Reuse existing primitives (`TeamInboxObserver`, `TeamEventLog`, hook handler, panes-per-worktree view model) instead of inventing new ones.

## Non-goals

1. Replacing or retiring `asyncRewake` on Claude. It works; this design lives alongside it.
2. Per-pane session-id precision. v1 targets the worktree's first pane only.
3. A new `zmx send` CLI surface — the existing `Zmx*` types in `Sources/GrafttyKit/Zmx/` already expose what we need; we wire it in instead of adding API.
4. Heuristic "did this PTY have a Codex process?" detection. We trust the worktree's pane list.

## Architecture

### State machine, per worktree

```
                 SessionStart / PostToolUse
       ┌──────────────────────────────────────┐
       │                                      │
   ┌───▼────┐    Stop + no recent typing  ┌───┴────┐
   │ active │ ───────────────────────────►│  idle  │ ◄─────┐
   └───┬────┘                             └───┬────┘       │
       │                                      │            │
       │ Stop + recent typing                 │ user types │ 60s no typing
       │                                      ▼            │
       │                              ┌───────────────┐    │
       └─────────────────────────────►│ user_engaged  │────┘
                                      └───────────────┘
```

States:

- **`unknown`** — initial; no SessionStart observed yet for this worktree's runtime. **No delivery.**
- **`active`** — SessionStart or PostToolUse fired most recently. **No delivery** (PostToolUse handles urgent; normal waits for Stop).
- **`idle`** — Stop fired and the pane has had no keystrokes for ≥ 60s. **Deliver pending and arriving messages.**
- **`user_engaged`** — Stop fired, but a keystroke landed in the pane within the last 60s. **No delivery** until 60s elapses.

Transitions:

- `unknown` → `active` on first SessionStart.
- `active` → `idle` on Stop iff `now - lastKeystroke ≥ 60s` (or `lastKeystroke` is nil).
- `active` → `user_engaged` on Stop iff `now - lastKeystroke < 60s`.
- `idle` → `user_engaged` on any keystroke into the pane.
- `user_engaged` → `idle` 60s after the last keystroke (driven by a single rescheduled timer per pane, not a tick loop).
- `idle` / `user_engaged` → `active` on SessionStart or PostToolUse.

Storage: in-process only. A SwiftUI-side `WorktreeAgentStateRegistry` keyed by `(repoPath, worktreePath, runtime)` holding `lastInputAt: Date?, state: AgentState, lastEventAt: Date`. No persistence — process-restart resets every worktree to `unknown`, which is the correct default.

### Pane targeting

Recipient is the *first pane* of the recipient worktree, taken from graftty's existing pane list for that worktree. If the worktree has no panes, skip delivery (and log it).

> **Definition of "first":** `panes.first` from the worktree's pane array as already maintained for the sidebar — earliest-created surviving pane. Future versions can refine this with session-id-to-pane tracking; v1 doesn't need it.

### Keystroke observation

A new `PaneInputActivityObserver` taps the libghostty input boundary at the SwiftUI surface — the same point every PTY-bound keystroke flows through regardless of source (web session vs native libghostty pane). On each input event it stamps `[PaneID: Date]` in a process-wide `PaneInputActivityRegistry`.

**Why not `ZmxInputState`:** that observer only sees web-session-routed bytes; native libghostty keystrokes are invisible to it. Wrong layer for our gate.

The 60s rule reads `lastInputAt(pane: firstPaneOf(worktree))` and compares against `Date()`.

### Triggers for evaluation

Two events drive `IdleDeliveryService.maybeDeliver(toWorktree:)`:

1. **Stop hook fires** → `TeamInboxRequestHandler.hook(... event: .stop)` invokes `IdleDeliveryService.onStop(worktree:)` as a side-effect *before* returning `{}`.
2. **New message arrives** → existing `TeamInboxObserver` already fires per-write events; `IdleDeliveryService` subscribes and dispatches `maybeDeliver` for the recipient's worktree.

The `user_engaged → idle` transition is driven by a per-pane `Timer` rescheduled on every keystroke. When the timer fires, if state is still `user_engaged`, transition to `idle` and call `maybeDeliver`.

`maybeDeliver(toWorktree:)`:

```
state = registry.state(worktree)
guard state == .idle else { return }
pending = inbox.unreadAddressedTo(worktree, after: zmxWatermark)
guard !pending.isEmpty else { return }
pane = panes(for: worktree).first
guard let pane else { log("no panes"); return }
zmx.send(pane: pane, text: format(pending))
inbox.advanceZmxWatermark(worktree, to: pending.last.id)
```

### Watermark separation

Two cursors exist already in `TeamInbox`: `cursor` (per-session, advances on hook delivery) and `worktreeWatermark` (per-worktree, advances when user reads via `graftty team inbox`).

Add a third: `zmxWatermark` per `(team, worktree, runtime)`. Why a third instead of reusing one of the existing two:

- `cursor` is per-session-id. zmx-send is session-agnostic — it goes to the pane, not to a specific Codex session.
- `worktreeWatermark` advances on user read, which is "I've seen these in my own eyes." zmx delivery advances on "graftty pushed these into the PTY," which doesn't imply user has seen them yet.

Three watermarks tracking three distinct read-states is verbose but keeps each invariant clean.

### Nudge format

Auto-submit: deliver `format(messages) + "\r"`. Justification: this is the Codex equivalent of asyncRewake on Claude, where the message surfaces as a system reminder and the agent resumes processing immediately. Requiring user-Enter would fail the "drop-in equivalent" goal — the user's not necessarily watching the pane when a teammate ping arrives.

`format(messages)` reuses `TeamHookRenderer.format(messages:)` so what the agent sees via zmx-send is byte-identical to what it would have received via `additionalContext`. Wrap with a short prefix line (`"\n[graftty] new message from <sender>:\n"`) so the agent's transcript shows where the input came from.

### zmx-send wire-up

Replace `ZmxNudgeSender.send` body. The pane's `paneID` resolves to a zmx session name via `ZmxLauncher.sessionName(for: paneID)` (which returns `"graftty-<8hex>"`). We then call into the existing in-process `Zmx*` API to write `text` to that session's PTY — same path the existing `zmx send` CLI uses.

This is a function call, not a subprocess — graftty owns the zmx integration, so we don't shell out to a CLI we ourselves implement.

### Observability

Every transition and delivery attempt writes a row to `events.jsonl` via `TeamEventLog.append`. New event kinds:

- `agent_state_transition` — `{from, to, runtime, worktree, trigger: stop|sessionStart|postToolUse|keystroke|timer}`
- `zmx_nudge_attempt` — `{worktree, runtime, paneID, messageIDs, outcome: sent|skipped_no_pane|skipped_state_<x>|error_<reason>}`

These rows live in `events.jsonl`, which is **never routed through `TeamEventDispatcher`** — it's a flat POSIX-`O_APPEND` debug log. Loop-by-replay risk is structurally impossible.

## Spec changes

### Updated requirements

**`TEAM-IDLE-2.1`** (was: 60s-staleness polling)
> While a Codex agent is registered, the application shall maintain an in-process worktree state machine driven by hook events (SessionStart/PostToolUse → active; Stop → idle/user_engaged depending on recent keystrokes) and shall deliver pending normal-priority messages via zmx-send when the state is `idle`.

**`TEAM-IDLE-2.2`** (was: uncommitted-byte typing gate)
> While the recipient pane has received any user keystroke within the last 60 seconds, the application shall hold worktree state at `user_engaged` and skip zmx-send. After 60 seconds of no keystrokes (or no keystroke ever observed), the state shall transition to `idle`.

**`TEAM-IDLE-2.3`** (unchanged in intent, restated against new model)
> While the worktree state has not transitioned and the inbox watermark is unchanged since the last nudge, the application shall send at most one nudge per `(state, watermark)` pair.

### New requirements

**`TEAM-IDLE-2.4`**
> When delivering a nudge to a worktree, the application shall write to the first pane of that worktree and skip delivery if no panes exist.

**`TEAM-IDLE-2.5`**
> When the Stop hook fires for a recipient with one or more unread messages, the application shall (synchronously, as a hook side-effect, before returning `{}`) evaluate idle-delivery for that worktree.

**`TEAM-IDLE-2.6`**
> When `IdleDeliveryService` decides to nudge, it shall invoke the in-process zmx writer with `<formatted-messages> + "\r"` against the resolved pane's session name, and advance a per-`(team, worktree, runtime)` zmx-watermark across the delivered message IDs.

**`TEAM-IDLE-2.7`**
> Each agent-state transition and each nudge attempt shall append a row to `events.jsonl` via `TeamEventLog`, never via `TeamEventDispatcher`, so observability data cannot loop back as inbox messages.

### Deleted requirements

None — `TEAM-IDLE-2.1` and `TEAM-IDLE-2.2` are *retitled*, not deleted, so the spec IDs stay stable.

## Component map

| Component | Status | Notes |
|---|---|---|
| `WorktreeAgentStateRegistry` | new | In-process state-per-worktree; no persistence |
| `PaneInputActivityRegistry` | new | `[PaneID: Date]`, written by libghostty input observer |
| `PaneInputActivityObserver` | new | SwiftUI-side; taps libghostty input boundary |
| `IdleDeliveryService` | rewrite | Drop polling loop; expose `onStop(worktree:)` and `onMessageArrival(worktree:)` |
| `ZmxNudgeSender` | replace stub | NSLog → in-process zmx write |
| `TeamInbox` | extend | Add `zmxWatermark` storage and `advance/read` API |
| `TeamHookRenderer` | unchanged | Stop renderer keeps returning `{}` |
| `TeamInboxRequestHandler` | extend | Stop case calls `idleDelivery.onStop(...)` as side-effect |
| `TeamInboxObserver` | unchanged | Existing event already fires; idle service subscribes |
| `TeamEventLog` | unchanged | New event kinds added; pipeline unchanged |

## Test strategy

Unit tests:

- State machine transitions (each transition + each guard).
- 60s timer: schedules / reschedules / fires. Use a fake clock + a `TimerScheduler` protocol so tests don't sleep.
- `IdleDeliveryService.onStop`: pending messages + idle → delivers; pending + user_engaged → defers; no pending → no-op.
- `IdleDeliveryService.onMessageArrival`: idle → delivers; active → no-op; user_engaged → no-op.
- Watermark advance: same `(state, watermark)` doesn't redeliver.
- First-pane targeting: zero panes → skip-no-pane log; one pane → that pane; multiple → first.
- Observability rows for each transition and each nudge.

Integration:

- End-to-end: write to inbox → observer fires → state is idle → ZmxNudgeSender called with correct text. Stub the actual zmx writer at the seam to avoid PTY in tests.
- Stop hook side-effect: invoke handler with `.stop`, assert `IdleDeliveryService.onStop` ran, assert `{}` is returned.

## Rollout

No feature flag in v1. Match the existing `IdleDeliveryService` shipping posture. The in-process state machine has no persistent state, so a regression is reverted by ship-and-revert without migration.

## Open questions

1. **First-pane definition under pane reordering**: if the user closes pane 0, does pane 1 become the new "first"? Yes — the registry is recomputed from `panes.first` on each evaluation. Worth a test fixture.
2. **Cross-process observability**: do we want to merge in events from other graftty instances pointing at the same `~/.graftty/teams/` root? No — a single graftty app has exclusive ownership of agent panes; cross-process is not a real case.
