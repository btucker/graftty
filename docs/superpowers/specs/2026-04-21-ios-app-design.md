# iOS App — Design Specification

A universal iPhone + iPad app, `GrafttyMobile`, that attaches to a running Graftty server over Tailscale using the existing `/sessions` + `/ws?session=<name>` WebSocket protocol (see §15 of `SPECS.md`). The iOS app is a peer UI to the Mac app — multi-session, sidebar-style — not a mobile replacement for the Phase 2 single-pane web client.

## Goal

After v1 ships, this user story works:

> I open Graftty Settings on my Mac and tap "Show QR". On my iPhone or iPad, on the same tailnet, I open `GrafttyMobile`, scan the QR, and authenticate with Face ID. The app shows my running sessions grouped by repo, just like the Mac sidebar. I tap one and a live libghostty pane comes up — same parser as the Mac app, so escape sequences render identically. On iPad with a hardware keyboard, I can split left/right and work in two sessions at once. When I put the phone down and pick it up five minutes later, Face ID re-prompts; on unlock, the sessions reconnect and pick up exactly where I left off — the zmx daemon kept them alive.

## Core promise

**Shared renderer.** The iOS app uses `GhosttyTerminal.TerminalView` + `InMemoryTerminalSession` from `libghostty-spm` — the same Swift package the Mac app already depends on. libghostty-spm ships a UIKit `TerminalViewRepresentable` alongside its AppKit one and targets `.iOS(.v17)`. The VT parser is identical on every Graftty surface (macOS native pane, web client WASM, iOS native) — per `WEB-5.1`'s "single parser keeps escape-sequence behavior identical" ethos.

**No new server protocol.** The iOS client speaks exactly what the web client speaks today:

- `GET /sessions` → `[SessionInfo]` (`WEB-5.4`).
- `/ws?session=<name>` WebSocket upgrade (`WEB-3.3`).
- Binary frames carry raw PTY bytes in both directions (`WEB-3.4`, `WEB-5.2`).
- Text frames carry JSON control envelopes — currently only `{"type":"resize","cols":…,"rows":…}` (`WEB-3.5`, `WEB-5.3`).

The iOS app is architecturally a sibling of the React `TerminalPane`, multiplied out to N concurrent WebSockets for the sidebar-style UI.

## Scope

### In scope for v1

- **Universal target.** iPhone + iPad, one SwiftUI codebase, layout forks on `horizontalSizeClass`.
- **Persistent saved hosts.** Keychain-backed list of hosts with user-chosen labels. Multi-host.
- **QR onboarding.** Mac Settings pane gains a "Show QR" action rendering the current Base URL. iOS app has a QR scanner that parses the URL and saves a new host.
- **Session picker.** Grouped by `repoDisplayName`, mirroring the web client's root page.
- **Multi-session in-app.** Each visible pane owns its own `URLSessionWebSocketTask` + `InMemoryTerminalSession`.
- **iPad layout.** `NavigationSplitView` sidebar + detail. Optional left/right split on a single detail, two panes max (two concurrent WebSockets).
- **iPhone layout.** Compact navigation stack + bottom session switcher.
- **Biometric gate.** Face ID / passcode on cold launch and after 5 minutes in background. `LocalAuthentication` `deviceOwnerAuthentication` policy so a passcode fallback is always available.
- **Mobile input.** Keyboard accessory bar above the software keyboard with Esc, Tab, Ctrl (sticky), arrow keys, and common symbols. Hardware keyboard support via `UIKeyCommand` for Ctrl/Cmd chords.
- **Reconnect.** On background, close all WebSockets with code 1000 (server SIGTERMs the `zmx attach` child per `WEB-4.5`; the daemon survives per `ZMX-4.4`). On foreground, re-dial every previously active pane. Session state is intact because zmx preserved it.

### Non-goals for v1

- **No non-Graftty hosts.** Not a generic SSH/mosh client; Graftty-over-Tailscale only.
- **No mouse / OSC 52 / Kitty protocol in the pane.** Matches `WEB-6.2`.
- **No session management from iOS.** Can't create, close, or stop a worktree; can't split panes server-side; can't move panes. Read-and-type only.
- **No scrollback persisted on the phone.** On reconnect, the user sees whatever the zmx daemon's buffer still has.
- **No push notifications.** No background PR status, no "build finished" push.
- **No in-app Tailscale.** The user must have Tailscale's iOS app installed, signed in, and connected. We do not bundle the Tailscale SDK.

## Architecture

```
[iPhone / iPad]                         [Graftty (Mac)]                 [zmx daemon]
  │                                           │                              │
  │── HTTPS? no — plain HTTP over tailnet ──►│                              │
  │── GET /sessions ────────────────────────►│ (Tailscale WhoIs gate —      │
  │◄── [{name, worktreePath, repoDisp…}] ────│  owner-only, same as the web)│
  │                                           │                              │
  │── WS /ws?session=<name> upgrade ────────►│                              │
  │                                           │  [spawn zmx attach <name>]──►│
  │◄── PTY bytes (binary WS) ─────────────────│                              │
  │── PTY bytes (binary WS) ─────────────────►│                              │
  │── {"type":"resize",...} (text WS) ───────►│  [ioctl TIOCSWINSZ]          │
```

One WebSocket per visible pane; iPad splits mean up to 2 concurrent sockets; iPhone is always 1.

### Discovery and onboarding

The server binds only to Tailscale IPs + loopback (`WEB-1.1`), so a phone on plain Wi-Fi cannot reach it. The user must be on the same tailnet. Given that, onboarding is QR-code handoff:

1. **Mac side.** Settings pane renders the current Base URL (e.g., `http://mac-name.tailnet-name.ts.net:8799/`) as a QR code via CoreImage's `CIFilter.qrCodeGenerator`. The URL is already being composed by `WebURLComposer.baseURL(host:port:)` (`WEB-1.8` brackets IPv6); no new URL logic.
2. **iOS side.** `HostPickerView` has an "Add host" button that opens an `AVFoundation` scanner. On successful scan, the parsed URL plus a user-chosen label becomes a `Host` record saved to Keychain.

Manual URL entry is also supported as a fallback for power users who dislike cameras or want to type a tailnet hostname directly. Both paths reach the same `HostStore.add(_:)` entry point.

### Authentication

Two layers:

1. **Network-level.** Tailscale WhoIs gates every request and every WebSocket upgrade (`WEB-2.1`/`WEB-2.2`). An iPhone whose tailnet identity matches the Mac's owner is accepted; any other peer sees HTTP 403 at the protocol level. This is identical to how the web client is authenticated; the iOS app inherits it for free.
2. **Device-level.** A `BiometricGate` component prompts Face ID / passcode on cold launch and when the app has been in background ≥5 minutes. The gate uses `LAContext` with `deviceOwnerAuthentication` so a passcode fallback is always available. Until the gate unlocks, `HostPickerView` and every downstream view stays behind a full-screen lock overlay — no plaintext hostnames, no session names.

The gate does not protect Keychain reads directly (iOS's system unlock already does); it gates the UI.

### Renderer

Every terminal pane is a `TerminalView` from `libghostty-spm`'s `GhosttyTerminal` module, backed by an `InMemoryTerminalSession`. The session's two closures map onto the WebSocket:

```swift
let session = InMemoryTerminalSession(
    write: { data in client.sendBinary(data) },         // writeHandler → WS out
    resize: { viewport in
        client.sendText(WebControlEnvelope.resize(
            cols: UInt16(viewport.columns),
            rows: UInt16(viewport.rows)
        ))                                              // resizeHandler → WS out
    }
)
// Binary WS frame in → session.receive(data) → libghostty parses.
```

Key consequence: the keyboard, text selection, scrollback, cursor handling, and touch gestures behave however libghostty-spm's iOS implementation behaves. We inherit those behaviors wholesale. Any feature gaps in libghostty-spm's UIKit path become Graftty iOS feature gaps; the fix belongs upstream.

### Target topology

All business logic lives in SwiftPM targets so it's testable and reusable across Mac and iOS. A thin Xcode project owns the iOS .app bundle (Info.plist, entitlements, assets, launch screen, code-signing). This split is standard because SwiftPM alone cannot produce an iOS .app with the required bundle metadata.

`Package.swift` becomes multi-platform:

```
platforms: [.macOS(.v14), .iOS(.v17)]

targets:
  + .target(name: "GrafttyProtocol")                  // NEW, platform-neutral
  + .target(name: "GrafttyMobileKit",                 // NEW, iOS-only
              dependencies: [
                "GrafttyProtocol",
                .product(name: "GhosttyTerminal", package: "libghostty-spm"),
              ])
  + .testTarget(name: "GrafttyProtocolTests")
  + .testTarget(name: "GrafttyMobileKitTests")

  modified:
    GrafttyKit: add dependency on GrafttyProtocol; delete the moved types.
```

`Sources/GrafttyProtocol/` contains only the types that cross the wire between client and server: `SessionInfo` (moved verbatim from `Sources/GrafttyKit/Web/WebServer.swift`) and `WebControlEnvelope` (moved verbatim from `Sources/GrafttyKit/Web/WebControlEnvelope.swift`). Both types already exist with the shapes we need — this is a pure move, not a rewrite. GrafttyKit imports them back through the new library so the server continues to emit and parse them unchanged.

`Sources/GrafttyMobileKit/` layout:

```
App/
  AppEntry.swift             // @main SwiftUI App
  RootView.swift             // Face ID gate → HostPicker or HostDetail
Auth/
  BiometricGate.swift        // LAContext wrapper, 5-min idle rule
Hosts/
  HostStore.swift            // Keychain CRUD
  Host.swift                 // value type {id, label, baseURL, lastUsedAt, addedAt}
  QRScannerView.swift        // AVFoundation scanner
Session/
  SessionClient.swift        // one WS + one InMemoryTerminalSession
  SessionsFetcher.swift      // GET /sessions
  HostController.swift       // per-host: sessions list + active panes + reconnect policy
Terminal/
  TerminalPaneView.swift     // wraps GhosttyTerminal.TerminalView
  KeyboardAccessoryBar.swift // Esc/Tab/Ctrl/arrows/…
  ExternalKeyboardBinding.swift // UIKeyCommand table
UI/
  HostPickerView.swift
  SessionPickerView.swift    // grouped by repoDisplayName
  SplitContainerView.swift   // iPad-only 1 or 2 pane layout
  SessionSwitcherView.swift  // iPhone compact swap UI
```

`Apps/GrafttyMobile/GrafttyMobile.xcodeproj` is a single iOS App target. It references the package by local path and links `GrafttyMobileKit`. The Xcode project is the minimum wrapper needed for bundle metadata; all testable logic stays in the SwiftPM library target.

### Data flow

**Onboarding (first run).**

1. User opens Mac Settings → "Show QR". Mac renders QR of `WebURLComposer.baseURL(host, port)`.
2. User launches `GrafttyMobile`. `BiometricGate` prompts Face ID. On success → `HostPickerView`.
3. Empty list → "Add host" → `QRScannerView` → parses URL → saves to Keychain via `HostStore.add(_:)`.

**Open a session.**

1. User taps a host → `HostController` starts, calls `SessionsFetcher.fetch(baseURL)` → 200 `[SessionInfo]` → `SessionPickerView` groups by `repoDisplayName`.
2. User taps a session → `HostController` creates a `SessionClient(session.name)`. Client opens `URLSessionWebSocketTask` at `ws://<host>:<port>/ws?session=<urlEncoded>` (or `wss://` if the host's scheme is HTTPS).
3. `TerminalPaneView` mounts `TerminalView` from `GhosttyTerminal` bound to the client's `InMemoryTerminalSession`. On first layout, the view emits a resize via the `InMemoryTerminalSession.resizeHandler` → client sends `{"type":"resize","cols":…,"rows":…}` text frame (`WEB-5.3`).
4. Server sends binary frames → `session.receive(data)` → libghostty parses → SwiftUI view redraws.
5. User typing → libghostty's surface emits bytes via `writeHandler` → binary WS frame out (`WEB-5.2`).

**iPad split.**

User taps "Split right" in a pane → `HostController` allocates a second `SessionClient` for the same or different session name → `SplitContainerView` shows both panes side-by-side. Each pane's `TerminalView` independently reports resize to its own WebSocket. Two concurrent `/ws` sockets, same host, same WhoIs check on each.

**Backgrounding.**

App enters background → `HostController.teardown()` closes every `URLSessionWebSocketTask` with code 1000. The server responds by SIGTERMing its `zmx attach` child per `WEB-4.5`; the zmx daemon survives per `ZMX-4.4`.

App foregrounds within 5 minutes → `BiometricGate` does not re-prompt → `HostController.resume()` re-dials every previously-active pane. The terminal buffer, cursor, and running process list are intact because the daemon stayed alive.

App foregrounds after ≥5 minutes → `BiometricGate` re-prompts; on success → resume.

**Host disappears / server stops.**

WebSocket errors or `/sessions` fails → pane displays a "disconnected" banner with "Reconnect" and "Back to sessions" buttons. `HostController` applies exponential backoff starting at 1 s, capped at 30 s, while the host tab is visible; stops backing off entirely when the host view is hidden.

## Behavior requirements (EARS)

These are the requirements that will land in `SPECS.md` under a new top-level section. Scoped identifiers below use the `IOS-*` prefix; sub-sections re-use the pattern already established (`IOS-1.1`, etc.).

### §18. iOS App

#### 18.1 Target and platform

**IOS-1.1** The application shall provide a universal iOS app, `GrafttyMobile`, targeting iOS 17 or later, running on both iPhone and iPad form factors with layouts forked on `horizontalSizeClass`. (iOS 17 is the minimum because the app uses Swift's `@Observable` macro, which requires iOS 17 at runtime.)

**IOS-1.2** All iOS business logic (views, stores, session management, terminal bridging) shall live in the SwiftPM library target `GrafttyMobileKit`. The iOS .app bundle shall live in a separate Xcode project at `Apps/GrafttyMobile/GrafttyMobile.xcodeproj` that depends on `GrafttyMobileKit` by local package reference.

**IOS-1.3** Wire-format types shared between `GrafttyMobile` and the `GrafttyKit` web server — `SessionInfo`, `WebControlEnvelope` — shall live in a shared library target `GrafttyProtocol`, imported by both targets. This ensures a breaking JSON-shape change is a compile-time error on both sides.

#### 18.2 Discovery and host storage

**IOS-2.1** The application shall provide a QR-code scanner (`AVFoundation`) that accepts any URL matching `^(http|https)://<host>(:\d+)?/?$` as a new saved host. A QR payload failing this parse shall keep the scanner open and present a non-dismissing toast `QR did not contain a Graftty URL`.

**IOS-2.2** The application shall provide manual URL entry as an equivalent alternative to the QR scanner, reaching the same `HostStore.add(_:)` entry point.

**IOS-2.3** The application shall persist the saved-host list to the iOS Keychain, one generic-password item per host, keyed by host UUID. Each host record shall carry `{id, label, baseURL, lastUsedAt, addedAt}`.

**IOS-2.4** The macOS application's Settings pane shall render the current Base URL (as already composed by `WebURLComposer.baseURL(host:port:)`) as a scannable QR code alongside the existing copy/open actions (`WEB-1.12`). When the server status is not `.listening`, the QR-code area shall render a placeholder explaining why (e.g., "Tailscale unavailable").

#### 18.3 Authentication

**IOS-3.1** On cold launch, the application shall display a full-screen lock overlay until `LAContext.evaluatePolicy(.deviceOwnerAuthentication, …)` resolves successfully. While locked, no saved hostnames, session names, or terminal contents shall be visible.

**IOS-3.2** When the application enters the background, it shall record the wall-clock timestamp. When it foregrounds, if ≥5 minutes have elapsed since that timestamp, the application shall re-prompt per `IOS-3.1`.

**IOS-3.3** On authentication denial or cancellation, the application shall remain locked with a retry button; no UI behind the lock shall become interactive.

#### 18.4 Session fetching and rendering

**IOS-4.1** When the user selects a saved host, the application shall issue `GET <baseURL>/sessions` and render the response as a session picker grouped by `SessionInfo.repoDisplayName`, matching the grouping behavior of the web client's root page (`WEB-5.4`).

**IOS-4.2** When `GET /sessions` returns a non-2xx status or a body that fails to decode as `[SessionInfo]`, the application shall render an error banner displaying the status code (or "malformed response") and a manual retry button. A 403 response shall instead render `Not authorized — is this device on your tailnet?` with a link that opens the Tailscale iOS app.

**IOS-4.3** When the user selects a session, the application shall open a `URLSessionWebSocketTask` at `<ws-or-wss>://<host>:<port>/ws?session=<urlEncoded name>` and attach it to an `InMemoryTerminalSession` from `libghostty-spm` rendered by `GhosttyTerminal.TerminalView`.

**IOS-4.4** On WebSocket open, the application shall send an initial `{"type":"resize","cols":<n>,"rows":<m>}` text frame derived from the terminal view's first-layout viewport, before forwarding any user input. This mirrors `WEB-5.3`.

**IOS-4.5** Server-sent binary WebSocket frames shall be forwarded to `InMemoryTerminalSession.receive(_:)` unmodified. User input emitted by libghostty via the `writeHandler` callback shall be sent as a binary WebSocket frame, mirroring `WEB-3.4` and `WEB-5.2`.

**IOS-4.6** On subsequent terminal resizes (viewport change, keyboard appearance, rotation), the application shall send a `{"type":"resize",...}` text frame matching the new viewport, mirroring `WEB-5.3`.

#### 18.5 Multi-pane layout

**IOS-5.1** On iPad (regular `horizontalSizeClass`), the application shall render a `NavigationSplitView` sidebar + detail layout. The sidebar shall show saved hosts; tapping a host reveals the session picker; tapping a session renders the detail as a terminal pane.

**IOS-5.2** On iPad, the application shall support an in-app left/right split in the detail area, with up to two concurrent panes. Each pane owns its own `URLSessionWebSocketTask` + `InMemoryTerminalSession`. Each pane independently emits its own resize envelopes.

**IOS-5.3** On iPhone (compact `horizontalSizeClass`), the application shall collapse the layout to a `NavigationStack`. Only one pane is visible at a time; session switching is via a bottom-edge session switcher.

**IOS-5.4** When multiple panes exist, only one pane shall be focused at a time. The keyboard accessory bar and hardware keyboard routing shall deliver input only to the focused pane.

#### 18.6 Input

**IOS-6.1** Above the software keyboard, the application shall render a `KeyboardAccessoryBar` exposing, at minimum: Esc, Tab, Ctrl (sticky), ↑ ↓ ← →, `|`, `/`, `~`, `-`. The Ctrl key shall be a one-shot modifier — tapping Ctrl then any subsequent key (letter, digit, space, or symbol) shall send that key with the control modifier applied to the focused pane's `TerminalView` via libghostty-spm's key-event API; the modifier shall clear after that one key, or on a second Ctrl tap if no intervening key was pressed.

**IOS-6.2** libghostty-spm's `TerminalView` shall be the primary owner of key-event translation for every pane; software-keyboard text and hardware-keyboard key events shall reach it directly. The application shall additionally publish a `UIKeyCommand` table solely for **application-level** shortcuts that must be intercepted before the terminal sees them (e.g., Cmd-\\ to split on iPad, Cmd-1…9 to switch visible sessions). `UIKeyCommand` shall not be used to re-implement terminal chord translation — that path belongs to libghostty-spm.

#### 18.7 Lifecycle

**IOS-7.1** When the application enters the background, it shall close every active `URLSessionWebSocketTask` with WebSocket close code 1000 (normal closure) and tear down every `InMemoryTerminalSession`. The server's response (SIGTERM to each `zmx attach` child per `WEB-4.5`) leaves the zmx daemon alive per `ZMX-4.4`, so reconnect picks up the same session.

**IOS-7.2** When the application foregrounds and the biometric gate is satisfied (either the ≥5 min path with re-prompt per `IOS-3.2` or the within-5-min fast path), the application shall re-fetch `/sessions` for each host whose panes were previously active and then re-dial every pane whose session name is still present in the response, re-mounting its `TerminalView`. Per `PERSIST-4.1` the application does not persist scrollback itself; whatever the zmx daemon still has is what the user sees.

**IOS-7.3** When a previously active pane's session name is absent from the fresh `/sessions` response (e.g., the worktree was stopped on the Mac while the iOS app was backgrounded), the application shall mark that pane as `sessionEnded` with a non-retryable banner and shall not open a WebSocket for it. The banner shall offer "Back to sessions" as the only action.

**IOS-7.4** On WebSocket failure (upgrade failure, read/write error, or close frame not initiated by the app) for a pane whose session name is still listed in `/sessions`, the application shall display a per-pane "disconnected" banner with "Reconnect" and "Back to sessions" buttons. While the host view is visible, the application shall retry automatically with exponential backoff: the delay starts at 1 second, doubles after each successive failure, and is capped at 30 seconds. Each successful connect resets the delay to 1 second. When the host view is not visible, no automatic retry shall occur.

#### 18.8 Non-goals (recorded for future specs)

**IOS-8.1** The v1 iOS app shall not support connecting to non-Graftty SSH/mosh hosts.

**IOS-8.2** The v1 iOS app shall not forward terminal mouse events, OSC 52 clipboard reads, or Kitty graphics/keyboard-protocol sequences. (Mirrors `WEB-6.2`.)

**IOS-8.3** The v1 iOS app shall not initiate any pane / worktree / session lifecycle operations on the Mac (create, close, split, move, stop). Any such control surface is deferred to a future spec.

**IOS-8.4** The v1 iOS app shall not persist terminal scrollback on the device. On reconnect, it renders whatever the zmx daemon's buffer still contains.

**IOS-8.5** The v1 iOS app shall not use push notifications for PR status, build completions, or session events.

## Testing strategy

| Layer | What is tested | Mechanism |
|---|---|---|
| `GrafttyProtocol` | `WebControlEnvelope` parse/encode round-trip; `SessionInfo` JSON golden fixture matches the bytes `WebServer` emits. | `swift test`, shared Mac + iOS. |
| `SessionClient` | Inbound binary frame → `InMemoryTerminalSession.receive` call equality; `writeHandler` → outbound binary frame payload equality; `resizeHandler` → correctly shaped JSON text frame. | Fake WebSocket pair. |
| `HostController` | Reconnect backoff sequence, teardown on background, resume after unlock. | Fake clock, fake `SessionClient`. |
| `BiometricGate` | 5-minute idle policy math. | Fake clock (`LAContext` is stubbed). |
| `HostStore` | Keychain round-trip of a `Host` record under a test service name. | iOS simulator test target. |
| Integration | Mac running Graftty + iOS simulator attaches to real `/sessions` and `/ws`. | Manual dev loop, no CI. |

Mac-side behavior changes (the two moved types, the new QR view in Settings) are covered by existing GrafttyKit tests — if they still compile and pass against the imported `GrafttyProtocol` types, the move was non-breaking.

## Tradeoffs and alternatives considered

**Renderer choice.** Two alternatives were rejected:

- **WKWebView hosting the existing `ghostty-web` WASM.** Zero rendering work and perfect parser parity, but iOS WebView keyboard handling is hostile to external keyboards and the result always feels web-wrapped. Rejected: use-case v1 is tap-in pilot, not passive viewing.
- **SwiftTerm (Miguel de Icaza's Swift VT emulator).** Best native feel, great external-keyboard support, but a different VT parser than libghostty. Rejected because the cross-surface promise of "same escape-sequence behavior everywhere" is load-bearing for Graftty's identity.

Using `libghostty-spm`'s iOS path gives native feel *and* identical parser behavior with less work than either alternative — it's the same dependency the Mac app already uses.

**Code topology.** Two alternatives were considered:

- **In-repo duplicate-the-protocol (no shared target).** Simpler up front, but the web-client/server contract is already encoded in two Swift files (`WebServer.swift`'s `SessionInfo`, `WebControlEnvelope.swift`); duplicating into a third copy on the iOS side invites silent drift the first time the envelope grows past `resize`.
- **Separate repo for `graftty-ios`.** Decouples release trains, but at the cost of protocol drift risk and a second repo to keep in sync. Chosen (B) keeps both in one repo, extracts the contract into `GrafttyProtocol`, and lets the compiler enforce protocol agreement.

**Splits on iPad.** The web client skips splits (`WEB-6.2`) because the server's 1 WebSocket ↔ 1 `zmx attach` model provides no splits primitive. We adopt the same stance: in-app splits on iPad are purely a client-side layout choice — two independent WebSockets rendered side-by-side. No server-side concept of "iPad pane pair" exists or should exist.

**Biometric gate duration.** Chose 5 minutes as the background-expiration window. Shorter (1-2 min) re-prompts too often during active triage; longer (15+ min) removes the "unlocked phone on a coffee-shop table" protection the gate exists to provide.
