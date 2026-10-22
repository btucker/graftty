# Observable worktree store (#493, shared with #480)

**Date:** 2026-10-22. **Issues:** #493 (mobile), #480 (Mac), audit #494.

## Problem

Both clients learn "the worktree rows changed" by re-reading a value on a
1 Hz timer, even though something upstream already knows exactly when it
changes:

- **Mobile (#493).** `WorktreePanesStore` already receives every
  panes-state frame by push over the long-lived subscription that
  `PanesStateSubscription` opens (#551). Yet
  `WorktreeListContent.pollRemoteWorktrees` and
  `SingleSessionView.observeAttention` each call
  `coordinator.worktreePanes(for:)` once per second, then make a second
  actor hop (`navigationSnapshot(for:matching:)`) to get sidebar metadata
  from the same frame. `IPadRootLayout` also bumps
  `externalRefreshToken` after pane mutations to force one more read of
  data the store already holds.
- **Mac (#480).** `SidebarView` rebuilds its navigation every second. Part
  of that rebuild reads this same store
  (`RemoteMacConnectionRegistry.panesSnapshot` → `store.currentSnapshot`).
  The rest reads `AppState`, which has a change point
  (`.onChange(of: appState)`) but no observer API.

## Primitive: `LatestValueBroadcast<Value>` (GrafttyProtocol)

`WorktreePanesStore` lives in GrafttyRemoteClient, and neither
GrafttyRemoteClient nor GrafttyMobileKit depends on GrafttyKit.
GrafttyProtocol is the only module that the Mac app, GrafttyKit,
GrafttyRemoteClient and GrafttyMobileKit all import, so the primitive
lives there:

```swift
public final class LatestValueBroadcast<Value: Sendable>: @unchecked Sendable {
    public init()
    public var latest: Value? { get }          // nil until the first publish
    public func publish(_ value: Value)        // ignored after finish()
    public func updates() -> AsyncStream<Value>
    public func finish()                       // ends every observer's stream
}
```

Contract:

1. **Replay latest.** A new observer first receives the latest value, if
   one exists, then every later publish. Subscribing never races the first
   frame, and an observer that attaches late still starts in a consistent
   state.
2. **Newest-only buffering.** Each observer buffers at most one pending
   value (`.bufferingNewest(1)`). A slow observer skips intermediate
   values and never applies a stale one. Coalescing comes from the
   primitive itself, not from a timer.
3. **Terminal finish.** `finish()` ends every current and future
   observer's sequence. The `for await` loop exits, and the owner decides
   whether to re-subscribe somewhere else.
4. **Synchronous, lock-based publish.** `publish` is callable from any
   isolation without `await`: from the store actor, and from the Mac's
   `@MainActor` `.onChange(of: appState)`. It uses `NSLock`, the
   GrafttyProtocol idiom (`RemoteIdentityFileStores`), because
   `Synchronization.Mutex` needs macOS 15 and the package targets 14.
5. **No equality filtering.** The host sends panes-state frames only when
   they change. Equality is a consumer decision because some publishers
   (a Mac revision tick) carry no meaningful value.

## Store hook (GrafttyRemoteClient)

```swift
public actor WorktreePanesStore {
    public nonisolated let frames: LatestValueBroadcast<PanesStateMessage>
}
```

- `applySnapshot` publishes `.snapshot(rows, sidebar:)` after it updates
  `current`/`sidebar`. Rows and metadata always travel as one frame, so
  observers no longer need `navigationSnapshot(matching:)`'s
  "same frame?" check (REMOTE-14.8 still guards the pull API).
- `markClosed` and `unsubscribe` call `frames.finish()`. A store is one
  channel's lifetime: when the channel ends, its observers end.
- `nonisolated` lets a `@MainActor` view start observing without an actor
  hop. The wire and `PanesStateSubscription` are unchanged.

## Mobile use (#493)

- **Coordinator** (`RemoteConnectionCoordinator.worktreeUpdates(for:)`):
  an `AsyncStream` that bridges store replacement. The loop is: ensure the
  subscription (the existing `worktreePanes(for:)` path, with its dedup
  and failure cooldown) → forward `store.frames` → when that stream
  finishes (close, eviction, or `invalidateAll` on background), report
  the host as unavailable and re-subscribe after a bounded retry delay.
  This replaces the reconnect that the 1 Hz polls currently do as a side
  effect. While the host is healthy the loop sleeps in `for await`.
- **`SingleSessionView`**: `observeAttention` iterates `worktreeUpdates`
  instead of polling. It keeps clearing the count while the host is
  unavailable.
- **`WorktreeListContent`**: `pollRemoteWorktrees` becomes the same
  `for await`. `externalRefreshToken` is deleted because a pane mutation's
  result arrives as a frame. `refresh(reconnect:)` stays for initial load,
  pull-to-refresh and Retry.
- **One source of truth on iPad.** `appState.latestWorktrees` is fed
  directly from the same stream at layout level, which retires
  `onListChanged`. The exact cut is settled in that PR, against the
  selection-generation guards.
- **Out of scope:** `RemoteOpenButton`'s 3 s `openResource(.list)` poll.
  Open-resource offers travel on the worktree-management channel and are
  not part of a panes-state frame, so making them push requires a wire
  change. That is filed as a follow-up.

## Mac reuse (#480)

- **Remote rows:** `SidebarView` (and the WebRTC relay) can observe each
  remote Mac's `store.frames` instead of re-reading `currentSnapshot` every
  second.
- **Local rows:** an `AppStateChanges = LatestValueBroadcast<UInt64>`
  revision counter, published from the existing `.onChange(of: appState)`
  plus the other change points listed in #480. Replay-latest gives each
  new subscriber an immediate first build; newest-only buffering coalesces
  bursts. Debouncing and the safety-net tick that #480 proposes stay with
  the consumer (`for await` plus a `Task.sleep`-bounded race), not in the
  primitive.

## Staging

1. This note, `LatestValueBroadcast`, and the store hook.
2. Coordinator `worktreeUpdates(for:)` and the push version of
   `SingleSessionView` attention (retires the iPhone 1 Hz timer).
3. `WorktreeListContent` push; delete `pollRemoteWorktrees` and
   `externalRefreshToken`.
4. iPad single source of truth (`onListChanged` / `latestWorktrees`).
