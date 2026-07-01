# Explicit Display Ownership Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace implicit shared-session size/input authority with an explicit zero-or-one display owner model, and reserve GrafttyMobile terminal height for visible bottom chrome so the bottom shell row is not hidden.

**Architecture:** Add shared ownership wire types in `GrafttyProtocol`, an authoritative `SessionDisplayOwnershipStore` in `GrafttyKit`, create one process-lifetime store in `AppServices`, then route Mac, web/iOS, previews, and mobile viewport layout through that store. Owner clients can send input and resize. Followers render the authoritative grid, block PTY-bound input/resizes, and can explicitly take control when interactive.

**Tech Stack:** Swift 5.10, Swift Testing, SwiftUI/UIKit, NIO WebSocket, zmx attach, libghostty in-memory and native surfaces.

---

## Prerequisites and Safety Notes

- [ ] Preserve the existing uncommitted `SurfaceHandle` sizing fix unless the owner model deliberately supersedes a touched line. Do not revert these files:
  - `Sources/Graftty/Terminal/SurfaceHandle.swift`
  - `Tests/GrafttyTests/Terminal/SurfaceHandleHostManagedTests.swift`
  - `Tests/GrafttyTests/Terminal/SurfaceHandleTestSupport.swift`
  - `SPECS.md`
- [ ] Before each code task, run `git status --short` and inspect overlapping files.
- [ ] Prefer adding compatibility shims before deleting old concepts. Remove old gates only when tests prove the replacement path.
- [ ] Specs around `IOS-6.5`, `IOS-6.10`, `IOS-12.1`, `TERM-11.x`, `WEB-5.6`, and `RemoteAttachmentRegistry` need semantic rewrites rather than another exception layer.
- [ ] Web client source lives in `web-client/`; do not hand-edit the generated `Sources/GrafttyKit/Web/Resources/app.js`. After web-client changes, run the repo's web build path so `Sources/GrafttyKit/Web/Resources/{index.html,app.js,app.css}` are regenerated.

## Task 1: Protocol and Ownership Store

**Write scope:** `Sources/GrafttyProtocol/WebControlEnvelope.swift`, new protocol files if useful, new `Sources/GrafttyKit/SessionDisplayOwnershipStore.swift`, and tests under `Tests/GrafttyProtocolTests` and `Tests/GrafttyKitTests`.

- [ ] Add shared wire/state types:
  - `DisplayClientID` as a `String`-backed `Sendable`, `Hashable`, `Codable` value.
  - `DisplayClientKind`: `mac`, `web`, `ios`, `preview`.
  - `DisplayClientRole`: `interactive`, `preview`.
  - `DisplayGrid`: positive `UInt16 cols/rows`.
  - `DisplayOwnershipSnapshot`: `sessionName`, optional owner ID/kind, authoritative grid, epoch, and derived ownerless state.
- [ ] Extend `WebControlEnvelope` with text frames:
  - client to server: `hello(clientID, kind, role, visible, cols, rows)`, `takeControl(clientID, kind, cols, rows)`, `ownerResize(clientID, epoch, cols, rows)`, replacing raw `.resize` for owner-aware clients.
  - server to client: `ownership(DisplayOwnershipSnapshot)` in addition to `.grid` during migration.
  - keep parsing legacy `.resize` temporarily so old clients fail soft during rollout.
- [ ] Unit-test protocol encoding/parsing, missing fields, invalid dimensions, legacy resize parsing, and ownership snapshot round-trip.
- [ ] Implement `SessionDisplayOwnershipStore`:
  - keyed by session name;
  - stores zero-or-one owner, last accepted authoritative grid, epoch, and attached client identities;
  - supports `attachClient`, `claimOwner`, `ownerResize`, `detachClient`, `releaseOwner`, and `snapshot`;
  - auto-claims only for a new visible interactive attach while ownerless;
  - preserves last accepted grid when moving ownerless;
  - rejects stale epoch resizes.
- [ ] Unit-test the state machine:
  - first visible interactive attach auto-claims when ownerless;
  - preview attach never owns;
  - existing followers do not auto-claim after owner disconnect;
  - takeover increments epoch and swaps owner;
  - owner resize accepts only matching owner and epoch;
  - stale resize from old epoch is rejected after takeover;
  - owner disconnect makes ownerless and preserves the last grid;
  - never-owned ownerless sessions can snapshot a daemon fallback grid.
- [ ] Verification:
  - `swift test --filter WebControlEnvelopeTests`
  - `swift test --filter SessionDisplayOwnershipStoreTests`
  - `swift test --filter SharedProtocolSurfaceTests`

## Task 2: Web Bridge Ownership Gate

**Write scope:** `Sources/GrafttyKit/Web/WebServer.swift`, `Sources/GrafttyKit/Web/WebSession.swift` only as needed, `Sources/Graftty/Web/WebServerController.swift`, `Sources/Graftty/GrafttyApp.swift` for store injection only, and web tests under `Tests/GrafttyKitTests/Web` / `Tests/GrafttyTests/Web` as needed.

- [ ] Add store injection:
  - `WebServer.Config` accepts a `SessionDisplayOwnershipStore`;
  - `WebServerController` has `setDisplayOwnershipStore(_:)`;
  - production does not create a private default store when a process-wide store is available.
- [ ] Give each `WebSocketBridgeHandler` a per-connection `DisplayClientID`.
- [ ] On WebSocket attach:
  - call `attachClient` with kind `.web` for browser web or `.ios` if the request/client declares iOS;
  - use the initial grid from `hello` when present;
  - broadcast the returned ownership snapshot to the client.
- [ ] Replace direct handling of `.resize`:
  - owner-aware `.ownerResize` calls `ownerResize`; accepted resizes call `WebSession.resize`;
  - legacy `.resize` is accepted only for ownerless/new-owner compatibility and should claim or resize through the store, not bypass it;
  - rejected follower/stale resizes do not call `WebSession.resize`.
- [ ] Gate binary frames:
  - owner writes call `WebSession.write`;
  - follower writes are ignored and should not record input state.
- [ ] On PTY size poll:
  - update/broadcast authoritative grid only when the size corresponds to accepted owner state;
  - continue sending `.grid` for compatibility, but also send `.ownership`.
- [ ] On channel inactive/close:
  - detach the client identity;
  - if it was owner, store becomes ownerless and preserves grid;
  - broadcast ownerless snapshot to remaining same-session clients if there is an existing broadcast registry, or add a minimal same-process broadcaster.
- [ ] Tests:
  - owner WebSocket resize reaches `WebSession.resize`;
  - follower resize is rejected;
  - owner binary input reaches `WebSession.write`;
  - follower binary input is ignored;
  - takeover immediately resizes PTY to the new owner grid;
  - owner disconnect emits ownerless snapshot and does not auto-promote another client.
- [ ] Verification:
  - `swift test --filter WebControlEnvelopeTests`
  - `swift test --filter WebSessionTests`
  - `swift test --filter WebServerAuthTests`
  - `swift test --filter WebServerIntegrationTests`

## Task 3: Process-Wide Store Assembly

**Write scope:** `Sources/Graftty/GrafttyApp.swift`, `Sources/Graftty/Terminal/TerminalManager.swift`, `Sources/Graftty/Web/WebServerController.swift`, and assembly tests under `Tests/GrafttyTests`.

- [ ] Add `let displayOwnershipStore: SessionDisplayOwnershipStore` to `AppServices`, constructed once for the app lifetime.
- [ ] Wire the same store into:
  - `terminalManager.displayOwnershipStore`;
  - `webController.setDisplayOwnershipStore(services.displayOwnershipStore)`;
  - any SSH/WebRTC mobile bridge path that creates `/ws`-equivalent terminal streams.
- [ ] Keep `RemoteAttachmentRegistry` only as connection accounting while this migration is in progress; it must not decide size/input authority.
- [ ] Add tests proving shared store identity/behavior:
  - a Mac-side claim is visible to web bridge ownership checks;
  - a web/iOS takeover is visible to Mac backend ownership checks;
  - two separately constructed test controllers can still use injected isolated stores without touching process global state.
- [ ] Verification:
  - `swift test --filter GrafttyApp`
  - `swift test --filter TerminalManagerMetadataTests`
  - `swift test --filter WebServer`

## Task 4: Mac Native Ownership Gate

**Write scope:** `Sources/Graftty/Terminal/HostManagedZmxBackend.swift`, `Sources/Graftty/Terminal/TerminalManager.swift`, related Mac UI files under `Sources/Graftty/Views`, and tests under `Tests/GrafttyTests/Terminal`.

- [ ] Thread a stable per-attachment `DisplayClientID` through `TerminalManager` into each `HostManagedZmxBackend`.
- [ ] Inject ownership operations into `HostManagedZmxBackend` through testable closures or a small protocol:
  - current snapshot;
  - attach/claim;
  - owner resize;
  - detach/release;
  - write permission.
- [ ] Replace resize authority checks:
  - remove `RemoteAttachmentRegistry.isRemoteAttached` as a resize gate;
  - remove hidden ownership from `AttachState.silent`, first user input, and show-time takeback;
  - keep layout-settle protection against bogus pre-layout grid callbacks.
- [ ] Owner behavior:
  - forwards viewport callbacks through `ownerResize`;
  - forwards user input;
  - `setVisible(true)` may refresh presentation and re-read grid, but must not resize unless still owner.
- [ ] Follower behavior:
  - suppresses PTY resize;
  - blocks PTY-bound input;
  - renders current authoritative grid without stealing ownership.
- [ ] Add a Mac **Take Control** path:
  - visible follower can explicitly claim with current natural grid;
  - takeover immediately resizes zmx PTY through accepted owner path.
- [ ] Tests:
  - Mac owner forwards resize/input;
  - Mac follower suppresses resize/input;
  - first visible interactive Mac attach auto-claims only when ownerless;
  - show-time reconcile does not steal ownership;
  - takeover swaps owner, increments epoch, and sends new grid;
  - stale pending resize from old owner is rejected after takeover.
- [ ] Verification:
  - `swift test --filter HostManagedZmxBackendTests`
  - `swift test --filter SurfaceHandleHostManagedTests`
  - `swift test --filter TerminalManager`

## Task 5: Web Client Ownership UI

**Write scope:** `web-client/src/components/TerminalPane.tsx`, related `web-client/src` files, `web-client/src/styles.css`, `web-client/src/components/TerminalPane.test.tsx`, and regenerated `Sources/GrafttyKit/Web/Resources/{index.html,app.js,app.css}`.

- [ ] Add client-side ownership protocol helpers matching `WebControlEnvelope`:
  - generate a fresh browser `clientID` per WebSocket connection;
  - send `hello` on open with kind `.web`, role `.interactive`, visibility, and current terminal grid when available;
  - send `ownerResize` instead of raw `resize` when owner;
  - send `takeControl` only from explicit UI.
- [ ] Track ownership snapshots:
  - `isOwner`;
  - follower/ownerless state;
  - authoritative grid/epoch.
- [ ] Gate browser terminal behavior locally:
  - owner `onData` sends binary input;
  - follower `onData` is ignored locally;
  - owner resize sends `ownerResize`;
  - follower resize changes only presentation fit.
- [ ] Add visible **Take Control** UI for follower/ownerless browser sessions.
- [ ] Preserve existing web behavior:
  - mobile visual viewport resizing still keeps the terminal above browser keyboard;
  - scrollback pinning still works;
  - root/session routing remains unchanged.
- [ ] Tests:
  - sends `hello` on WebSocket open;
  - owner resize sends `ownerResize`;
  - follower resize does not send owner resize;
  - follower data input is blocked;
  - Take Control button sends `takeControl` with current grid;
  - ownership snapshot toggles UI and input behavior.
- [ ] Build bundled resources:
  - `cd web-client && pnpm test`
  - `cd web-client && pnpm build`
  - verify generated `Sources/GrafttyKit/Web/Resources/app.js` is updated by the build, not manual editing.

## Task 6: GrafttyMobile Ownership UI and Client Semantics

**Write scope:** `Sources/GrafttyMobileKit/Session/SessionClient.swift`, `Sources/GrafttyMobileKit/Session/WebSocketClient.swift`, `Sources/GrafttyMobileKit/App/RootView.swift`, `Sources/GrafttyMobileKit/Terminal/TerminalPaneView.swift`, and mobile tests.

- [ ] Replace `isSizeLeader` with explicit ownership state:
  - `ownershipSnapshot`;
  - `isOwner`;
  - `isFollower`;
  - `isOwnerless`;
  - authoritative grid derived from ownership snapshot, falling back to `.grid`.
- [ ] On WebSocket open, send `hello` with a fresh per-connection `DisplayClientID`, role, visibility, and current viewport if available.
- [ ] Stop implicit claims:
  - typing, paste, control-bar buttons, long-press, and pinch must not claim ownership;
  - follower input attempts should be blocked locally, with a visible **Take Control** affordance.
- [ ] Add explicit `takeControl()`:
  - uses last viewport grid;
  - sends `takeControl`;
  - after ownership snapshot confirms ownership, layout-driven resizes use `ownerResize`.
- [ ] Keep width-primary follower fit:
  - compute font override from authoritative cols and container width;
  - stop horizontal-grid feedback while follower/ownerless;
  - when owner, preserve existing user-adjustable font behavior.
- [ ] Update `TerminalPaneView` gesture hooks:
  - remove leadership-claim callbacks;
  - keep long-press menu and pinch behavior only for local selection/zoom unless owner.
- [ ] Tests:
  - follower keystrokes/control-bar actions do not send binary frames;
  - follower long-press/pinch does not send resize/takeover;
  - explicit `takeControl()` sends takeover with last viewport;
  - owner resize sends `ownerResize` with current epoch;
  - ownership text frames update `isOwner` and authoritative grid;
  - preview role never owns and never shows takeover.
- [ ] Verification:
  - `swift test --filter SessionClientTests`
  - `swift test --filter TerminalPaneViewTests`
  - `swift test --filter TerminalWidthLayoutTests`
  - `swift test --filter PanePreviewFontSizingTests`

## Task 7: Mobile Terminal Chrome Height Reservation

**Write scope:** `Sources/GrafttyMobileKit/App/RootView.swift`, helper types under `Sources/GrafttyMobileKit/App` if useful, and tests under `Tests/GrafttyMobileKitTests/App`.

- [ ] Add a measured bottom-chrome height helper using a SwiftUI preference key or equivalent measurement.
- [ ] Reserve bottom chrome from terminal content:
  - `terminalViewportHeight = max(1, containerSize.height - measuredChromeHeight)`;
  - pass this reduced content size to `activeTerminal` and font/grid decisions;
  - keep overlay placement visually unchanged.
- [ ] Measure both bottom chrome cases:
  - full software-keyboard control bar;
  - compact show-keyboard affordance.
- [ ] Ensure owner grid calculations and follower vertical fit use the reduced terminal content height.
- [ ] Tests:
  - pure helper calculates reduced terminal viewport height;
  - full control bar height is subtracted;
  - compact keyboard button height is subtracted;
  - zero/unknown chrome height falls back to full container height;
  - reduced viewport is used in the font-fit task key so resizing happens immediately when chrome appears/disappears.
- [ ] Verification:
  - `swift test --filter KeyboardFrameInsetTests`
  - `swift test --filter RootView`
  - `swift test --filter SessionClientTests`

## Task 8: Preview and Specs Cleanup

**Write scope:** `Sources/GrafttyMobileKit/UI/PaneLayoutView.swift`, `Sources/GrafttyMobileKit/UI/PanePreviewClientPool.swift`, preview sizing tests, `SPECS.md`, `Tests/GrafttyTests/Specs`, `Tests/GrafttyMobileKitTests/Specs` if present.

- [ ] Make previews explicit followers:
  - never send `hello` as interactive;
  - never send input/resize/takeover;
  - render authoritative grid through width-fit sizing.
- [ ] Rewrite affected specs to describe explicit ownership instead of implicit leadership.
- [ ] Run `scripts/generate-specs.py` and include the generated `SPECS.md` changes.
- [ ] Tests:
  - preview client role is `.preview`;
  - preview cannot auto-claim;
  - preview font sizing uses authoritative cols.
- [ ] Verification:
  - `swift test --filter PanePreview`
  - `scripts/generate-specs.py --check`

## Task 9: Integration Verification

**Write scope:** no production code unless fixing review findings.

- [ ] Run focused suites from all previous tasks.
- [ ] Run broader safety checks:
  - `swift test --filter HostManagedZmxBackendTests`
  - `swift test --filter SurfaceHandleHostManagedTests`
  - `swift test --filter SessionClientTests`
  - `swift test --filter WebControlEnvelopeTests`
  - `swift test --filter SessionDisplayOwnershipStoreTests`
  - `swift test --filter TerminalWidthLayoutTests`
  - `swift test --filter PanePreview`
  - `cd web-client && pnpm test`
  - `cd web-client && pnpm build`
  - `scripts/generate-specs.py --check`
  - `git diff --check`
- [ ] Manual verification matrix:
  - Mac owns, iOS follows: iOS width-fits Mac grid and cannot type.
  - iOS takes control: PTY immediately resizes to iOS terminal content area; Mac becomes follower.
  - Keyboard opens on iOS while iOS owns: bottom shell row remains visible above the control bar.
  - Mac takes control back: iOS becomes follower and stops sending input/resize.
  - Existing follower remains read-only when owner disconnects; no silent auto-promotion occurs.
