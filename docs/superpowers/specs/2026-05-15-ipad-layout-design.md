# iPad Layout — Design Specification

**Status:** Draft, awaiting user review.
**Authors:** Ben Tucker, with Claude.
**Date:** 2026-05-15.

GrafttyMobile gains an iPad-class layout: a worktree sidebar plus a multi-pane detail column that renders the full `SplitTree` with live, simultaneous terminals. Pane lifecycle ops (split, close, swap) are initiated from iPad. The work bundles WebRTC Phase 2 transport adoption so the iPad layout lands on the long-term transport rather than the soon-to-be-retired `/ws` WebSocket bridge.

## 1. Goal

After this ships, this user story works:

> I open GrafttyMobile on my iPad in landscape and pick a paired host from the header. The sidebar shows my repos, worktrees, and per-pane rows — the same shape as my Mac sidebar. I tap a multi-pane worktree and the detail column renders both panes side-by-side, each with its own live terminal. I tap the right pane to focus it, tap "Split Down" in the focused-pane toolbar, and a third pane spawns. My Mac, watching the same worktree, sees the new pane appear in its sidebar within a second — without yanking the Mac user's focus. I background the app to answer a notification; on foreground, Face ID re-prompts; every terminal reconnects under a fresh authenticated handshake.

## 2. Core promise

**Worktree sidebar with desktop parity.** The iPad sidebar mirrors the desktop sidebar's information density — PR badges, attention pills, divergence gutter, swipe-to-delete — by reusing `WorktreePickerView`'s row components inside a `NavigationSplitView` column.

**Multi-pane detail with desktop parity.** The detail column renders `PaneLayoutNode` recursively: leaves as live `TerminalPaneView`s, splits as `HStack`/`VStack` with a draggable divider, ratios honored from the wire model.

**Read-write pane lifecycle.** iPad initiates `split` / `close` / `swap` via the new `pane_control` channel. Server is sovereign over the splittree shape; iPad mutations show up on every connected client.

**Live model updates without polling.** The new `panes_state` channel pushes `[WorktreePanes]` snapshots on every server-side change. The sidebar and detail re-render from one observable store.

**WebRTC transport throughout.** All live data — terminal I/O, model push, lifecycle RPCs — flows over a single per-host WebRTC DataChannel, multiplexed by channel-id per the [WebRTC secure remote access design](../../../../graftty-server/docs/superpowers/specs/2026-05-15-graftty-webrtc-secure-remote-access-design.md). No new long-lived sockets per pane.

## 3. Scope

### In scope

- **`NavigationSplitView` 2-column iPad layout** with a tappable host header at the top of the sidebar that opens a host-switcher popover.
- **Worktree sidebar** reusing `WorktreePickerView`'s row, refresh, and swipe-action infrastructure inside the sidebar column.
- **`MultiPaneDetailView`** rendering `PaneLayoutNode` recursively with per-leaf `TerminalPaneView`s and draggable split dividers.
- **Focused-pane toolbar** overlay on the focused leaf with Split Right / Split Down / Swap / Close icons; hands off to a new pane on tap.
- **Pane lifecycle ops** (`split`, `close`, `swap`) via the new `pane_control` channel.
- **Live model push** via the new `panes_state` channel; one subscription per opened host.
- **WebRTC Phase 2 adoption** for the mobile client: peer connection, Noise handshake, channel multiplexing, retiring `WebSocketClient`.
- **MobileSurfaceBudget LRU** capping concurrent open `terminal` channels at 8 on iPad; evicted leaves render `IdleSnapshotView` placeholders.
- **Compact-width fallback** — same code path on iPhone and iPad-narrow-Split-View. `NavigationSplitView` auto-collapses to a push-nav stack; `MultiPaneDetailView` falls back to focused-leaf-only.
- **Background/foreground full re-establish** — peer connection torn down on background; fresh Noise handshake on foreground per the WebRTC design's invariants.

### Out of scope (for this body of work)

- **Per-pane control commands beyond split/close/swap.** Pane move-to-another-worktree, pane configuration, OSC 52 clipboard reads, Kitty graphics — out.
- **Cloud-routed signaling.** Phase 4 of the WebRTC design. iPad uses Direct/Tailscale signaling only.
- **Push notifications.** `IOS-8.5` stands.
- **Web client iPad parity.** The web client is being deprecated per the WebRTC design §12.
- **Optimistic UI for lifecycle ops.** All mutations round-trip through the server; the snapshot push is the source of truth.
- **Cross-client focus sync.** Per-client focus state; iPad focus does not move Mac focus, mirroring `WEB-7.5`.
- **Pane resize sync across clients.** Pane divider ratios are per-client UI state in v1. (Open question §13.)

## 4. Architecture

```
GrafttyMobile (iPad)                    Graftty.app (Mac)             zmx daemon
  │                                          │                            │
  │── HTTPS signaling (Direct/Tailscale) ───►│                            │
  │     SDP offer → answer, ICE              │                            │
  │                                          │                            │
  │═══════ WebRTC DataChannel ══════════════│                            │
  │   (one per host, app-layer E2EE)         │                            │
  │                                          │                            │
  │── channel.open type=panes_state ────────►│                            │
  │◄── snapshot([WorktreePanes]) ────────────│                            │
  │◄── snapshot([WorktreePanes]) (on change)─│                            │
  │                                          │                            │
  │── channel.open type=terminal ───────────►│ ── spawn zmx attach <s>──►│
  │   target=<sessionName>                   │                            │
  │◄══ PTY bytes ════════════════════════════│                            │
  │══ PTY bytes ════════════════════════════►│                            │
  │                                          │                            │
  │── channel.open type=pane_control ───────►│                            │
  │   request={type:"split", target, dir}    │                            │
  │◄── response={ok:true} ───────────────────│                            │
  │  (then panes_state push delivers new shape)                           │
```

### 4.1 Client side

```
GrafttyMobileApp
└── RootView                                   (size-class router — IPAD-1.1)
    ├── (compact) → existing NavigationStack flow (unchanged for iPhone)
    └── (regular) → IPadRootLayout              (new)
        ├── HostHeaderRow                       (sidebar header — IPAD-1.2)
        │     └── HostSwitcherPopover           (tap target)
        └── NavigationSplitView
            ├── Sidebar
            │   └── WorktreeListContent         (extracted from WorktreePickerView)
            └── Detail
                ├── BreadcrumbBar               (host · repo · worktree · branch · PR)
                └── MultiPaneDetailView         (recursive over PaneLayoutNode — IPAD-2.x)
                    ├── PaneLeafView           (one per leaf)
                    │   ├── TerminalPaneView   (existing)
                    │   ├── FocusRing          (when focused)
                    │   └── FocusedPaneToolbar (overlay, focused-only — IPAD-3.x)
                    └── PaneSplitView          (HStack/VStack + draggable Divider)

RemoteHostConnection (actor, one per opened host)
├── PeerConnection                              (RTCPeerConnection, WebRTC Phase 2)
├── DataChannel                                 (single, multiplexed)
├── NoiseTransport                              (fresh per connect, ICE restart, recreate)
└── ChannelRouter
    ├── PanesStateClient → WorktreePanesStore  (one subscription per host)
    ├── PaneControlClient                      (RPC API: split/close/swap)
    └── TerminalChannelPool                    (one channel per visible leaf, LRU-budgeted)

IPadAppState (@Observable)
├── selectedHostId: HostID?
├── selectedWorktreePath: String?
└── focusedPaneId: String?                      (zmx sessionName; per-iPad-client)

MobileSurfaceBudget                              (IPAD-4.x — caps open terminal channels)
```

### 4.2 Server side (Graftty.app additions)

```
WebRTCHostAgent (Phase 2)
└── ChannelRouter
    ├── terminal channel handler → existing TerminalManager / zmx attach
    ├── panes_state channel handler → subscribes to WorktreeMonitor + emits snapshots (NEW)
    └── pane_control channel handler → invokes AppState splittree mutations (NEW)
```

### 4.3 State flow

1. User selects a host from the header. `RemoteHostConnection` is built for that host; signaling round-trip, ICE, Noise — all per the WebRTC design §7.
2. `RemoteHostConnection` open: `WorktreePanesStore` opens its `panes_state` channel, receives the initial snapshot, publishes.
3. `IPadRootLayout` renders sidebar (from `WorktreePanesStore`) and detail (from selected worktree's `PaneLayoutNode`).
4. User selects a worktree → `MultiPaneDetailView` walks the leaves and opens one `terminal` channel per leaf (subject to LRU budget).
5. User taps a focused-pane toolbar button → `PaneControlClient.split(target:direction:)` sends an RPC frame → server returns `{ok:true}` → server-side splittree mutation fans out a new `panes_state` snapshot → store updates → views re-render.

## 5. UI design

### 5.1 Sidebar

- **Host header (IPAD-1.2):** label of the selected host with a small chevron. Tap → presents a popover (iPad) / sheet (compact) listing all paired hosts with the same row content as today's `HostPickerView`. Selecting a different host triggers a clean host switch (close current `RemoteHostConnection`, build new one for the picked host).
- **Worktree list (IPAD-1.3):** the entire `WorktreePickerView` body — `WorktreePickerGrouping`, swipe actions, PR badges, attention pills, divergence gutter — extracted into a `WorktreeListContent` view, lifted out of view-local state, and bound to `WorktreePanesStore` instead of fetching on appear.
- **Pane child rows (IPAD-1.4):** in iPad regular width, tapping a pane child row sets `IPadAppState.focusedPaneId` to that leaf's `sessionName` (no navigation push). The sidebar row gets a subtle highlight matching the detail's focus ring. The compact-width path keeps `IOS-4.21` behavior (push to fullscreen).

### 5.2 Detail column

- **BreadcrumbBar (IPAD-2.1):** simpler than desktop's. Renders `host · repo · worktree · branch` + PR badge. PR refresh action (tap PR badge → opens PR URL). No-worktree-selected state → `ContentUnavailableView("Select a worktree from the sidebar")`.
- **`MultiPaneDetailView` (IPAD-2.x):** recursive renderer over `PaneLayoutNode`. Splits with `ratio: Double` produce an `HStack` or `VStack` (per `SplitAxis`) with the two children proportionally sized and a `Divider` between them. Dragging the divider mutates a local override map keyed by the tree path to that split (a `[Int]` of "go-left / go-right" steps from the root); v1 stores these per-iPad-client only (see §12 Open Question #1).
- **`PaneLeafView` (IPAD-2.4):** owns:
  - The `terminal` channel for its leaf via `TerminalChannelPool`.
  - A `TerminalController` shared across leaves of the same host.
  - A focus ring (`outline: 2pt accent, opacity 0.5`) when `IPadAppState.focusedPaneId == self.sessionName`.
  - The `FocusedPaneToolbar` overlay (focused-only).
- **Per-leaf width policy (IPAD-2.5):** `TerminalWidthLayout.decide` runs per-leaf with the leaf's allotted frame. If `serverCols × cellWidth > frameWidth`, the leaf wraps in a horizontal `ScrollView` — same logic as today's `SingleSessionView`, applied per pane.

### 5.3 Focused-pane toolbar (IPAD-3.x)

Overlay on the focused leaf, bottom-right or top-right (TBD during M7 — likely top-right to avoid the soft-keyboard hand zone). Icons (SF Symbols):

| Action | Icon | RPC |
|---|---|---|
| Split right | `rectangle.split.2x1` | `pane_control: split direction=horizontal` |
| Split down | `rectangle.split.1x2` | `pane_control: split direction=vertical` |
| Swap | `rectangle.2.swap` | `pane_control: swap` (with neighbor — TBD which side) |
| Close | `xmark.rectangle` | `pane_control: close` |

Tapping a different leaf hands off the toolbar. The currently-focused leaf is the implicit `target` of every RPC. The toolbar is hidden when the soft keyboard is up (the terminal control bar takes its place).

### 5.4 Host switching (IPAD-6.x)

- Selecting a different host closes the current `RemoteHostConnection` and builds a new one. All open `terminal` channels close; the sidebar repopulates from the new host's first `panes_state` snapshot.
- During the connection-establish window (signaling + Noise, typically <500ms on LAN), the sidebar shows the new host's label with a small spinner; the detail shows `ContentUnavailableView`.

### 5.5 Compact-width fallback (IPAD-7.x)

When `horizontalSizeClass == .compact`:
- `RootView` renders today's `NavigationStack` flow unchanged (iPhone gets exactly what it has today, just via the new transport).
- iPad in narrow Split View / Slide Over inherits the compact path — single-pane fullscreen terminal, push-nav for sidebar.
- Transition between regular and compact (e.g., user resizes Split View) preserves `selectedWorktreePath` and `focusedPaneId` so the user lands on the same leaf in whichever shape.

## 6. WebRTC channel lifecycle

### 6.1 Per-host `RemoteHostConnection`

Built when the user selects a host. Owns the WebRTC peer connection, the single DataChannel, and the Noise transport state. Single source of truth for "is this host reachable right now."

- **Connect lifecycle:** signaling → ICE → DataChannel open → Noise handshake → first channel open. Failures at any step surface as a sidebar banner; the user can retry from the host header.
- **Reconnect:** ICE restart and DataChannel recreation both **require fresh Noise** per the WebRTC design §4 invariants. No resume token in v1.
- **Teardown:** host switch, app background, or user logout closes the DataChannel, closes the peer connection, drops the Noise transport. Foreground builds a new one from scratch.

### 6.2 `terminal` channels

One per visible leaf, scoped to `RemoteHostConnection`, multiplexed on the shared DataChannel. Frame payload: raw PTY bytes (binary frames). Control envelopes (resize): JSON frames keyed by channel-id.

`TerminalChannelPool` is the per-connection multiplexer. Closing a leaf's `PaneLeafView` closes its channel; opening or refocusing opens (or re-opens) one.

### 6.3 `panes_state` channel (REMOTE-6.x)

Subscription channel. Opened by `RemoteHostConnection` immediately after Noise completes. Server pushes:

```json
{"type": "snapshot", "worktrees": [/* WorktreePanes... */]}
```

— on connect and on every change to the shared splittree, attention state, or PR status. Client `WorktreePanesStore` replaces its `[WorktreePanes]` array on each snapshot. SwiftUI re-diffs the sidebar and detail automatically.

No delta protocol in v1. Snapshots are a few KB; the simplicity is worth the cost.

### 6.4 `pane_control` channel (REMOTE-7.x)

RPC channel. Opened lazily by `PaneControlClient` on first lifecycle action. Frames:

```json
// request:
{"type": "split", "target": "<sessionName>", "direction": "horizontal"|"vertical"}
{"type": "close", "target": "<sessionName>"}
{"type": "swap",  "source": "<sessionName>", "target": "<sessionName>"}

// response:
{"ok": true}
{"ok": false, "error": "<message>", "code": "<rfc7807-ish slug>"}
```

The response confirms server-side acceptance. The *effect* — splittree shape change — arrives via the next `panes_state` snapshot. Client treats `panes_state` as the source of truth, not the `pane_control` response.

Capability gate: `terminal_control` (default-granted on pairing per the WebRTC design §9). A revoked peer's open `pane_control` channels close immediately. This spec deliberately does *not* introduce a separate `pane_lifecycle` capability — `terminal_control` already gates the higher-blast-radius "send keystrokes to a PTY" verb, and granting it without lifecycle access is not a coherent product state.

### 6.5 Server-side concurrency (REMOTE-7.4)

Concurrent `pane_control` requests against the same target leaf serialize on the server. A second request for the same target before the first's snapshot push lands returns `409 Conflict`. Client suppresses 409 toasts silently — the snapshot tells the user what actually happened.

### 6.6 MobileSurfaceBudget (IPAD-4.x)

Mirroring desktop's `MEM-1.x` LRU but for terminal *channels* on iPad: cap concurrent open `terminal` channels at **8 leaves**. Beyond cap → evict by least-recently-focused; channel closes; leaf renders `IdleSnapshotView` from the last frame the channel held. Tapping a snapshot re-opens a fresh `terminal` channel for that leaf.

## 7. Spec ID plan

### 7.1 New families

- **`IPAD-1.x`** — Root layout, size-class router, host header, sidebar contents.
- **`IPAD-2.x`** — `MultiPaneDetailView`, recursive split rendering, per-leaf width policy, focus ring.
- **`IPAD-3.x`** — Focused-pane toolbar, lifecycle RPC invocation, soft-keyboard interaction.
- **`IPAD-4.x`** — `MobileSurfaceBudget` LRU on terminal channels.
- **`IPAD-5.x`** — Background/foreground lifecycle, Noise re-establish requirements.
- **`IPAD-6.x`** — Host switching, RemoteHostConnection teardown semantics.
- **`IPAD-7.x`** — Compact-width fallback within the iPad layout.
- **`REMOTE-6.x`** — `panes_state` channel protocol, subscription semantics, snapshot encoding.
- **`REMOTE-7.x`** — `pane_control` channel protocol, RPC frames, capability requirement, server-side serialization, Mac focus sovereignty.

### 7.2 Amendments

- **`IOS-5.x`** — Reframe as compact-width-only. New `IPAD-2.x` covers iPad regular-width multi-pane.
- **`IOS-7.x`** — Extend with Noise re-establish on foreground. Add language: "When the application foregrounds and the biometric gate is satisfied, the application shall rebuild the `RemoteHostConnection` from signaling onward, completing a fresh Noise handshake per REMOTE-2.1, before re-opening any `terminal` channel."
- **`IOS-4.x`** — Soften to "during the WebRTC connection-establish window" for the cold-load HTTPS metadata path; `panes_state` is authoritative once subscribed.

### 7.3 Superseded

- Any rule referencing `/ws` or `WebSocketClient` for terminal attach — replaced by `terminal` channel references. Actual deletion of `WebSocketClient` lands in M2 with WebRTC Phase 2 adoption.
- **`IOS-8.3`** — Removed. The non-goal ("shall not initiate pane lifecycle operations") is fundamentally inverted by this work; the positive behavior is fully expressed by `IPAD-3.3` / `IPAD-3.4` / `IPAD-3.5` (toolbar → `pane_control` RPC) and `REMOTE-7.1` (capability gate). No replacement IOS-* spec is added.

## 8. Implementation milestones

The bundle is a serial 9-PR sequence. Each milestone is independently shippable (behind the existing iPhone path until M5 lights up iPad UI). M5–M9 spec text can be drafted during M1–M4.

| # | Title | Scope | Spec families |
|---|---|---|---|
| M1 | WebRTC Phase 2 foundation | Peer connection, signaling endpoint, ICE, Noise handshake, channel framing layer. No channels wired. | REMOTE-2.x |
| M2 | `terminal` channel + retire `/ws` | Move existing `SessionClient` onto a `terminal` channel; delete `WebSocketClient`. iPhone fullscreen pane keeps working through the new transport. | REMOTE-5.x, IOS-4.x amend |
| M3 | `panes_state` channel | Subscription channel, server pushes snapshots, `WorktreePanesStore` decodes. Sidebar refresh becomes live without iPad UI changes yet. | REMOTE-6.x |
| M4 | `pane_control` channel | RPC frames, server handlers, capability gate. No UI surfaces yet. | REMOTE-7.x |
| M5 | `RootView` size-class router + iPad sidebar | `NavigationSplitView`, host header, extracted `WorktreeListContent`. Detail still single-pane. | IPAD-1.x, IPAD-6.x |
| M6 | `MultiPaneDetailView` read-only | Recursive splittree render, per-leaf width policy, focus ring. No lifecycle UI yet. | IPAD-2.x |
| M7 | Focused-pane toolbar + lifecycle UI | Toolbar overlay, split/close/swap gestures wired to `PaneControlClient`. Drag-divider resize. | IPAD-3.x |
| M8 | `MobileSurfaceBudget` LRU on channels | 8-leaf cap, evict to `IdleSnapshotView`, tap to re-attach. | IPAD-4.x |
| M9 | Background/foreground + compact-width regression sweep | Full Noise re-establish on foreground; compact-width fallback verified. | IPAD-5.x, IPAD-7.x |

Each milestone follows the project's RED→GREEN TDD process (CLAUDE.md): disabled `@Test` entries land in `*Todo.swift` ahead of the milestone, promote to active tests, implement, regenerate `SPECS.md`, `/simplify`, open PR.

## 9. Testing strategy

### 9.1 Spec tests

Every `IPAD-*`, `REMOTE-6.*`, `REMOTE-7.*` ID gets a behavioral `@Test` in `Tests/`. Disabled inventory entries land first in `Tests/GrafttyTests/Specs/IpadTodo.swift` and `Tests/GrafttyTests/Specs/RemoteTodo.swift`.

### 9.2 Security regression tests

Lifted from the WebRTC design §15. For every reconnect path — ICE restart, DataChannel recreation, app foreground, host wake — there is a test that:

- An unpaired client cannot open `pane_control`.
- A revoked peer's existing `pane_control` channel closes within one tick of revocation.
- A `pane_control` RPC sent before Noise completes is dropped.
- A modified SDP transcript hash fails attach verification.
- `panes_state` snapshots before Noise completion are not emitted.

No mocking of WebRTC primitives in security tests — real `RTCPeerConnection` pairs on loopback so the Noise/transcript binding is exercised end-to-end.

### 9.3 Cross-repo contract tests

New tests in `Tests/GrafttyProtocolTests/`:

- `panes_state` snapshot encoding round-trip.
- `pane_control` request / response encoding round-trip.
- Channel-open / close / error frame encoding round-trip.

These run in both `graftty` and `GrafttyMobile` test targets via the shared `GrafttyProtocol` module.

### 9.4 iPad UI tests

With a faked `RemoteHostConnection` injecting canned `panes_state` snapshots:

- Sidebar render: every `WorktreePickerGrouping` invariant continues to hold (group order, swipe actions, PR badges, attention pills).
- Sidebar pane-row tap → `IPadAppState.focusedPaneId` change → detail focus ring moves.
- Splittree render: every `PaneLayoutNode` shape renders the right `HStack`/`VStack`/`Divider` structure.
- Focused-pane toolbar visibility: appears on focused leaf only, hides on soft-keyboard show.
- Host-switch tear-down: every open `terminal` channel closes; sidebar repopulates.

### 9.5 macOS `swift test` is insufficient

Per the user-memory `feedback_macos_swift_test_misses_uikit_guarded_code`: `swift test` on Mac false-greens iPad UIKit-guarded code. iOS CI is the gate for every `IPAD-*` test.

## 10. Risks

**Phase 2 schedule risk.** Bundle assumes M1 + M2 land cleanly. If Phase 2 stalls, every later milestone stalls. Mitigation: M5–M9 spec text and disabled-test inventory can be drafted during M1–M4 to lose no calendar time.

**Multi-leaf live-surface cost.** 8 concurrent `terminal` channels each driving a libghostty surface is meaningfully heavier than today's single-pane iPhone. Mitigation: M8 explicitly tunes the cap; profile on real iPad hardware during M6 before committing.

**Compact-width regressions.** SwiftUI `NavigationSplitView` auto-collapse is deceptively easy to misuse. iPhone users get the same code path; a bug there is P0 for the existing user base. M9 regression sweep is mandatory before TestFlight.

**`pane_control` race conditions.** Two clients (iPad + Mac, or iPad + iPad) racing on `split` against the same leaf. Mitigation: server serializes by target leaf, second request returns 409, client suppresses 409 toasts silently.

**Cross-repo Phase 2 coordination.** The graftty-server work (Cloudflare Worker, signaling, TURN) is parallel but irrelevant to this bundle — iPad uses Direct/Tailscale signaling. Direct mode signaling lives in `graftty` itself. No coordination overhead with `graftty-server` for this bundle.

**WebRTC SDK choice for iOS.** GoogleWebRTC binary, Apple-private WebKit-backed RTCPeerConnection bridge, or a Swift-native alternative? Affects app size, App Store acceptance, maintenance. Decided in M1.

## 11. Non-goals

- **Cloud-routed signaling.** Phase 4 of the WebRTC design. iPad uses Direct/Tailscale signaling only in v1.
- **Pane move-to-another-worktree.** Desktop has it; iPad does not in v1.
- **Per-pane configuration UI.** Worktree-level "stop", "delete", etc. stay on the existing swipe actions. Pane-level settings — out.
- **Drag-and-drop sidebar reordering on iPad.** Desktop has it; iPad inherits sort order via the snapshot. Out for v1.
- **Push notifications for `panes_state` events.** `IOS-8.5` stands.
- **Web client iPad parity.** Web client is being deprecated.

## 12. Open questions

1. **Pane divider ratios — per-client or shared?** v1 stores ratios as per-iPad-client UI state, not part of the shared splittree. Means resizing on iPad doesn't move the divider on the Mac. Simpler. May feel surprising — flagged for review during M6.
2. **Focused-pane toolbar position.** Top-right (avoids hand zone, may collide with terminal output near the cursor) vs bottom-right (collides with soft keyboard, requires hide-on-keyboard logic). Decide in M7 with a real device.
3. **Swap RPC target.** Desktop `swap` operates on a specified pair. Touch UI has no second selection — does the iPad toolbar's swap button swap with the previous-focused leaf? Or open a sheet? Decide in M7.
4. **Sidebar pane-row count cap.** A worktree with 10 leaves bloats the sidebar. Cap visible rows under a worktree (collapse to "+N more" after 5)? Out of scope for v1 spec text; revisit if it bites.

## 13. Decisions summary

| Decision | Choice |
|---|---|
| Worktree sidebar on iPad | 2-column `NavigationSplitView` with host header |
| Multi-pane detail | Full `SplitTree` rendering, recursive, live terminals per leaf |
| Pane lifecycle on iPad | Read-write (`split`, `close`, `swap`) via new `pane_control` channel |
| Transport | WebRTC DataChannel only, per WebRTC design §10 |
| Model-push | New `panes_state` channel, server snapshots on every change |
| Compact-width fallback | Same code path; auto-collapse via `NavigationSplitView` |
| Pane focus state | Per-iPad-client; does not move Mac focus |
| Pane resize ratios | Per-iPad-client in v1; revisit during M6 |
| Live channel budget | 8 concurrent `terminal` channels; LRU evict to snapshot |
| Compact-width pane UI | Single focused leaf; sidebar pane-rows navigate |
| Lifecycle UI | Focused-pane toolbar overlay (split / close / swap / focus hand-off) |
| Phase 2 dependency | Bundled — M1+M2 ship as part of this work |
