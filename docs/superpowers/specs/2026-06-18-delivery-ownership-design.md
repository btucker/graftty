# Runtime-agnostic team delivery ownership

**Status:** Draft
**Date:** 2026-06-18
**Branch:** `codex-injection`

## Summary

Graftty team inbox delivery needs one shared rule for every agent runtime:
automatic delivery for a `(team, worktree, runtime)` is owned by exactly one live
registered agent. Runtime transports may differ, but none of them may fan out the
same worktree message to multiple panes or multiple runtime sessions.

This spec introduces a runtime-agnostic delivery ownership resolver derived from
Graftty presence. Claude uses it to decide whether `team watch-inbox claude`
should arm its `asyncRewake` watcher. Codex uses it to decide whether app-server
delivery may send a turn into the currently visible thread. The shared policy is
independent of Claude hooks, Codex app-server mechanics, and zmx/PTY delivery.

## Goals

1. Define one automatic inbox delivery owner per `(teamID, worktree, runtime)`.
2. Make the owner deterministic: the first live registered agent wins.
3. Prevent duplicate automatic delivery when more than one agent of the same
   runtime is present in one worktree.
4. Let Claude and Codex share ownership logic while keeping their transport code
   runtime-specific.
5. Never mark inbox messages delivered unless a transport actually handed them
   to the owning agent.
6. Give Codex a path away from zmx/PTY message injection without changing the
   user-facing "first agent in the worktree gets messages" model.

## Non-goals

1. Replacing Claude's `asyncRewake` transport. This design gates it; it does not
   remove it.
2. Delivering messages to whichever agent is idle. Liveness decides ownership;
   transport health does not promote secondaries.
3. Fanout across panes, sessions, or threads in the same worktree/runtime.
4. Making manual `graftty team inbox` primary-aware. Manual reads remain
   available to any session.
5. Removing zmx delivery in the first implementation step. Codex app-server
   delivery should reach equivalent coverage before zmx injection is removed.

## Current behavior

Claude registers an async Stop watcher through the hook installer:
`graftty team watch-inbox claude` with `asyncRewake`. The watcher is keyed by
Claude session id and recipient worktree/member. It supersedes older watchers for
the same Claude session, but it is not currently gated by a worktree-level primary
agent decision. If two Claude sessions in the same worktree both stop and both
watch the same inbox, they can both wake for one new message.

Codex currently has hook registration and a zmx-based idle delivery path. Stop
hooks cannot inject normal additional context. App-server experiments showed that
Graftty can send a non-PTY turn into a visible Codex TUI thread when it knows the
thread id and app-server socket, but `/resume` can switch the visible thread to a
different cwd. Codex delivery must therefore validate the thread before sending.

`TeamPresenceRecord` already carries most cross-runtime identity needed for a
shared policy: `teamID`, `worktree`, `runtime`, `paneSessionName`, `pid`, and
`registeredAt`. This design extends it with stable process identity
(`processStartTime`) so ownership does not rely on PID liveness alone. Presence
should be the source of truth for ownership candidates.

## Ownership model

Automatic inbox delivery is owned by exactly one live registered agent per
`(teamID, worktree, runtime)`. Ownership is runtime-agnostic and derived from
Graftty presence. Runtime-specific mechanisms may only deliver when they can prove
they are acting for that owner.

Add a small shared model:

```swift
struct TeamDeliveryOwnerKey: Hashable {
    var teamID: String
    var worktree: String
    var runtime: AgentRuntime
}

struct TeamDeliveryOwner: Equatable {
    var key: TeamDeliveryOwnerKey
    var paneSessionName: String
    var pid: Int32
    var processStartTime: Date
    var registeredAt: Date
    var runtimeSessionID: String?
}

struct TeamDeliveryOwnerCandidate {
    var key: TeamDeliveryOwnerKey
    var paneSessionName: String?
    var pid: Int32?
    var processStartTime: Date?
    var runtimeSessionID: String?
}
```

Add a resolver:

```swift
protocol TeamDeliveryOwnershipResolving {
    func owner(for key: TeamDeliveryOwnerKey) throws -> TeamDeliveryOwner?
    func isOwner(_ candidate: TeamDeliveryOwnerCandidate,
                 for key: TeamDeliveryOwnerKey) throws -> Bool
}
```

The resolver computes ownership on demand:

1. Load presence records for the team.
2. Filter to the requested worktree and runtime.
3. Drop records without a valid `paneSessionName`.
4. Drop records whose pane session is no longer known to Graftty.
5. Drop records whose process identity is no longer valid.
6. Sort remaining records by `registeredAt`, then `paneSessionName`, then `pid`.
7. Return the first record.

Process identity must be stronger than `kill(pid, 0)` alone. PID liveness is
necessary but not sufficient because a stale presence record can survive long
enough for the OS to reuse the PID. Extend `TeamPresenceRecord` with a stable
process identity captured at registration time, starting with `processStartTime`.
The resolver should verify that the live process for `pid` still has the same
start time recorded in presence. If start time cannot be read at registration or
cannot be verified during resolution, that record is ineligible for automatic
delivery ownership.

The resolver should not let a watcher, app-server client, or idle-delivery service
acquire ownership by running first. A durable lease file is not needed for the
initial design because presence already gives us the authoritative candidates and
PID liveness gives us stale-owner cleanup.

## Runtime identity

The shared owner is identified by Graftty identity first:
`paneSessionName`, `pid`, `processStartTime`, `registeredAt`, `teamID`,
`worktree`, and `runtime`. Runtime-native identifiers are optional attachments
used only to prove that a transport is acting for the owning Graftty agent.

Claude proof should use the hook payload plus inherited Graftty environment. The
watch command already receives Claude hook JSON and runs inside the wrapped
process environment. If the hook payload does not identify the pane directly, the
watch path should resolve the current pane through wrapper-provided environment
such as `ZMX_SESSION`, or through a session-id-to-pane mapping recorded during
SessionStart.

Codex proof should use the owning pane/process identity plus Codex app-server
state: socket path, visible thread id, thread cwd, and thread status. A Codex
thread id alone is not a delivery owner because `/resume` can switch the visible
thread independently of the worktree that launched the pane.

Agents launched outside Graftty panes should not become automatic delivery
owners unless they have a valid `paneSessionName` presence record. They may still
read the inbox manually.

## Claude transport behavior

`graftty team watch-inbox claude` should become owner-gated:

1. Read the existing hook JSON from stdin.
2. Resolve team, worktree, runtime, recipient, and current candidate identity.
3. Build `TeamDeliveryOwnerKey(teamID, worktree, .claude)`.
4. Ask `TeamDeliveryOwnershipResolver.isOwner(candidate, for: key)`.
5. If false, exit quietly without arming `InboxWatcher`.
6. If true, arm the existing `InboxWatcher`.
7. When a matching message arrives, keep the existing `asyncRewake` exit behavior.

The watcher should not advance inbox cursors or watermarks. The later Claude hook
turn remains responsible for rendering unread messages and advancing delivery
state through the existing inbox path.

That later hook render path must also be owner-gated before it renders unread
automatic-delivery messages or advances cursor/watermark state. Gating only the
async watcher is not enough: a non-owner Claude session can still hit
SessionStart, PostToolUse, or Stop hooks independently. Non-owner hooks may return
runtime primers or other non-inbox context, but they must not consume or mark
worktree inbox messages delivered.

This change makes the current per-session watcher safe when several Claude
sessions exist in one worktree: only the primary session arms an async watcher.

## Codex transport behavior

Codex delivery should use the same owner resolver before any app-server turn is
started. The transport may send only when all validation passes:

1. The selected presence record is still the owner for
   `(teamID, worktree, .codex)`.
2. The owner PID is alive.
3. Graftty knows the owner's app-server socket.
4. Graftty knows the owner's currently visible thread id.
5. The active thread cwd matches the owner's worktree.
6. The thread is idle and able to accept a new turn.
7. The pending inbox messages have not already been delivered past the relevant
   cursor or watermark.

If validation fails, Codex delivery must not fall back to zmx/PTY injection as a
silent recovery path. It should leave the inbox unread and expose a suspended
delivery state that explains why the owner cannot currently be reached, for
example: `delivery suspended: active codex thread cwd does not match worktree`.

During migration, zmx/PTY delivery may remain available only for the existing
legacy delivery path before app-server delivery is enabled for a target. Once an
app-server target is selected for a delivery attempt, validation failure is
fail-closed: do not retry the same message through zmx. This prevents app-server
guardrails such as cwd validation from being bypassed by fallback typing.

The `/resume` case is explicitly guarded by cwd validation. If the user resumes a
thread from another repository in the attached Codex TUI, that thread is not a
valid target for the current worktree's team messages.

The implementation plan should pin the exact app-server signal used to determine
whether a thread is idle. If the API does not provide a reliable idle signal,
Codex app-server delivery should remain disabled and the legacy path should stay
in place until that signal exists.

## Delivery state

Keep persistent state minimal:

- Presence records define candidates.
- Inbox cursors and worktree/runtime watermarks define delivered messages.
- Runtime transport state records only how to reach the owner.

Ownership is recomputed on each delivery attempt. Dead PIDs are ignored.
Transport state that is missing, stale, or inconsistent suspends delivery but
does not transfer ownership to a secondary agent.

Only the path that actually renders or sends messages to the owning agent may
advance cursor or watermark state. Failed attempts, non-owner attempts, suspended
Codex delivery, and non-primary Claude watchers must not mark messages delivered.

## User-visible semantics

The user-facing model is:

- The first live agent of a runtime in a worktree receives automatic team inbox
  delivery.
- Additional agents in the same worktree/runtime do not automatically receive
  those messages.
- If the first agent exits, the next live registered agent becomes the owner.
- If the first agent is alive but its transport is unavailable, messages remain
  pending for that owner.
- Any agent may still run `graftty team inbox` manually.

This preserves the existing "first agent in the worktree gets messages" behavior
and avoids surprising failover to a secondary pane just because the primary
transport is temporarily unavailable.

## Observability

Delivery decisions should be visible enough to debug stuck inboxes:

- owner selected
- owner skipped because PID is dead
- non-owner Claude watcher skipped
- Codex delivery suspended because socket/thread/cwd/status validation failed
- message delivery sent
- message delivery failed without advancing state

These can be logged through the existing team event/debug mechanisms. They should
not be routed as team inbox messages.

## Migration plan

1. Add the shared delivery ownership resolver and focused unit tests.
2. Gate Claude `watch-inbox` with the resolver while preserving the existing
   `asyncRewake` transport.
3. Add Codex owner validation to the current idle-delivery path.
4. Add Codex app-server transport state tracking: owner socket, visible thread id,
   cwd, and idle/running status.
5. Send Codex non-urgent delivery through app-server when owner validation passes.
6. Keep zmx delivery only as the pre-app-server legacy path while app-server
   coverage is being verified. Do not use zmx as a fallback after an app-server
   delivery attempt fails validation.
7. Remove zmx/PTY injection for Codex team inbox delivery after app-server
   delivery has equivalent coverage.

Equivalent coverage for removing zmx means:

- Codex app-server delivery has tests for owner validation, cwd mismatch,
  thread-running refusal, successful delivery, and no cursor/watermark advance on
  failure.
- A manual smoke test confirms a message sent to an idle Codex TUI appears in the
  visible owner thread without PTY typing.
- A manual smoke test confirms `/resume` to a thread in another cwd suspends
  delivery instead of injecting into that thread.
- Claude owner-gated delivery continues to pass its watcher and render-path tests.
- zmx removal does not remove manual `graftty team inbox`.

## Testing

Unit tests should cover the shared invariant first:

- The ownership resolver picks the earliest live presence record for
  `(team, worktree, runtime)`.
- Dead PIDs are ignored and the next live candidate becomes owner.
- A reused PID with a different process start time is ignored.
- A presence record without verifiable process start time is ineligible for
  automatic ownership.
- Ties are deterministic by `paneSessionName` and `pid`.
- Records from other teams, worktrees, or runtimes are ignored.
- A candidate matching the owner returns true from `isOwner`.
- A later candidate in the same worktree/runtime returns false.

Claude tests:

- Owner Claude watcher arms `InboxWatcher`.
- Non-owner Claude watcher exits quietly and does not arm `InboxWatcher`.
- Owner watcher wake does not advance inbox cursor or watermark directly.
- Claude sessions without Graftty pane identity do not become automatic owners.

Codex tests:

- Delivery sends only when the target is the current owner and the active thread
  cwd matches the worktree.
- Delivery refuses to send when `/resume` has switched the active thread to a
  different cwd.
- Delivery refuses to send when the target is not the current owner.
- Suspended or failed delivery does not advance cursor or watermark.
- Manual `graftty team inbox` remains available from a non-owner session.

Integration tests should exercise at least one duplicate-prevention path per
runtime: two Claude sessions in one worktree with one incoming message, and two
Codex-capable panes/threads in one worktree with one incoming message.

## Planning decisions

1. Owner selection requires `paneSessionName`. A CLI-launched agent outside a
   Graftty pane is not eligible for automatic delivery.
2. App-server delivery requires a reliable idle/running signal. If planning
   cannot identify one, app-server delivery remains disabled.
3. App-server validation is fail-closed. zmx may continue only as the legacy path
   before an app-server delivery attempt is selected; it is not a fallback after
   app-server validation fails.
