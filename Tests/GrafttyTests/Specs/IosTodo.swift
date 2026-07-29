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
@spec IOS-1.4: While the iOS application is installed, it shall appear on the home screen and in the app switcher as "Graftty" (via `CFBundleDisplayName`) and shall use the same app icon as the macOS application, sourced from the shared master `Resources/AppIcon.png`. The Xcode target, `.xcodeproj`, on-disk sources directory, and bundle identifier keep the `GrafttyMobile` name internally so `Bundle.main.bundleIdentifier` checks, keychain service strings, and the `GrafttyMobileKit` SPM target continue to work unchanged — "GrafttyMobile" is the codebase's internal handle, "Graftty" is the user-facing brand on both platforms.
""", .disabled("not yet implemented"))
    func ios_1_4() async throws { }

    @Test("""
@spec IOS-2.4: For compatibility with older mobile clients, the macOS application's Web Access settings may continue to render its Web Base URL as a scannable QR code alongside the copy/open actions (`WEB-1.12`). Current GrafttyMobile onboarding shall use authenticated device pairing (`IOS-2.1`) and shall not require Web Access.
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
@spec IOS-4.1: When the user selects a paired Mac, the application shall consume its authenticated panes-state channel and render the snapshot as a **worktree** picker grouped by `WorktreePanes.repoDisplayName` (one row per running worktree, not one row per pane). The mobile flow remains drill-down — worktree → pane tree → single pane.
""", .disabled("not yet implemented"))
    func ios_4_1() async throws { }

    @Test("""
@spec IOS-4.3: When the user selects a pane, the application shall open that pane's terminal subsystem over the mutually authenticated paired connection and attach its byte stream to an `InMemoryTerminalSession` from `libghostty-spm` rendered by `GhosttyTerminal.TerminalView`.
""", .disabled("not yet implemented"))
    func ios_4_3() async throws { }

    @Test("""
@spec IOS-4.4: When the selected terminal transport supports owner-aware control frames, the application shall send an initial `hello` containing a fresh iOS display client ID, kind `.ios`, role `.interactive` for fullscreen panes or `.preview` for pane previews, visibility, and the last measured viewport grid. The authenticated terminal subsystem may use its direct resize protocol.
""", .disabled("not yet implemented"))
    func ios_4_4() async throws { }

    @Test("""
@spec IOS-4.5: Binary bytes received from the authenticated terminal subsystem shall be forwarded to `InMemoryTerminalSession.receive(_:)` unmodified. User input emitted by libghostty via the `writeHandler` callback shall be sent back through the same authenticated terminal byte stream.
""", .disabled("not yet implemented"))
    func ios_4_5() async throws { }

    @Test("""
@spec IOS-4.6: On subsequent fullscreen terminal resizes (viewport change, keyboard appearance, rotation), the application shall memoize the local viewport immediately. If and only if the current ownership snapshot confirms this iOS client as display owner, it shall send `ownerResize(clientID, epoch, cols, rows)`; follower, ownerless, and preview clients shall not resize the remote PTY. Legacy/non-web-control transports may still use their direct resize protocol for compatibility.
""", .disabled("not yet implemented"))
    func ios_4_6() async throws { }

    @Test("""
@spec IOS-4.7: When the user selects a paired Mac, the application shall request `hostPresentation` over the authenticated worktree-management channel and pass a non-empty Ghostty config to `TerminalController.shared.updateConfigSource(.generated(text))` before mounting a `TerminalPaneView`. A missing or empty config is non-fatal and falls back to `libghostty-spm` defaults. The response also carries the Mac's resolved keybindings so terminals mirror desktop presentation without Web Access.
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
@spec IOS-4.11: When the user taps a pane tile, the application shall open a fullscreen terminal view for that session — a single `TerminalPaneView` with the navigation bar hidden and the terminal extending beneath the top safe area (`IOS-4.8`). The authenticated terminal channel is opened on view appear and closed on view disappear; system edge-swipe-back returns to the worktree detail.
""", .disabled("not yet implemented"))
    func ios_4_11() async throws { }

    @Test("""
@spec IOS-5.4: When multiple panes exist, only one pane shall be focused at a time. The keyboard accessory bar and hardware keyboard routing shall deliver input only to the focused pane.
""", .disabled("not yet implemented"))
    func ios_5_4() async throws { }

    @Test("""
@spec IOS-5.5: While a session's terminal is rendered full-screen (navigation bar hidden per the fullscreen layout), the application shall overlay a translucent back-button in the top-left that pops the current session off the `NavigationPath`, returning the user to the worktree detail they drilled in from. The button shall be rendered as a chevron inside an `.ultraThinMaterial` circle at a fixed 44×44pt tap target, padded 12pt from the top and leading edges so it floats above the terminal content without being clipped by the device's notch / rounded corners. The system edge-swipe gesture remains available but is not discoverable, so this overlay is the primary affordance.
""", .disabled("not yet implemented"))
    func ios_5_5() async throws { }

    @Test("""
@spec IOS-6.1: While the software keyboard is visible, the application shall render a compact terminal control bar above the keyboard. The v1 bar shall expose, at minimum: Esc, Tab, Ctrl-C, Ctrl-D, ↑, ↓, ←, →, submit Return, insert literal LF, and Hide Keyboard. These controls shall send explicit PTY bytes through `SessionClient` rather than relying on UIKit text entry: Esc=`0x1B`, Tab=`0x09`, Ctrl-C=`0x03`, Ctrl-D=`0x04`, arrows=`ESC [ A/B/D/C`, submit Return=`0x0D`, and literal LF=`0x0A`.
""", .disabled("not yet implemented"))
    func ios_6_1() async throws { }

    @Test("""
@spec IOS-8.1: The v1 iOS app shall not support connecting to non-Graftty SSH/mosh hosts.
""", .disabled("not yet implemented"))
    func ios_8_1() async throws { }

    @Test("""
@spec IOS-8.2: The v1 iOS app shall not forward terminal mouse events, OSC 52 clipboard reads, or Kitty graphics/keyboard-protocol sequences. (Mirrors `WEB-6.2`.)
""", .disabled("not yet implemented"))
    func ios_8_2() async throws { }

    @Test("""
@spec IOS-8.4: The v1 iOS app shall not persist terminal scrollback on the device. On reconnect, it renders whatever the zmx daemon's buffer still contains.
""", .disabled("not yet implemented"))
    func ios_8_4() async throws { }

    @Test("""
@spec IOS-8.5: The v1 iOS app shall not use push notifications for PR status, build completions, or session events.
""", .disabled("not yet implemented"))
    func ios_8_5() async throws { }

    @Test("""
@spec IOS-9.1: The worktree-picker screen (`IOS-4.1`) shall display an "Add Worktree" action as a primary toolbar item. Tapping it shall present a modal sheet collecting the fields required by the authenticated `.createWorktree` request: a repository picker populated by `.listRepositories` (hidden when only one repo is tracked), a worktree-name field, and a branch-name field.
""", .disabled("not yet implemented"))
    func ios_9_1() async throws { }

    @Test("""
@spec IOS-9.2: Both the worktree-name and branch-name fields shall sanitize input live with `WorktreeNameSanitizer` (same allowed set as the Mac sheet and the web client: `A-Z a-z 0-9 . _ - /`, consecutive disallowed chars collapsing to a single `-`). The branch field shall auto-mirror the worktree-name field until the user types a branch that differs, at which point the mirror breaks and further edits to the worktree field stop overwriting the branch. On submit, both fields shall be trimmed of leading/trailing whitespace plus `-` and `.` (matching the macOS sheet's `submitTrimSet` and the web client's `trimForSubmit`). The sheet's Create button shall be disabled while either field is empty after trim.
""", .disabled("not yet implemented"))
    func ios_9_2() async throws { }

    @Test("""
@spec IOS-9.3: On submit, the application shall send `.createWorktree(repositoryID, worktreeName, branchName)` over the authenticated worktree-management channel and handle structured success or failure responses:
""", .disabled("not yet implemented"))
    func ios_9_3() async throws { }

    @Test("""
@spec IOS-9.4: When `.listRepositories` returns an empty list, the sheet shall render an empty-state "No repositories tracked — open a repository in Graftty on the Mac first." and shall not show the input fields. The iOS app shall not implement repository-adding (the Mac-side file-picker + security-scoped bookmark mint has no iOS equivalent).
""", .disabled("not yet implemented"))
    func ios_9_4() async throws { }

    @Test("""
@spec IOS-9.5: While an authenticated `.createWorktree` request is in flight, the Create button shall be replaced by an in-flight indicator, the Cancel button and both input fields shall be disabled, and the repository picker shall be disabled. Once the request resolves (success or failure) all controls shall re-enable.
""", .disabled("not yet implemented"))
    func ios_9_5() async throws { }

}
