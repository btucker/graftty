// Auto-generated inventory of unimplemented specs in this section.
// Promote a @Test(.disabled(...)) entry to a real @Test in a *Tests.swift
// file before implementing the behavior, then delete the entry from this
// inventory file. SPECS.md is regenerated from these markers by
// scripts/generate-specs.py.

import Testing

@Suite("IOS — pending specs")
struct IosTodo {
    @Test("""
@spec IOS-1.1: The application shall provide a universal iOS app, `GrafttyMobile`, targeting iOS 17 or later, running on both iPhone and iPad form factors with layouts forked on `horizontalSizeClass`. (iOS 17 is the minimum because the app uses Swift's `@Observable` macro, which requires iOS 17 at runtime.)
""", .disabled("not yet implemented"))
    func ios_1_1() async throws { }

    @Test("""
@spec IOS-1.2: All iOS business logic (views, stores, session management, terminal bridging) shall live in the SwiftPM library target `GrafttyMobileKit`. The iOS .app bundle shall live in a separate Xcode project at `Apps/GrafttyMobile/GrafttyMobile.xcodeproj` that depends on `GrafttyMobileKit` by local package reference.
""", .disabled("not yet implemented"))
    func ios_1_2() async throws { }

    @Test("""
@spec IOS-1.3: Wire-format types shared between `GrafttyMobile` and the `GrafttyKit` web server — `SessionInfo`, `WebControlEnvelope` — shall live in a shared library target `GrafttyProtocol`, imported by both targets. This ensures a breaking JSON-shape change is a compile-time error on both sides.
""", .disabled("not yet implemented"))
    func ios_1_3() async throws { }

    @Test("""
@spec IOS-1.4: While the iOS application is installed, it shall appear on the home screen and in the app switcher as "Graftty" (via `CFBundleDisplayName`) and shall use the same app icon as the macOS application, sourced from the shared master `Resources/AppIcon.png`. The Xcode target, `.xcodeproj`, on-disk sources directory, and bundle identifier keep the `GrafttyMobile` name internally so `Bundle.main.bundleIdentifier` checks, keychain service strings, and the `GrafttyMobileKit` SPM target continue to work unchanged — "GrafttyMobile" is the codebase's internal handle, "Graftty" is the user-facing brand on both platforms.
""", .disabled("not yet implemented"))
    func ios_1_4() async throws { }

    @Test("""
@spec IOS-2.1: The application shall provide a QR-code scanner (`AVFoundation`) that accepts any URL matching `^(http|https)://<host>(:\\d+)?/?$` as a new saved host. A QR payload failing this parse shall keep the scanner open and present a non-dismissing toast `QR did not contain a Graftty URL`.
""", .disabled("not yet implemented"))
    func ios_2_1() async throws { }

    @Test("""
@spec IOS-2.2: The application shall provide manual URL entry as an equivalent alternative to the QR scanner, reaching the same `HostStore.add(_:)` entry point.
""", .disabled("not yet implemented"))
    func ios_2_2() async throws { }

    @Test("""
@spec IOS-2.3: The application shall persist the saved-host list to a JSON file in `~/Library/Application Support/<bundleID>/hosts.json`, written atomically on each mutation. Each host record shall carry `{id, label, baseURL, lastUsedAt, addedAt}`. Keychain was initially specified here, but a saved host contains no secret (just URL, label, and timestamps), and iOS-simulator Keychain access requires a signing context that ad-hoc-signed Xcode builds without a `DEVELOPMENT_TEAM` cannot obtain (every `SecItemAdd` returns `errSecMissingEntitlement`, -34018). File storage works identically on simulator and device and upgrades cleanly to a per-field Keychain split when we later persist a secret (e.g., a bearer token).
""", .disabled("not yet implemented"))
    func ios_2_3() async throws { }

    @Test("""
@spec IOS-2.4: The macOS application's Settings pane shall render the current Base URL (as already composed by `WebURLComposer.baseURL(host:port:)`) as a scannable QR code alongside the existing copy/open actions (`WEB-1.12`). When the server status is not `.listening`, the QR-code area shall render a placeholder explaining why (e.g., "Tailscale unavailable").
""", .disabled("not yet implemented"))
    func ios_2_4() async throws { }

    @Test("""
@spec IOS-3.1: On cold launch, the application shall display a full-screen lock overlay until `LAContext.evaluatePolicy(.deviceOwnerAuthentication, …)` resolves successfully. While locked, no saved hostnames, session names, or terminal contents shall be visible.
""", .disabled("not yet implemented"))
    func ios_3_1() async throws { }

    @Test("""
@spec IOS-3.2: When the application enters the background, it shall record the wall-clock timestamp. When it foregrounds, if ≥5 minutes have elapsed since that timestamp, the application shall re-prompt per `IOS-3.1`.
""", .disabled("not yet implemented"))
    func ios_3_2() async throws { }

    @Test("""
@spec IOS-3.3: On authentication denial or cancellation, the application shall remain locked with a retry button; no UI behind the lock shall become interactive.
""", .disabled("not yet implemented"))
    func ios_3_3() async throws { }

    @Test("""
@spec IOS-4.1: When the user selects a saved host, the application shall issue `GET <baseURL>/worktrees/panes` and render the response as a **worktree** picker grouped by `WorktreePanes.repoDisplayName` (one row per running worktree, not one row per pane). This differs from the web client's flat session list (`WEB-5.4`) because the mobile flow is drill-down — worktree → pane tree → single pane — rather than flat selection.
""", .disabled("not yet implemented"))
    func ios_4_1() async throws { }

    @Test("""
@spec IOS-4.2: When `GET /sessions` returns a non-2xx status or a body that fails to decode as `[SessionInfo]`, the application shall render an error banner displaying the status code (or "malformed response") and a manual retry button. A 403 response shall instead render `Not authorized — is this device on your tailnet?` with a link that opens the Tailscale iOS app.
""", .disabled("not yet implemented"))
    func ios_4_2() async throws { }

    @Test("""
@spec IOS-4.3: When the user selects a session, the application shall open a `URLSessionWebSocketTask` at `<ws-or-wss>://<host>:<port>/ws?session=<urlEncoded name>` and attach it to an `InMemoryTerminalSession` from `libghostty-spm` rendered by `GhosttyTerminal.TerminalView`.
""", .disabled("not yet implemented"))
    func ios_4_3() async throws { }

    @Test("""
@spec IOS-4.4: On WebSocket open, the application shall send an initial `{"type":"resize","cols":<n>,"rows":<m>}` text frame derived from the terminal view's first-layout viewport, before forwarding any user input. This mirrors `WEB-5.3`.
""", .disabled("not yet implemented"))
    func ios_4_4() async throws { }

    @Test("""
@spec IOS-4.5: Server-sent binary WebSocket frames shall be forwarded to `InMemoryTerminalSession.receive(_:)` unmodified. User input emitted by libghostty via the `writeHandler` callback shall be sent as a binary WebSocket frame, mirroring `WEB-3.4` and `WEB-5.2`.
""", .disabled("not yet implemented"))
    func ios_4_5() async throws { }

    @Test("""
@spec IOS-4.6: On subsequent terminal resizes (viewport change, keyboard appearance, rotation), the application shall send a `{"type":"resize",...}` text frame matching the new viewport, mirroring `WEB-5.3`.
""", .disabled("not yet implemented"))
    func ios_4_6() async throws { }

    @Test("""
@spec IOS-4.7: When the user selects a saved host, the application shall issue `GET <baseURL>/ghostty-config` and, if the response is a non-empty 2xx body, pass it to `TerminalController.shared.updateConfigSource(.generated(text))` before mounting any `TerminalPaneView`. A missing or empty response is a non-fatal condition — the client shall fall back to `libghostty-spm`'s default configuration. The endpoint is a concatenation of the user's on-disk Ghostty configs (`$XDG_CONFIG_HOME/ghostty/config`, then `~/Library/Application Support/com.mitchellh.ghostty/config`) in the same priority order the Mac app applies them at launch, so terminals render with the same fonts, theme, and colors as the desktop.
""", .disabled("not yet implemented"))
    func ios_4_7() async throws { }

    @Test("""
@spec IOS-4.8: While a pane is mounted, the application shall hide the navigation bar (`.toolbar(.hidden, for: .navigationBar)`) and extend the terminal beneath every safe-area edge (`.ignoresSafeArea()`) — top (under the notch), bottom (under the home indicator), and the left/right safe-area strips in landscape. libghostty renders its configured background color to the full view bounds, so the unsafe regions pick up the terminal's own background rather than the SwiftUI default. The user returns to the worktree detail via the system edge-swipe-back gesture rather than an explicit button.
""", .disabled("not yet implemented"))
    func ios_4_8() async throws { }

    @Test("""
@spec IOS-4.9: The application shall display a floating keyboard button at the bottom-trailing corner of the pane view with three states:
""", .disabled("not yet implemented"))
    func ios_4_9() async throws { }

    @Test("""
@spec IOS-4.10: When the user selects a worktree from the picker (`IOS-4.1`), the application shall present a second screen rendering the worktree's pane split tree faithfully to the Mac sidebar's layout: each split respects its `direction` (horizontal/vertical) and `ratio`; each leaf is a tappable tile labelled with the pane's current title (or the session name when no title has been set yet). Tapping a tile pushes the fullscreen terminal for that session.
""", .disabled("not yet implemented"))
    func ios_4_10() async throws { }

    @Test("""
@spec IOS-4.11: When the user taps a pane tile, the application shall open a fullscreen terminal view for that session — a single `TerminalPaneView` with the navigation bar hidden and the terminal extending beneath the top safe area (`IOS-4.8`). The WebSocket is opened on view appear and closed on view disappear; system edge-swipe-back returns to the worktree detail.
""", .disabled("not yet implemented"))
    func ios_4_11() async throws { }

    @Test("""
@spec IOS-5.1: On iPad (regular `horizontalSizeClass`), the application shall render a `NavigationSplitView` sidebar + detail layout. The sidebar shall show saved hosts; tapping a host reveals the session picker; tapping a session renders the detail as a terminal pane.
""", .disabled("not yet implemented"))
    func ios_5_1() async throws { }

    @Test("""
@spec IOS-5.2: On iPad, the application shall support an in-app left/right split in the detail area, with up to two concurrent panes. Each pane owns its own `URLSessionWebSocketTask` + `InMemoryTerminalSession`. Each pane independently emits its own resize envelopes.
""", .disabled("not yet implemented"))
    func ios_5_2() async throws { }

    @Test("""
@spec IOS-5.3: On iPhone (compact `horizontalSizeClass`), the application shall collapse the layout to a `NavigationStack`. Only one pane is visible at a time; session switching is via a bottom-edge session switcher.
""", .disabled("not yet implemented"))
    func ios_5_3() async throws { }

    @Test("""
@spec IOS-5.4: When multiple panes exist, only one pane shall be focused at a time. The keyboard accessory bar and hardware keyboard routing shall deliver input only to the focused pane.
""", .disabled("not yet implemented"))
    func ios_5_4() async throws { }

    @Test("""
@spec IOS-5.5: While a session's terminal is rendered full-screen (navigation bar hidden per the fullscreen layout), the application shall overlay a translucent back-button in the top-left that pops the current session off the `NavigationPath`, returning the user to the worktree detail they drilled in from. The button shall be rendered as a chevron inside an `.ultraThinMaterial` circle at a fixed 44×44pt tap target, padded 12pt from the top and leading edges so it floats above the terminal content without being clipped by the device's notch / rounded corners. The system edge-swipe gesture remains available but is not discoverable, so this overlay is the primary affordance.
""", .disabled("not yet implemented"))
    func ios_5_5() async throws { }

    @Test("""
@spec IOS-5.6: While the iOS client is not the size-leader (before the first keystroke on this session per `IOS-6.5`) and the server-announced grid's column count exceeds what fits in the device's container at libghostty's current cell width, the application shall wrap the terminal pane in a horizontal `ScrollView` whose inner frame width equals `serverCols × cellWidthPoints`. `cellWidthPoints` shall be taken from the `cellWidthPixels` field of libghostty's resize-callback viewport (divided by the display scale) — not a static font-aspect estimate — so libghostty's VT parser runs at exactly `serverCols` columns and server output flows through without internal line-wrap. Before the first viewport callback delivers a non-zero cell width, an overshooting fallback shall be used so the scroll frame errs toward too-wide (extra blank cells) rather than too-narrow (wrapped lines).
""", .disabled("not yet implemented"))
    func ios_5_6() async throws { }

    @Test("""
@spec IOS-6.1: While the software keyboard is visible, the application shall render a compact terminal control bar above the keyboard. The v1 bar shall expose, at minimum: Esc, Tab, Ctrl-C, Ctrl-D, ↑, ↓, ←, →, submit Return, insert literal LF, and Hide Keyboard. These controls shall send explicit PTY bytes through `SessionClient` rather than relying on UIKit text entry: Esc=`0x1B`, Tab=`0x09`, Ctrl-C=`0x03`, Ctrl-D=`0x04`, arrows=`ESC [ A/B/D/C`, submit Return=`0x0D`, and literal LF=`0x0A`.
""", .disabled("not yet implemented"))
    func ios_6_1() async throws { }

    @Test("""
@spec IOS-6.2: libghostty-spm's `TerminalView` shall remain the primary owner of terminal rendering and hardware-keyboard key-event translation for every pane. Ordinary software-keyboard text shall use the app-owned `UIKeyInput` path in `IOS-6.6` so committed text is sent as raw PTY input instead of paste text. The application shall additionally publish a `UIKeyCommand` table solely for **application-level** shortcuts that must be intercepted before the terminal sees them (e.g., Cmd-\\\\ to split on iPad, Cmd-1…9 to switch visible sessions). `UIKeyCommand` shall not be used to re-implement general terminal chord translation.
""", .disabled("not yet implemented"))
    func ios_6_2() async throws { }

    @Test("""
@spec IOS-6.5: On the first user keystroke within a session, the iOS client shall claim size-leadership by sending its last-measured viewport `(cols, rows)` to the server via a `WebControlEnvelope.resize` frame. Subsequent libghostty-reported layout changes shall be forwarded to the server. Before this moment, layout-driven resize callbacks shall be memoized but not sent, so the Mac pane's `TIOCGWINSZ` dictates the PTY's dimensions and `IOS-5.6`'s scroll-view path governs rendering.
""", .disabled("not yet implemented"))
    func ios_6_5() async throws { }

    @Test("""
@spec IOS-6.6: While a terminal pane is focused on iOS, ordinary software-keyboard text shall be captured by GrafttyMobile's own `UIKeyInput` responder and forwarded to the remote PTY as raw UTF-8 bytes via `SessionClient.sendSoftwareKeyboardText(_:)`, rather than through libghostty's `TerminalSurface.sendText(_:)` path. A single software-keyboard newline shall be translated to CR (`0x0D`) per `IOS-6.3`, and software-keyboard delete shall send DEL (`0x7F`). This prevents normal typing from being wrapped in bracketed-paste delimiters (`ESC [ 200 ~` / `ESC [ 201 ~`) that prompt-driven TUIs can display as stray `[200~` text.
""", .disabled("not yet implemented"))
    func ios_6_6() async throws { }

    @Test("""
@spec IOS-7.1: When the application enters the background, it shall close every active `URLSessionWebSocketTask` with WebSocket close code 1000 (normal closure) and tear down every `InMemoryTerminalSession`. The server's response (SIGTERM to each `zmx attach` child per `WEB-4.5`) leaves the zmx daemon alive per `ZMX-4.4`, so reconnect picks up the same session.
""", .disabled("not yet implemented"))
    func ios_7_1() async throws { }

    @Test("""
@spec IOS-7.2: When the application foregrounds and the biometric gate is satisfied (either the ≥5 min path with re-prompt per `IOS-3.2` or the within-5-min fast path), the application shall re-fetch `/sessions` for each host whose panes were previously active and then re-dial every pane whose session name is still present in the response, re-mounting its `TerminalView`. Per `PERSIST-4.1` the application does not persist scrollback itself; whatever the zmx daemon still has is what the user sees.
""", .disabled("not yet implemented"))
    func ios_7_2() async throws { }

    @Test("""
@spec IOS-7.3: When a previously active pane's session name is absent from the fresh `/sessions` response (e.g., the worktree was stopped on the Mac while the iOS app was backgrounded), the application shall mark that pane as `sessionEnded` with a non-retryable banner and shall not open a WebSocket for it. The banner shall offer "Back to sessions" as the only action.
""", .disabled("not yet implemented"))
    func ios_7_3() async throws { }

    @Test("""
@spec IOS-7.4: On WebSocket failure (upgrade failure, read/write error, or close frame not initiated by the app) for a pane whose session name is still listed in `/sessions`, the application shall display a per-pane "disconnected" banner with "Reconnect" and "Back to sessions" buttons. While the host view is visible, the application shall retry automatically with exponential backoff: the delay starts at 1 second, doubles after each successive failure, and is capped at 30 seconds. Each successful connect resets the delay to 1 second. When the host view is not visible, no automatic retry shall occur.
""", .disabled("not yet implemented"))
    func ios_7_4() async throws { }

    @Test("""
@spec IOS-8.1: The v1 iOS app shall not support connecting to non-Graftty SSH/mosh hosts.
""", .disabled("not yet implemented"))
    func ios_8_1() async throws { }

    @Test("""
@spec IOS-8.2: The v1 iOS app shall not forward terminal mouse events, OSC 52 clipboard reads, or Kitty graphics/keyboard-protocol sequences. (Mirrors `WEB-6.2`.)
""", .disabled("not yet implemented"))
    func ios_8_2() async throws { }

    @Test("""
@spec IOS-8.3: The v1 iOS app shall not initiate pane lifecycle operations on the Mac (close, split, move, stop) nor worktree-stop or session-kill operations. Worktree **creation** is supported per §19.9. Any other such control surface is deferred to a future spec.
""", .disabled("not yet implemented"))
    func ios_8_3() async throws { }

    @Test("""
@spec IOS-8.4: The v1 iOS app shall not persist terminal scrollback on the device. On reconnect, it renders whatever the zmx daemon's buffer still contains.
""", .disabled("not yet implemented"))
    func ios_8_4() async throws { }

    @Test("""
@spec IOS-8.5: The v1 iOS app shall not use push notifications for PR status, build completions, or session events.
""", .disabled("not yet implemented"))
    func ios_8_5() async throws { }

    @Test("""
@spec IOS-9.1: The worktree-picker screen (`IOS-4.1`) shall display an "Add Worktree" action as a primary toolbar item. Tapping it shall present a modal sheet collecting the fields required by `POST /worktrees` (`WEB-7.2`): a repository picker populated from `GET /repos` (hidden when only one repo is tracked), a worktree-name field, and a branch-name field.
""", .disabled("not yet implemented"))
    func ios_9_1() async throws { }

    @Test("""
@spec IOS-9.2: Both the worktree-name and branch-name fields shall sanitize input live with `WorktreeNameSanitizer` (same allowed set as the Mac sheet and the web client: `A-Z a-z 0-9 . _ - /`, consecutive disallowed chars collapsing to a single `-`). The branch field shall auto-mirror the worktree-name field until the user types a branch that differs, at which point the mirror breaks and further edits to the worktree field stop overwriting the branch. On submit, both fields shall be trimmed of leading/trailing whitespace plus `-` and `.` (matching the macOS sheet's `submitTrimSet` and the web client's `trimForSubmit`). The sheet's Create button shall be disabled while either field is empty after trim.
""", .disabled("not yet implemented"))
    func ios_9_2() async throws { }

    @Test("""
@spec IOS-9.3: On submit, the application shall issue `POST <baseURL>/worktrees` with `{repoPath, worktreeName, branchName}` and handle the response per the server's status-code contract (`WEB-7.3` / `WEB-7.4`):
""", .disabled("not yet implemented"))
    func ios_9_3() async throws { }

    @Test("""
@spec IOS-9.4: When `GET /repos` returns an empty list, the sheet shall render an empty-state "No repositories tracked — open a repository in Graftty on the Mac first." and shall not show the input fields. The iOS app shall not implement repository-adding (the Mac-side file-picker + security-scoped bookmark mint has no iOS equivalent, same stance as `WEB-7.7`).
""", .disabled("not yet implemented"))
    func ios_9_4() async throws { }

    @Test("""
@spec IOS-9.5: While a `POST /worktrees` call is in flight, the Create button shall be replaced by an in-flight indicator, the Cancel button and both input fields shall be disabled, and the repository picker shall be disabled. Once the call resolves (success or failure) all controls shall re-enable.
""", .disabled("not yet implemented"))
    func ios_9_5() async throws { }
}
