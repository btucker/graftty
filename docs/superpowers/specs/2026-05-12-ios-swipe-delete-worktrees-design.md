# iOS swipe-to-delete worktrees + sidebar-order grouping

**Status:** draft
**Date:** 2026-05-12

## Goal

In GrafttyMobile's `WorktreePickerView`:

1. Let the user swipe a worktree row to delete (non-stale rows) or dismiss (stale rows), mirroring the Mac sidebar's two-flavored removal contract.
2. Render repo groups in the same order as the Mac app sidebar instead of alphabetic order.

## Non-goals

- "Remove Repository" mobile action (only worktree-level removal here).
- Multi-select / batch delete.
- Undo / trash.
- Web client parity (this PR adds the wire endpoint; the web client picks it up in a follow-up).

## Background

The Mac sidebar already has two removal semantics:

- **Delete** — `git worktree remove [--force] <path>` then tears down surfaces, clears stats/PR caches, drops the model entry, fires the `left` team event. Implementation: `MainWindow.performDeleteWorktree` in `Sources/Graftty/Views/MainWindow.swift`.
- **Dismiss** — the on-disk dir is gone but the git admin entry survives. Run `git worktree prune` then drop the model entry. Same teardown path. Triggered when `GitWorktreeRemove` fails because `FileManager.default.fileExists(atPath: worktreePath) == false`. Spec ID `GIT-3.6` / `GIT-4.13`.

The mobile picker `Sources/GrafttyMobileKit/UI/WorktreePickerView.swift` currently has no removal affordance and groups repos alphabetically via `grouped()`. The `/worktrees/panes` endpoint already serves repos in `appState.repos` order (`Sources/Graftty/GrafttyApp.swift:1128`), so the mobile fix is purely client-side ordering.

## Architecture

### New components

1. **`DeleteWorktreeFlow.delete(...)`** (`Sources/Graftty/DeleteWorktreeFlow.swift`) — actor-isolated funnel extracted from `MainWindow.performDeleteWorktree`. Takes the same dependencies pattern `AddWorktreeFlow.add` uses (`appState`, `worktreeMonitor`, `statsStore`, `prStatusStore`, `terminalManager`, `teamEventDispatcher`, `force: Bool`). Owns: git invocation, prune-on-vanished, surface teardown, cache clears, model removal, team event. Does NOT own confirmation alerts.
2. **`DeleteWorktreeClient`** (`Sources/GrafttyMobileKit/Session/DeleteWorktreeClient.swift`) — mirror of `CreateWorktreeClient`. One method `delete(baseURL:request:)`, decodes the response envelope.
3. **`WebServer.DeleteWorktreeRequest` + `DeleteWorktreeOutcome`** in `WebServer.swift` — same shape as the existing create variants.
4. **`worktreeRemover: (@Sendable (DeleteWorktreeRequest) async -> DeleteWorktreeOutcome)?`** on `WebServer.Config` and a `setWorktreeRemover(_:)` setter on `WebServerController`.

### Refactor of existing components

- `MainWindow.performDeleteWorktree` shrinks to: present confirmation alert → call `DeleteWorktreeFlow.delete(force: false)` → on `gitFailed` outcome, present Force Delete alert → call `DeleteWorktreeFlow.delete(force: true)`. The NSAlert UX stays in `MainWindow` because the alert text and short-status format are sidebar-specific. The mobile flow funnels through the same `DeleteWorktreeFlow` but owns its own SwiftUI `.confirmationDialog` chain.
- `GrafttyApp.startup()` adds a `webController.setWorktreeRemover { req in ... DeleteWorktreeFlow.delete(...) ... }` block adjacent to the existing `setWorktreeCreator` block.

### HTTP contract

`POST /worktrees/delete`

Request body:

```json
{ "worktreePath": "/abs/path/to/wt", "force": false }
```

Response shapes:

- `200 OK` `{ "dismissed": true|false }` — success. `dismissed` is `true` when the server took the GIT-3.6/4.13 prune path; `false` when it ran `git worktree remove`. The mobile client uses this only to label any toast/log, NOT to gate UI (the row disappears either way).
- `400 Bad Request` `{ "error": "<msg>" }` — empty path, main-checkout path, non-git repo. Defense-in-depth; client should not normally produce these.
- `404 Not Found` `{ "error": "<msg>" }` — `worktreePath` doesn't match any known worktree (e.g. raced with another delete). Client silently refreshes.
- `409 Conflict` `{ "error": "<stderr>", "forceAllowed": true, "shortStatus": "..." }` — git failed in a way `--force` could fix. Drives the mobile Force Delete dialog. `shortStatus` is always present when `forceAllowed: true`; it is the trimmed output of `git status --short` captured at the failure point, same source the Mac's `ForceDeleteAlert.informativeText` reads.
- `409 Conflict` `{ "error": "<stderr>", "forceAllowed": false }` — git failed and force already attempted, OR the failure is a class force can't fix. Client shows a non-retry error.
- `500 Internal Server Error` `{ "error": "<msg>" }` — non-git-exit failures (binary missing, subprocess launch failure).
- `503 Service Unavailable` `{ "error": "worktree deletion not available" }` — `worktreeRemover` not injected (matches the create endpoint's pre-injection behavior).

NIO routing: extend the `path == "/worktrees"` branch in `WebServer.HTTPHandler.serveStatic` to also dispatch `/worktrees/delete` to a new `handleDeleteWorktree`. `POST`-only; other methods → 405.

### Mobile UX

`WorktreePickerView` row-level changes:

- Wrap each non-main-checkout, non-`.creating` row in `.swipeActions(edge: .trailing, allowsFullSwipe: false)` with one destructive button labeled "Delete" or "Dismiss" based on `worktree.state == .stale`.
- Tap → SwiftUI `.confirmationDialog` titled "Delete Worktree?" or "Dismiss Worktree?" with body text matching the Mac's NSAlert copy.
- On 409 `forceAllowed: true` response, present a second `.confirmationDialog` with "Force Delete" button and the `shortStatus` as the dialog message.
- On 200, re-fetch via the existing `refresh()` path. No optimistic removal — the next refresh authoritatively reconciles, which keeps the picker honest if a competing delete or prune ran.
- On 4xx/5xx non-409 errors, surface a transient error toast at the bottom of the list — do NOT replace the whole view with `LoadState.error`, since the list is still valid. Re-uses the existing `AttentionCapsule` styling for visual consistency. Auto-dismiss after ~4s; reuse `Color.red` background.

### Repo-ordering fix

Replace `WorktreePickerView.grouped` with a first-occurrence-preserving grouper. The wire already carries the user's sidebar order. ~10 LOC change.

```swift
private func grouped(_ list: [WorktreePanes]) -> [(String, [WorktreePanes])] {
    var order: [String] = []
    var groups: [String: [WorktreePanes]] = [:]
    for wt in list {
        if groups[wt.repoDisplayName] == nil { order.append(wt.repoDisplayName) }
        groups[wt.repoDisplayName, default: []].append(wt)
    }
    return order.map { ($0, groups[$0] ?? []) }
}
```

## Specs (EARS) to add

All under their existing prefix families. The IOS-4.x family is full through IOS-4.19 and WEB-7.x through WEB-7.7, so we extend both forward.

- **IOS-9.6** — When the user swipes a non-main-checkout, non-creating worktree row in `WorktreePickerView`, the application shall reveal a trailing destructive action labeled "Delete" or "Dismiss" depending on whether the worktree state is `.stale`.
- **IOS-9.7** — When the user taps the trailing destructive action, the application shall present a confirmation dialog with copy matching the Mac sidebar's delete-or-dismiss alert and shall not issue any HTTP call until the user confirms.
- **IOS-9.8** — If `POST /worktrees/delete` returns 409 with `forceAllowed: true`, then the application shall present a Force Delete confirmation surfacing the `shortStatus` field as the dialog body, and retry the request with `force: true` only on user confirmation.
- **IOS-9.9** — While rendering grouped worktrees in `WorktreePickerView`, the application shall preserve the wire order of `repoDisplayName` first-occurrences rather than sort alphabetically, so mobile groups follow the user's Mac sidebar ordering.
- **WEB-7.8** — When `POST /worktrees/delete` arrives with a valid `worktreePath`, the application shall route it through `DeleteWorktreeFlow.delete` and respond `200 { dismissed: Bool }` on success — `dismissed: true` when the prune-on-vanished path ran (GIT-3.6 / GIT-4.13) and `dismissed: false` when `git worktree remove` succeeded.
- **WEB-7.9** — If the server-side delete flow encounters a git failure that `--force` could resolve, then the application shall respond `409 Conflict` with `{ "error": "<stderr>", "forceAllowed": true, "shortStatus": "<git status --short>" }`. When `--force` already ran or could not help, `forceAllowed` shall be `false`.
- **WEB-7.10** — If the server's `worktreeRemover` is not injected, then `POST /worktrees/delete` shall respond `503 Service Unavailable` with `{ "error": "worktree deletion not available" }`, matching the create endpoint's pre-injection behavior.

## Tests

Per CLAUDE.md: write each spec first as a `@Test(.disabled("not yet implemented"))` in `Tests/GrafttyTests/Specs/<Prefix>Todo.swift`, promote to a real test, watch it fail (RED), implement (GREEN), regenerate `SPECS.md`.

- **`WebServerDeleteEndpointTests`** (`Tests/GrafttyKitTests/Web/WebServerDeleteEndpointTests.swift`): inject a fake `worktreeRemover` closure and assert each branch's status code and body shape. Covers WEB-7.8, WEB-7.9, WEB-7.10. Uses the same `skipInCI` early-return pattern as `WebServerWorktreeEndpointTests`.
- (No standalone `DeleteWorktreeFlowTests`. `AddWorktreeFlow` has none either; both flows are integration-tested through the endpoint's stubbed-closure seam, matching the existing test layout. The Mac path runs via `swift run` / human verification, the iOS path via the endpoint stub + simulator. Adding a closure-injection seam to the flow only to test it in isolation would be cargo-cult — the closure that wires AppState/TerminalManager/etc. is the same code the test would have to fake.)
- **`WorktreePickerGroupingTests`** (`Tests/GrafttyMobileKitTests/UI/WorktreePickerGroupingTests.swift`): extract `grouped(_:)` as a `static` pure function on a `WorktreePickerGrouping` namespace so the test can call it without instantiating SwiftUI. Asserts first-occurrence ordering. Covers IOS-9.9.
- **`WorktreePickerSwipeActionTests`** (same target): same extraction approach — a pure `static` helper `swipeAction(for: WorktreePanes) -> SwipeAction?` returning `nil` for `.creating` and main checkout, `.delete` for non-stale, `.dismiss` for `.stale`. Covers IOS-9.6. No view-model layer is being added — just hoisting pure functions out of the SwiftUI body.
- **`DeleteWorktreeClientTests`** (`Tests/GrafttyMobileKitTests/Session/DeleteWorktreeClientTests.swift`): URLProtocol-stub tests modeled on `CreateWorktreeClientTests`. Cover 200 success (dismissed true/false), 409 with `forceAllowed: true` including `shortStatus` decoding, 409 with `forceAllowed: false`, 400, 403, 503, transport failure. Covers IOS-9.7 and IOS-9.8 wire decoding.
- iOS UI behavior past the helper (e.g. SwiftUI dialog plumbing) — given the `feedback_macos_swift_test_misses_uikit_guarded_code` memory, we rely on iOS-sim CI for integration. Confidence on the SwiftUI wiring comes from the iOS CI job, not local `swift test`.

## Risks / open questions

- **`appState` write isolation in the flow.** `DeleteWorktreeFlow.delete` writes through a `Binding<AppState>` like `AddWorktreeFlow.add` does. Confirm the binding-as-handle pattern reads cleanly when invoked from the web closure (`GrafttyApp.swift` already does this for create — the pattern is established).
- **PR/MR cleanup on dismiss.** GIT-3.6 dismiss currently clears caches via `finishWorktreeRemoval`. Ensure the dismiss path in the new flow still goes through that finish helper rather than a separate "model-only" shortcut, or we orphan cache entries.
- **Stale label vs `.stale` state.** Some rows may render with a strikethrough but server-side state is `.closed` (e.g. on-disk dir absent but model says closed). We trust `state` from the wire; the strikethrough is a render concern that doesn't change the delete-vs-dismiss decision. Server makes the authoritative call by inspecting `FileManager` after a failed `git worktree remove`.

## Implementation order

1. EARS specs in `*Todo.swift` files (RED inventory).
2. `DeleteWorktreeRequest` / `DeleteWorktreeOutcome` types + `worktreeRemover` plumbing through `WebServer.Config` and `WebServerController`. WEB-7.5.
3. `handleDeleteWorktree` HTTP handler. WEB-7.3 (success), WEB-7.4 (force).
4. `DeleteWorktreeFlow.delete` extracted from `MainWindow`. `MainWindow.performDeleteWorktree` becomes a thin shim.
5. `GrafttyApp.setWorktreeRemover { ... }` wiring.
6. Mobile `DeleteWorktreeClient`.
7. `WorktreePickerView` swipe + confirmation + force-delete chain. IOS-4.11/4.12/4.13.
8. `grouped()` fix. IOS-4.14.
9. Regenerate `SPECS.md`. Run `/simplify`. Open PR.
