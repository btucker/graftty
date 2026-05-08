# Pane-specific team registration & keys-input delivery

## Problem

`graftty team register --runtime <codex|claude>` records agent presence at
worktree granularity: `(teamID, worktree, runtime, pid, registeredAt)`. The
inbox-observer dispatch path resolves a delivery target via
`WorktreeEntry.firstPane` (focused pane, falling back to the first split-tree
leaf), then types pending team-message text into that pane via the
`SurfaceHandle.typeText` path.

When a worktree has multiple panes — e.g. codex in pane #1, a shell in pane
#2 — `firstPane` can resolve to a non-codex pane (most commonly when the
user has focused a sibling pane). The text gets typed into the wrong pane.

PR #136 closed an adjacent gap (TEAM-IDLE-2.8): when the runtime can't be
confirmed as codex, skip delivery. But it doesn't address the multi-pane
case: a worktree with one confirmed codex pane and one shell will still
route to whichever the worktree's `firstPane` happens to be.

The root cause is that registration is not pane-specific. The CLI register
command is the natural place to record per-pane identity, but it currently
captures only worktree+runtime.

## Goal

The unit of registration shall be **(pane × worktree × runtime)**, recorded
by the explicit CLI register command, regardless of which runtime is
registering. Codex/claude differentiation remains a delivery-time concern.

When pending team messages arrive for a worktree, the keys-input nudge is
fanned out to *every* registered codex pane in that worktree, with the
inbox watermark advancing once per message.

## Non-goals

- Detecting "codex exited but the pane lives on" (stale registration after
  the agent process exits in-place without firing unregister). Pre-existing
  issue; out of scope.
- Per-pane watermarks. Watermark scope stays
  `(team, worktree, runtime)`; new panes joining mid-stream do not replay
  history.
- Removing the `team register`/`team unregister` CLI surface. The agent is
  still expected to call them per the existing `teamSessionPrompt` /
  wrapper-cleanup flow.

## Design

### Registration shape

`TeamPresenceRecord` (`Sources/GrafttyKit/Teams/TeamPresenceStorage.swift`)
gains an optional pane-session-name field:

```swift
public struct TeamPresenceRecord: Codable, Sendable {
    public let teamID: String
    public let worktree: String
    public let runtime: TeamHookRuntime
    public let paneSessionName: String?    // NEW — value of ZMX_SESSION
    public let pid: Int32
    public let registeredAt: Date
}
```

Storage path keys by `(teamID, worktree, runtime, paneSessionName)`. The
filename incorporates `paneSessionName` (defaulting to a sentinel like
`"_no_pane"` when nil) so multiple panes registering the same runtime in
the same worktree do not collide.

Old `TeamPresenceRecord` JSON files lacking the field decode with
`paneSessionName: nil`. They remain visible in the team roster and team
activity log but are ineligible for keys-input delivery.

### CLI: `graftty team register`

`Sources/GrafttyCLI/Team.swift` `TeamRegister.run()` reads
`ProcessInfo.processInfo.environment["ZMX_SESSION"]` and stores the value
on the record. The CLI does not contact the daemon for pane resolution;
sessionName → paneID resolution happens at the daemon read site.

When `ZMX_SESSION` is unset (codex run outside a graftty-launched zmx
pane), the record is still written with `paneSessionName: nil`. The record
contributes to roster visibility and team-event logging but produces no
keys-input delivery.

### CLI: `graftty team unregister`

`TeamUnregister.run()` reads `ZMX_SESSION` symmetrically and deletes the
matching `(teamID, worktree, runtime, paneSessionName)` record. Sibling
panes' registrations remain. The wrapper script's `cleanup()` function
(`AgentHookInstaller.swift:263`) inherits `ZMX_SESSION` from its parent
shell, so the right record is removed at exit.

### Hooks become pure event signals

`onSessionStart`, `onPostToolUse`, and `onStop` (in `TeamHookCallbacks`)
no longer write to any registration store. Registration is owned
exclusively by the explicit CLI command. The hook callbacks remain
responsible for state-machine bookkeeping (`WorktreeAgentStateRegistry`)
and triggering the idle-delivery dispatcher.

The in-memory `agentForPane: [UUID: (worktree, runtime)]` map on
`AppServices` is removed. Its two consumers are migrated:

1. **`PaneInputActivityObserver.onKeystroke`** — currently looks up the
   pane's `(worktree, runtime)` to drive the state registry and grace
   timer. Re-implement by reading `TeamPresenceStorage.listAll()` and
   matching on `paneSessionName == ZmxLauncher.sessionName(for: paneID)`.
   Acceptable cost — file-count is bounded by active-agent count
   (typically <20).

2. **Inbox-observer dispatch** (currently uses `agentForPane` via the
   `resolveRuntime` helper at `GrafttyApp.swift:862`) — replaced as
   described below.

### Inbox-observer dispatch

`Sources/Graftty/GrafttyApp.swift` (around line 970-1000) replaces its
`resolveRuntime` + `resolvePaneID(worktree)` chain with a single helper
that returns the list of codex paneIDs registered in the recipient
worktree:

```swift
let codexPanesIn: @Sendable (String) -> [UUID] = { worktreePath in
    MainActor.assumeIsolated {
        let records = (try? presenceStorage.listAll()) ?? []
        let codexSessions = records
            .filter { $0.worktree == worktreePath && $0.runtime == .codex }
            .compactMap { $0.paneSessionName }
        return codexSessions.compactMap { sessionName in
            terminalManager.handle(forSessionName: sessionName)?.paneID
        }
    }
}
```

(`SurfaceHandle.paneID` exists or is added — minor accessor.)

The Task callback inside the observer becomes:

```swift
Task { @MainActor in
    let paneIDs = codexPanesIn(recipientWorktree)
    await service.onMessageArrival(
        team: teamID,
        worktree: recipientWorktree,
        paneIDs: paneIDs
    )
}
```

The `runtime` parameter is dropped from `onMessageArrival` — the gate is
now purely "are there registered codex panes?", expressed by `paneIDs`
non-emptiness. (Symmetric for `onStop`, where the caller wraps the
single hook-fired paneID as `[paneID]`.)

### `IdleDeliveryService` API

```swift
public func onStop(team: String, worktree: String, paneIDs: [UUID]) async
public func onMessageArrival(team: String, worktree: String, paneIDs: [UUID]) async

private func maybeDeliver(team: String, worktree: String,
                          paneIDs: [UUID], trigger: String) async {
    guard !paneIDs.isEmpty else {
        log(... outcome: "skipped_no_codex_panes")
        return
    }
    // existing state-gate, watermark read, pending-message resolution …
    for paneID in paneIDs {
        await nudgeSender.send(paneID: paneID, message: text,
                               messageIDs: pending.map(\.id))
    }
    // single watermark advance for the (team, worktree, runtime="codex")
    try inbox.advanceZmxWatermark(teamID: team, worktree: worktree,
                                  runtime: "codex", to: lastMessage.id)
}
```

The service is implicitly codex-only after this change. `runtime` is
gone from the public API; the watermark is advanced against `"codex"`
literally inside the implementation. Two upstream gates ensure only
codex paneIDs reach the service:

- **Inbox-observer dispatch** filters `TeamPresenceStorage` records by
  `runtime == .codex` before resolving paneIDs.
- **`onStop` hook callback** (in `GrafttyApp.swift`) always updates the
  state machine for both runtimes, but only invokes
  `idleService.onStop(paneIDs:)` when `runtime == .codex`. Claude's Stop
  hook still flips the state machine but never triggers keys-input —
  asyncRewake remains its canonical delivery path.

The Stop-hook callback resolves its own paneID from the hook's
`paneSessionName` (carried via the new wire-protocol field below) before
calling `idleService.onStop(paneIDs: [paneID])`. If `paneSessionName` is
nil or doesn't resolve, the callback skips the idle-delivery call and
logs the skip — state-machine bookkeeping still happens.

### Wire protocol for hooks

`NotificationMessage.swift` `.teamHook` adds an optional
`paneSessionName: String?` so the daemon can resolve the firing pane
without re-reading registration storage. `Sources/GrafttyCLI/Team.swift`
`TeamHook.run()` reads `ZMX_SESSION` and includes it.

```swift
case teamHook(callerWorktree: String, runtime: TeamHookRuntime,
              event: TeamHookEvent, sessionID: String?,
              paneSessionName: String?)        // NEW
```

JSON key: `pane_session_name`. Old encoders emit no such field; new
decoders default to `nil`.

### Pane-close cleanup

`Sources/Graftty/GrafttyApp.swift` ~line 1017-1027 currently removes
`agentForPane[paneID]` when a pane is destroyed. It is extended to also
remove any matching `TeamPresenceStorage` record:

```swift
let sessionName = ZmxLauncher.sessionName(for: paneID)
try? presenceStorage.deleteByPaneSessionName(sessionName)
```

(The agent's own `team unregister` cleanup hook normally handles this,
but pane-destroy is the safety net for ungraceful exits.)

## Specs (EARS)

- **TEAM-IDLE-2.9** — When `graftty team register --runtime <r>` is
  invoked with `ZMX_SESSION=<name>` set in its environment, the
  application shall record `paneSessionName == <name>` on the
  `TeamPresenceRecord` it writes.

- **TEAM-IDLE-2.10** — When `graftty team register --runtime <r>` is
  invoked without `ZMX_SESSION`, the application shall record
  `paneSessionName == nil`. The record contributes to roster visibility
  and event logging but the dispatch site shall treat it as ineligible
  for keys-input delivery.

- **TEAM-IDLE-2.11** — When two `TeamPresenceRecord`s with
  `runtime == .codex` and distinct `paneSessionName`s exist for the
  same worktree, the application shall deliver each pending team
  message to *every* registered codex pane and advance the zmx
  watermark exactly once per message.

- **TEAM-IDLE-2.12** — When zero `TeamPresenceRecord`s with
  `runtime == .codex` and a non-nil `paneSessionName` exist for the
  recipient worktree, the application shall not deliver via keys-input
  and shall log `outcome == skipped_no_codex_panes`.

- **TEAM-IDLE-2.13** — When `graftty team unregister --runtime <r>` is
  invoked with `ZMX_SESSION=<name>`, the application shall remove only
  the record matching `(worktree, runtime, paneSessionName=<name>)`;
  sibling panes' registrations shall remain.

- **TEAM-IDLE-2.14** — `TeamPresenceRecord`s with `runtime == .claude`
  and a non-nil `paneSessionName` shall not produce keys-input delivery
  (the asyncRewake watcher remains the canonical delivery path for
  Claude). The record shall remain queryable for roster and event-log
  purposes.

- **TEAM-IDLE-2.15** — When a pane is destroyed, the application shall
  remove any `TeamPresenceRecord` whose `paneSessionName` corresponds
  to that pane.

## Scope

This change touches:

- `Sources/GrafttyKit/Teams/TeamPresenceStorage.swift` — record schema,
  storage key, query helpers.
- `Sources/GrafttyCLI/Team.swift` — `TeamRegister`, `TeamUnregister`,
  `TeamHook` read `ZMX_SESSION`.
- `Sources/GrafttyKit/Notification/NotificationMessage.swift` — new
  `paneSessionName` field on `.teamHook`.
- `Sources/GrafttyKit/Teams/TeamInboxRequestHandler.swift` — accept and
  forward `paneSessionName` into hook callbacks.
- `Sources/GrafttyKit/Teams/IdleDeliveryService.swift` — API shift to
  `paneIDs: [UUID]`, fan-out, codex-only-by-construction.
- `Sources/Graftty/GrafttyApp.swift` — drop `agentForPane`,
  introduce `codexPanesIn(worktree:)` helper, route `paneIDs` through.
- `Sources/Graftty/Terminal/SurfaceHandle.swift` — add `paneID` accessor
  if not already present.
- `Tests/GrafttyKitTests/Teams/*` and `Tests/GrafttyTests/Specs/*` —
  new spec tests for TEAM-IDLE-2.9 through 2.15.

## Migration

- On-disk: old `TeamPresenceRecord` JSON files (no `paneSessionName`)
  decode as `nil`. They become "worktree-only" records — visible to
  teammates, ineligible for keys-input. Replaced naturally on the next
  `team register` cycle.
- In-memory: `agentForPane` removal is pure code deletion. Existing
  graftty processes restart-recover from `TeamPresenceStorage`.

## Test plan

Unit tests for each spec ID listed above, plus:

- `TeamPresenceStorage` round-trip with and without `paneSessionName`.
- `IdleDeliveryService` fan-out test: `paneIDs.count == 3` →
  `nudgeSender.calls.count == 3`, watermark advances once.
- End-to-end (`IdleDeliveryEndToEndTests`): two registered codex panes
  → both `StubWriter.writes` entries appear with the right session
  names; watermark file contains the last message ID once.

Manual smoke test (post-merge):

1. Open a worktree, split into two panes.
2. Run codex in pane #1, run a plain shell in pane #2.
3. From a teammate, send a team message to this worktree.
4. Confirm keys-input appears in pane #1 (codex), not pane #2 (shell),
   regardless of which pane is focused.
