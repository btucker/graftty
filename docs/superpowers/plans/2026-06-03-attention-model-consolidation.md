# Attention model consolidation — Implementation Plan

> REQUIRED SUB-SKILL: superpowers:test-driven-development per task (RED→GREEN).

**Goal:** Collapse the scattered attention set/clear code paths onto one model-owned API, add an `Attention.source`, and make "busy" and "needs input" mutually exclusive (an agent that resumes working clears its own "needs input" pill — which also un-suppresses the busy italic).

**Why:** attention is currently set in 3 places and cleared in ~6, with divergent scope — notably `selectWorktree` (worktree click) clears worktree **and** pane attention, while `acknowledgeSelection` (notification click) clears **only** worktree attention, so a pane-scoped "needs input" pill survives a notification click. There's no `source`, so we can't distinguish an agent-stop pill from a deliberate `graftty notify` ping.

**Branch:** `dont-show-working` (folds into PR #206 — it fixes that feature's bugs).

---

## Model

### `Attention.source` (`Sources/GrafttyKit/Model/Attention.swift`)
Add:
```swift
public enum AttentionSource: String, Codable, Sendable {
    case agentStop        // "<Agent> needs input" from a Stop hook
    case userNotify       // graftty notify (deliberate user ping)
    case commandFinished  // ✓ / ! shell-integration COMMAND_FINISHED
}
```
Add `public let source: AttentionSource` to `Attention`; init param defaults to `.userNotify`. Decode backward-compatibly: `decodeIfPresent(AttentionSource.self, forKey: .source) ?? .userNotify` (legacy persisted pings are treated as user pings → never auto-cleared on resume; conservative).

### `WorktreeEntry` API (`Sources/GrafttyKit/Model/WorktreeEntry.swift`)
One cohesive set of mutators; all attention mutation goes through these (except timestamp-guarded auto-clear, which stays as `clearAttentionIfTimestamp`/`clearPaneAttentionIfTimestamp`, and pane-lifecycle removal):
```swift
/// Set attention scoped to a pane, or worktree-scoped when `pane` is nil.
mutating func setAttention(_ attention: Attention, pane: PaneSlotID?)

/// The user is now looking at this worktree — clear ALL attention
/// (worktree + every pane). Used by both worktree-click and
/// notification-activation. (STATE-2.4)
mutating func acknowledgeAttention()

/// An agent resumed work in one of these sessions — clear only the
/// `.agentStop` "needs input" pill for the matching pane(s). `.userNotify`
/// and `.commandFinished` pills are left alone. (AGENT-3.4)
mutating func clearAgentStopAttention(forBusySessionNames busy: Set<String>)
```
`acknowledgeAttention` body = `attention = nil; paneAttention.removeAll()`.
`clearAgentStopAttention` iterates `paneSessions`, maps each to `ZmxLauncher.sessionName(for:)`, and nils `paneAttention[slot]` where the name is busy AND `source == .agentStop`. Also clears worktree-scoped `attention` if its source is `.agentStop` and any of the worktree's sessions is busy.

### `AppState` (`Sources/GrafttyKit/Model/AppState.swift`)
```swift
/// Apply the resume rule across all worktrees on a liveness update.
mutating func clearAgentStopAttentionForBusyPanes(liveness: [String: AgentLiveness])
```
Computes `busy = Set(liveness.filter { $0.value == .busy }.keys)`, calls `clearAgentStopAttention(forBusySessionNames:)` on every worktree.

## Caller routing (the collapse)

| Caller | Was | Now |
|---|---|---|
| `recordAgentStop` (GrafttyApp ~2273) | `paneAttention[slot]=`/`attention=` direct | `setAttention(Attention(…, source: .agentStop), pane: slot?)` |
| `.notify` handler (GrafttyApp ~1963) | direct + `setAttentionForTerminal` | `setAttention(…, source: .userNotify, …)` |
| `onCommandFinished` (GrafttyApp 791) → `setAttentionForTerminal` | pane set + auto-clear | `setAttentionForTerminal` sets `source: .commandFinished` |
| `selectWorktree` (MainWindow 388-389) | `attention=nil; paneAttention.removeAll()` | `acknowledgeAttention()` |
| `acknowledgeSelection` (AgentStopNotification 79) | clears worktree only | clear worktree **and** panes (call into `acknowledgeAttention`-equivalent over the matched worktree) — fixes the notification-click stuck-pill bug |
| liveness update (MainWindow `.onChange`) | — | `appState.clearAgentStopAttentionForBusyPanes(liveness:)` |

`setAttentionForTerminal` keeps its timestamp-guarded auto-clear; it gains a `source` parameter (default `.commandFinished` is wrong — pass explicitly from each caller).

## Specs
- **New AGENT-3.4:** "When a pane's agent transitions to busy, the application shall clear that pane's agent-stop 'needs input' attention (but not user `notify` pings), so busy and needs-input are mutually exclusive."
- **AGENT-2.2** already says busy → italic; no text change, but it's now reliably observable.
- **STATE-2.4 / notification-activation:** ensure the EARS/coverage reflects that *both* worktree-click and notification-activation clear pane + worktree attention.
- Regenerate `SPECS.md`.

## Tests (TDD)
- `AttentionTests`: `source` round-trips; legacy decode (no `source`) → `.userNotify`.
- `WorktreeEntryTests`: `acknowledgeAttention` clears worktree + all panes; `clearAgentStopAttention(forBusySessionNames:)` clears only `.agentStop` panes whose session is busy, leaves `.userNotify`/`.commandFinished` and non-busy panes; worktree-scoped agentStop cleared when a session is busy.
- `AppStateTests`: `clearAgentStopAttentionForBusyPanes` applies across worktrees.
- `AgentStopNotificationTests`: `acknowledgeSelection` now also clears pane attention.
- Existing STATE-2.x auto-clear + notify/clear tests stay green.

## Verify
`swift build`; `swift test`; iOS build-for-testing (MainWindow `.onChange` is Mac-only, but WorktreeListContent untouched here); `/simplify`; `/code-review`; push to #206.
