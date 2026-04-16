# Agent-Orchestrator Andy — Dogfood Journal

## Cycle 1 — 2026-04-16

### Explored
- Tried to take screenshots of the Espalier macOS app via `mcp__computer-use__*`. Access was denied with reason `not_installed` — Espalier is a raw SPM executable, not a proper `.app` bundle, so the system doesn't recognize it as an installed application. Filed mentally; tested the CLI instead.
- Tested `.build/arm64-apple-macosx/debug/espalier --help` — hung, produced no output, linked against AppKit/SwiftUI/Metal (not appropriate for a CLI).

### Broke
- **Build system bug:** `swift build` produces two executable products named `Espalier` and `espalier`. On macOS's default case-insensitive APFS, these collide at the same filesystem path. The second link step overwrites the first, so both `espalier` and `Espalier` end up as the same file (same inode, same hash, 10.2MB each). Running `espalier notify` actually launches the SwiftUI app, which explains the hang.
- Evidence: `md5 -r` and `stat -f "%i"` on both binaries returned identical values.

### Fixed
- Renamed the SPM product from `espalier` → `espalier-cli` in `Package.swift`. The target name (`EspalierCLI`) is unchanged. ATTN-1.1 is preserved because it only specifies what the binary is called **when installed into the app bundle** (`Espalier.app/Contents/MacOS/espalier`); app bundling renames the binary during install.
- Updated SPECS.md ATTN-1.1 to document this build-system constraint.

### Verified
- `swift build`: two distinct binaries, `Espalier` 10.2MB and `espalier-cli` 2.9MB, different inodes, different hashes.
- `espalier-cli --help`: prints help in <100ms.
- `espalier-cli notify "hello"` from `/tmp`: errors with "Not inside a tracked worktree", exits 1, in 11ms (previously hung indefinitely).
- `swift test --test-product EspalierPackageTests`: 36/36 tests still pass.

## Cycle 2 — 2026-04-16

### Explored
- Verified the CLI linkage concern from Cycle 1: post-rename, `otool -L .build/.../espalier-cli` shows zero GUI frameworks. Old observation was from the clobbered binary. No action needed.
- Worked on producing a proper `.app` bundle so `computer-use` would recognize Espalier as installed.

### Broke
- **Bundle location bug:** my initial `scripts/bundle.sh` copied the app binary to `Contents/MacOS/Espalier` AND the CLI to `Contents/MacOS/espalier`. On case-insensitive APFS the CLI overwrote the app — after bundling, the "app" binary was actually the 2.9MB CLI. Same case-collision bug as cycle 1, reproduced inside the bundle.
- Evidence: `ls -la .build/Espalier.app/Contents/MacOS/` showed only one file `Espalier` at 2.9MB (should be 10.2MB).

### Fixed
- Changed `scripts/bundle.sh` to put the CLI at `Contents/Helpers/espalier` instead of `Contents/MacOS/espalier`. Only the main app binary goes in `MacOS/` (matches macOS bundle convention — helpers conventionally go elsewhere).
- Updated SPECS.md ATTN-1.1 to specify `Contents/Helpers/espalier` with a written explanation of why.
- Updated `EspalierApp.swift:installCLI()` which had a hardcoded `Contents/MacOS/espalier` path → now points at `Contents/Helpers/espalier`.
- Wrote `scripts/bundle.sh` from scratch — builds via `swift build`, copies binaries into a proper `.app` bundle at `.build/Espalier.app/`, writes a valid Info.plist (passes `plutil -lint`).

### Verified
- `./scripts/bundle.sh` produces a bundle with correct sizes: `Contents/MacOS/Espalier` = 10.2MB (app), `Contents/Helpers/espalier` = 2.9MB (CLI). No collision.
- `open .build/Espalier.app` launches the app process.
- `.build/Espalier.app/Contents/Helpers/espalier notify "test"` from the worktree: 15ms, correct error "Espalier is not running", exit 1.
- `plutil -lint` on the Info.plist: OK.
- `swift test --test-product EspalierPackageTests`: 36/36 pass.

### Still blocked
- `mcp__computer-use__request_access` still returns `not_installed` even after:
  - registering the bundle via `lsregister -f`
  - copying the bundle to `~/Applications/`
  - registering that copy
- Hypothesis: the MCP tool's "installed" check likely requires a code-signed app or placement in `/Applications/` (system-owned path, requires admin). This is an environmental/signing concern, not a code fix.

## Cycle 3 — 2026-04-16

### Explored
- Grepped for `windowFrame` writes. Only the AppState initializer sets it — nothing observes window move/resize. PERSIST-3.4 was silently broken: the saved frame was always the constructor default `(100, 100, 1400, 900)`, so "restoring window frame" on launch always restored defaults.
- PERSIST-2.1 explicitly says "window resize or move (debounced)" — the spec author knew this needed debouncing but the code never implemented it.

### Broke
- Launched bundled app, used AppleScript to set window to `{1000, 700}` at `{100, 100}`, waited, killed the app.
- state.json had the default `windowFrame` (never written), though since state.json is only written on `onChange(of: appState)` and the frame never mutated appState, no save occurred.

### Fixed
- Added `Sources/Espalier/Views/WindowFrameTracker.swift`: an `NSViewRepresentable` that hooks into its host view's `NSWindow` via `viewDidMoveToWindow`, subscribes to `didResizeNotification` and `didMoveNotification`, and reports frame changes with a 250ms debounce via a cancellable `Task.sleep`.
- Added a View extension `.trackWindowFrame(debounceInterval:onChange:)` that wraps the tracker as a `.background()`.
- Wired `MainWindow` to call `.trackWindowFrame { frame in ... }` at the top level: converts the NSWindow frame into a `WindowFrame` value, compares against the current `appState.windowFrame`, and only writes if changed (to avoid feedback loops with the `onChange(of: appState)` save handler).

### Verified
- Clean build with no warnings.
- Manual test: launched bundled app, used AppleScript to resize to 1000×700 at (100, 100). Killed app. state.json contained `windowFrame: {height: 700, width: 1000, x: 100, y: 2208}` — real non-default values. (y is 2208 because NSWindow uses bottom-left origin; 2208 + 700 = 2908 = below screen top, which matches the (100,100) AppleScript top-left position on a large vertical-stitched display.)
- Added two new tests: `windowFrameCustomValuesSurviveSaveAndLoad` (round-trip) and `windowFrameEquatableDistinguishesByValue` (proves the `!=` comparison in the tracker's deduplication works). 38/38 tests pass.

## Cycle 4 — 2026-04-16

### Explored
- Followed up on cycle 3's coordinate concern. Wrote a state.json with a known-good saved frame (x=50, y=50, 800×600) and launched the bundled app. The window appeared at (100, 100) 1000×700 — the old position from cycle 3, NOT the saved values.

### Broke
- **`.defaultPosition(CGPoint)` doesn't exist on macOS 14.** Only `.defaultPosition(UnitPoint)` is available, where UnitPoint expects normalized 0-1 coords. `EspalierApp`'s code passed pixel values (`x=100, y=2208`) which created a silently-invalid UnitPoint — effectively a no-op. So PERSIST-3.4 was still broken even though cycle 3 made windowFrame saving work: it saved fine but the saved values were never applied on restore. The only reason windows came up in approximately-right positions was that macOS's NSWindowRestoration was quietly remembering the last position.
- Bonus latent bug: a saved frame on a disconnected external monitor would normally place the window off-screen with no way to grab it.

### Fixed
- Extended `WindowFrameTracker` to take an `initialFrame: CGRect?` parameter. On first attach to an `NSWindow`, it applies that frame via `window.setFrame(_:display:)` — only if the frame overlaps at least one connected screen by ≥40pt in each dimension (so the title bar is grabbable).
- Added `frameIsVisibleOnAnyScreen(_:)` helper that iterates `NSScreen.screens` and checks `visibleFrame.intersection` against the candidate frame.
- `MainWindow` computes `initialWindowRect`: nil if the saved frame equals `WindowFrame()` defaults (so a first-launch user gets OS-picked placement), otherwise the saved NSRect.
- Removed the broken `.defaultSize(width:height:)` and `.defaultPosition(.init(...))` from `EspalierApp`'s scene. Replaced with a simple `.defaultSize(width: 1400, height: 900)` for first-launch only. Left a comment explaining why pixel position can't be set via `.defaultPosition` on macOS 14.

### Verified
- Clean build.
- Added 7 unit tests (`WindowFrameVisibilityTests`) covering: fully on-screen; entirely off-screen; exact-threshold overlap (40pt); below-threshold overlap (39pt); secondary display; disconnected display; partial overlap too narrow. All 45/45 tests pass.
- Manual test 1: wrote state.json with x=400, y=300, 900×650. Window restored to exactly that size, at AppleScript position (400, 2058) which equals NSWindow bottom-origin (400, 300) + height 650 on the multi-display screen stack. ✓
- Manual test 2: wrote state.json with x=9999, y=9999 (phantom monitor), nuked `~/Library/Saved Application State/com.espalier.app.savedState`, launched. Window did NOT appear at 9999,9999 — it came up at OS-picked (690, 716). ✓ The visibility check correctly rejected the off-screen frame.

## Cycle 5 — 2026-04-16

### Explored
- End-to-end socket test, finally. Launched the bundled app (so socket is live), ran `espalier notify "Build failed"` from this (untracked-by-Espalier) worktree.
- CLI returned exit 0. state.json showed no attention set anywhere. The notification went into the void.

### Broke
- **Spec violation, ATTN-3.2:** the error message says "Not inside a tracked worktree" but the check only verified "inside a git worktree" — it never asked Espalier whether the worktree was actually *tracked*. Any random `.git`-containing directory sailed through. `handleNotification` on the server silently iterated zero worktrees that matched and wrote nothing back. Andy gets no feedback that his notify was a no-op.

### Fixed
- `WorktreeResolver.resolve()` now loads `~/Library/Application Support/Espalier/state.json` via `AppState.load(from: AppState.defaultDirectory)` and calls `state.worktree(forPath: candidate)`. If the resolved worktree isn't present, throw `.notInsideWorktree` (same message, same exit code 1 — matches the spec).
- Extracted `WorktreeResolver.isTracked(path:stateDirectory:)` as a testable helper.

### Verified

| scenario | before fix | after fix |
|---|---|---|
| A: PWD not a git repo | exit 1 "Not inside a tracked worktree" | same |
| B: PWD is a git worktree Espalier doesn't track | **exit 0 silently** | exit 1 "Not inside a tracked worktree" |
| C: PWD tracked, app not running | exit 1 "Espalier is not running" | same |
| D: PWD tracked, app running, notify | exit 0 + attention appears | same |
| E: notify --clear | clears attention | same |

Case D was verified by manually writing a state.json with a single worktree entry, launching the app, running `notify "Build failed"`, then reading state.json back — the attention field was populated with `{text: "Build failed", timestamp: <CF-seconds>}`. Case E: `notify --clear` reset attention to nil. Both round-trip through the socket server → main-thread closure → `appState` mutation → `onChange` save.

Observed as a sanity check: the reconcile pass at startup discovers sibling worktrees via `git worktree list --porcelain` even if state.json only mentions one. The main working tree at `/Users/btucker/projects/espalier` was auto-added alongside my manually-entered dogfood worktree — GIT-3.1 working correctly.

Added 2 unit tests: `cliTrackingCheckRoundTripsThroughStateJSON` (the exact AppState.load → worktree(forPath:) flow the CLI uses) and `cliTrackingCheckReturnsNilForMissingStateJSON` (fresh-install safety: fails closed). 47/47 tests pass.

## Cycle 6 — 2026-04-16

### Explored
- `sidebarWidth` followed the exact broken pattern of the original `windowFrame` before cycle 3: read by `.navigationSplitViewColumnWidth(ideal: appState.sidebarWidth, ...)` but no mechanism to write back when the user dragged the divider. PERSIST-1.2 says state.json contains sidebarWidth, but it was never updated at runtime.

### Broke
- Confirmed by grep: only the AppState initializer ever wrote `sidebarWidth`. No code path observed drag events.

### Fixed
- Added `Sources/Espalier/Views/SidebarWidthPreference.swift`: a `PreferenceKey` (`SidebarWidthKey`) and a `View.publishSidebarWidth()` modifier that wraps a background `GeometryReader` and publishes the view's rendered width. Spurious zero widths (common during SwiftUI layout passes) are filtered out in `reduce`.
- `SidebarView.body` now calls `.publishSidebarWidth()` on its root VStack.
- `MainWindow` subscribes via `.onPreferenceChange(SidebarWidthKey.self)`. Writes debounced at 250ms (same as windowFrame) via a `@State private var pendingSidebarWidthTask: Task<Void, Never>?`. Writes guarded by `!=` check to avoid feedback loops with the `onChange(of: appState)` save handler.
- Why `onGeometryChange`? Because it's macOS 15+; we target macOS 14. A background `GeometryReader` + preference key is the portable SwiftUI-native observation pattern here.

### Verified
- Added `sidebarWidthCustomValueSurvivesSaveAndLoad`. 48/48 tests pass.
- Clean build, no warnings.
- Manual: launched app with state.json `{sidebarWidth: 320}`, saw rendered width measure at 240 (more on this below) and get written back. The observation pipeline fires and updates appState as expected.

### Known limitation (separate follow-up)
- macOS's AppKit has its own `NSSplitView` autosave (via UserDefaults) that restores the last divider position independently of state.json. On a fresh launch, AppKit's restore runs before GeometryReader can measure, so if state.json and the autosave disagree, AppKit's value wins. For normal drag → save → restart → drag workflows both stores stay in sync, but if someone hand-edits state.json the sidebarWidth change won't take effect until they drag the divider.
- Resolving this needs either (a) disabling AppKit's autosave or (b) programmatically setting the NSSplitView divider position from the saved value after launch. Both are non-trivial and out of scope for this cycle.

## Cycle 7 — 2026-04-16

### Explored
- `/usr/local/bin/` is `root:wheel 755` by default — the current user can't write there without sudo. `installCLI()` tries `createSymbolicLink(atPath: "/usr/local/bin/espalier", ...)`, which throws "Permission denied". The existing error handler shows `error.localizedDescription` in a generic "Installation Failed" alert, giving Andy zero actionable next step.

### Broke
- Confirmed: `touch /usr/local/bin/.espalier-write-test` returns "Permission denied" for the current user. Installation from the app alone is impossible without sudo.

### Fixed
- Split the install logic into a pure, testable `CLIInstaller.plan(source:destination:)` in EspalierKit. It returns either:
  - `.directSymlink` — parent dir is writable, proceed as before
  - `.showSudoCommand` — surface a shell-escaped `sudo ln -sf` command
- Added `CLIInstaller.sudoSymlinkCommand(source:destination:)` with shell-safe single-quote escaping (handles the edge case of an app bundle path containing a literal single quote).
- `EspalierApp` now dispatches on the plan:
  - `directSymlink` → existing confirmation flow
  - `showSudoCommand` → new "Administrator Access Required" dialog with: title, body explaining why sudo is needed, a selectable read-only `NSTextField` containing the exact command in monospaced font, and a "Copy Command" button that writes to `NSPasteboard.general`.

### Verified
- Clean build, 53/53 tests pass (+5: `writableParentPlansDirectSymlink`, `unwritableParentPlansSudoCommand`, `sudoCommandWrapsPathsInSingleQuotes`, `sudoCommandEscapesEmbeddedSingleQuotes`, `sudoCommandIsValidShellWhenExecuted` — the last one executes the generated command through `/bin/sh` with `printf` substituted for `sudo ln -sf` and asserts the two shell arguments match the original paths).
- Manual, via AppleScript against the running bundled app: `offerCLIInstallIfNeeded`'s first-launch auto-trigger fires the menu item (had wiped `defaults delete com.espalier.app cliInstallOffered`). The dialog that appears reports exactly:
  - title: "Administrator Access Required"
  - body: "Installing to /usr/local/bin/espalier requires sudo. Copy this command and run it in Terminal:"
  - command: `sudo ln -sf '<bundle>/Contents/Helpers/espalier' '/usr/local/bin/espalier'`
  - buttons: `Copy Command` | `Cancel`
- Clicking Copy Command pastes the correct, escape-clean command to the clipboard. Verified via `pbpaste`.

## Cycle 8 — 2026-04-16

### Explored
- Stale socket cleanup. Wanted to confirm the claimed `unlink(socketPath)`-before-bind behavior handles the kill -9 case. Ran: launch bundled app → `kill -9 <pid>` → relaunch → `espalier notify`. Worked: socket inode changed across restarts (416017475 → 416017533), post-crash notify landed in state.json with the attention field populated. Recovery works.

### Broke (bonus find while writing the regression test)
- **`sockaddr_un.sun_path` truncation bug.** `SocketServer.start()` used `strlcpy(dest, ptr, 104)` to copy the path into `sun_path`. Any path whose UTF-8 length exceeds 103 bytes silently truncates and `bind()` creates the socket at the wrong location. The pre-existing `serverReceivesMessage` test was only passing by accident — both server and client went through the same truncation so they connected at the same corrupted path. My new test wrote a stale seed file at the full path, then found after `server.start()` that the dir contained a file named `te` (test.sock truncated).
- Production path (`~/Library/Application Support/Espalier/espalier.sock`) is 65 bytes for this user, safely under the limit. But a user with a long username (>50 chars) would silently get a broken socket.

### Fixed
- `SocketServer.maxPathBytes` public constant = 103 (accounts for null terminator in 104-byte buffer).
- `SocketServer.start()` now validates `socketPath.utf8.count <= maxPathBytes` before doing anything else, throwing `SocketServerError.socketPathTooLong(bytes:maxBytes:)` on failure.
- Updated the two existing integration tests to use `/tmp/espalier-sock-<8-char-UUID>/s` (short path, ~30 bytes) instead of `FileManager.default.temporaryDirectory` (`/var/folders/sl/...` which is already ~60 bytes before any filename).

### Verified
- Added 2 tests:
  - `startReplacesStaleSocketFile`: seeds a stale regular file at socketPath, calls `start()`, asserts the replaced file is now a socket with a different inode, then sends a message end-to-end to prove the server is actually listening (not just occupying a filename).
  - `startRejectsPathLongerThanSunPath`: calls `start()` with a 104-byte path, asserts it throws `SocketServerError`.
- 55/55 tests pass.

## Cycle 9 — 2026-04-16

### Explored
- Closed the loop on yesterday's cycle-8 finding: `SocketClient.send` in the CLI has the same `strlcpy(..., 104)` pattern that cycle 8 fixed in `SocketServer`. A user who sets `ESPALIER_SOCK=<long-path>` would silently truncate and connect() against the wrong filename — errno `ECONNREFUSED` or `ENOENT` would map to `CLIError.appNotRunning`, giving Andy "Espalier is not running" when actually the configuration is wrong.

### Fixed
- Added `CLIError.socketPathTooLong(bytes:maxBytes:)` with an actionable message that prints the exact byte count and suggests setting `ESPALIER_SOCK` to a shorter path.
- `SocketClient.send` now validates `socketPath.utf8.count <= SocketServer.maxPathBytes` (the public constant introduced in cycle 8) before any socket work. Importing the shared constant from EspalierKit means server and client can't drift.

### Verified
- End-to-end: `ESPALIER_SOCK="/tmp/$(printf 'a%.0s' {1..110})" espalier-cli notify "hello"` → exits 1 with message `espalier: Socket path is 115 bytes, exceeds macOS sockaddr_un limit of 103. Set ESPALIER_SOCK to a shorter path.`
- Happy path: launched bundled app, normal-path `espalier notify "still works"` → exit 0, attention appears in state.json. No regression.
- Added `maxPathBytesMatchesSunPathSizeMinusNull` — a tripwire test that pins the shared constant to 103. If a well-meaning refactor changes the value, server and client would need to agree; the test makes the coupling explicit.
- 56/56 tests pass.

## Cycle 10 — 2026-04-16

### Explored
- `offerCLIInstallIfNeeded` sets `UserDefaults[cliInstallOffered] = true` BEFORE the `asyncAfter` closure fires. If the app terminates during that 1-second window (rapid Cmd-Q, SIGKILL, crash), the defaults flag is set but the dialog was never presented. User never gets the offer again, silently violating ATTN-4.1 ("on first launch, the application shall offer...").

### Broke
- Repro: deleted the defaults flag, launched bundled app, let SwiftUI boot (~1s), then SIGKILL at t=1.2s (after scheduling, before the 1s asyncAfter closure fired). Flag was 1 afterwards despite no dialog ever appearing. Used a `/tmp/espalier-offer-trace` sentinel file to pinpoint when the closure ran; confirmed the pre-fix code burned the one-shot offer on rapid quits.

### Fixed
- Moved the `defaults.set(true, forKey: "cliInstallOffered")` call INSIDE the asyncAfter closure. Added a `guard NSApp.isRunning else { return }` check inside the closure as defense-in-depth — if the app is shutting down but the main queue still drains pending tasks, don't pop a modal against a dying window.
- Kept the already-installed shortcut (symlink exists → set flag and return synchronously). That case doesn't have the race because no async work happens.

### Verified
- Scenario A: kill at t=1.2s (inside the delay window) → flag stays "does not exist" → next launch will offer again.
- Scenario B: wait for dialog, click Cancel → flag = 1 → next launch won't re-prompt.
- 56/56 tests pass.
- Build is clean.

## Cycle 11 — 2026-04-16

### Explored
- First-launch window size. I expected 1400×900 per `.defaultSize(width: 1400, height: 900)` on the WindowGroup scene. Actual: 472×312. Scene-level `.defaultSize` is ignored when NavigationSplitView's detail has an intrinsic size (e.g. `ContentUnavailableView`). Same story for the "saved frame off-screen" fallback path (cycle 4) — tracker correctly refused the bad frame but then the window got the same 472×312 minimum.

### Broke
- Repro: nuked `~/Library/Application Support/Espalier/state.json` and `~/Library/Saved Application State/com.espalier.app.savedState/`, launched the bundled app. Got 472×312. Disgusting for a first impression; Andy would close it on reflex.

### Fixed
- Rewrote `MainWindow.initialWindowRect` to always return a valid CGRect (never nil). Priority ladder:
  1. Saved frame, if visible on any attached screen → apply as-is.
  2. Otherwise → center the `WindowFrame()` default (1400×900) on `NSScreen.main?.visibleFrame`.
- The centering math uses `screen.visibleFrame` not `screen.frame`, so the window sits below the menu bar and above the Dock rather than overlapping them.
- Leverages the existing `WindowFrameTracker.Coordinator.frameIsVisibleOnAnyScreen(_:)` static helper to validate the saved frame before accepting it. Keeps the cross-monitor-unplugged guard from cycle 4 but moves the *decision* into MainWindow where it can also supply the fallback rect. The tracker still has its own internal visibility check (defensive, harmless).

### Verified
| case | saved state | expected window | got |
|---|---|---|---|
| A. first launch | none | 1400×900 centered | 1400×900 at (120, 1069) ✓ |
| B. saved on-screen | (300, 400, 1000×700) | 1000×700 at saved pos | 1000×700 at (300, 1908) ✓ |
| C. saved off-screen | (9999, 9999, 900×650) | 1400×900 centered default | 1400×900 ✓ |

- 56/56 tests pass, build clean.

## Cycle 12 — 2026-04-16

### Explored
- User launched the app fresh and hit the "Administrator Access Required" dialog immediately — Andy was trying to open a worktree and got a sudo-prompt detour before even seeing the main UI. The `offerCLIInstallIfNeeded` auto-offer from cycle 10 was firing, and because `/usr/local/bin` needs sudo, that path went to `showSudoInstallAlert` (cycle 7). The dialog is technically correct, but it's gate-keeping the first-run experience for a completely optional feature.

### Fixed
- Removed the `offerCLIInstallIfNeeded` function and its call site from `startup()`. The menu item (`Espalier -> Install CLI Tool...`) is still there for users who explicitly want PATH integration.
- Updated SPECS.md: ATTN-4.1 now says CLI installation is opt-in via the menu. ATTN-4.2 merged into 4.1 since the menu was the only remaining path. The old "on first launch, the application shall offer..." language is gone; auto-prompting was strictly worse than menu-on-demand.

### Gotcha
- After removing the function, the dialog STILL appeared on relaunch. The binary at `~/Applications/Espalier.app` was stale — incremental SwiftPM build + a previous `cp` hadn't rippled through. Had to `touch` the source file to force a rebuild, nuke `.build/Espalier.app`, re-run the bundling script, then re-install. `strings` on the binary grepped for `cliInstallOffered` went from 1 → 0 after the clean cycle.

### Verified
- Fresh launch with cleaned state.json + cleaned `Saved Application State` + cleaned defaults: single window, title "Espalier", no modal dialog.
- 56/56 tests still pass; build clean.

## Cycle 13 — 2026-04-16

### Explored
- User launched the app and asked: "what does '(detached)' mean in the sidebar?" Opaque git-speak was leaking into the UI because `GitWorktreeDiscovery` passes the literal `detached` / `bare` sentinels through as branch labels.
- Followed up: "perhaps it should be the name of the worktree, not the name of the branch?"
- Follow-up #2: "I don't think it's going to work to only use the final directory part of the worktree path as the name. because then there are collisions" — which was the state we hit when both worktrees (main at `/Users/btucker/projects/blindspots` and a Codex-created one at `/Users/btucker/.codex/worktrees/6750/blindspots`) ended in the same last component.

### Fixed
- Added `WorktreeEntry.displayName(amongSiblingPaths:)` — returns the last path component by default; when a sibling in the same repo has the same last component, falls back to `parent/last` to disambiguate. Empty-path fallback returns the branch name.
- `SidebarView.repoSection` computes `repo.worktrees.map(\.path)` once and passes the resolved label to `WorktreeRow`.
- `WorktreeRow` now takes `displayName: String` as a property and renders `<displayName> <dim branch>` in an `HStack`, skipping the branch piece when it equals `displayName`. Stale-worktree strikethrough styling preserved.

### Verified
- 59/59 tests pass. Added 3 tests (`displayNameUsesLastComponentWhenUnique`, `displayNameDisambiguatesCollisionsWithParent`, `displayNameFallsBackToBranchWhenPathIsEmpty`). The collision test mirrors Andy's exact dogfood state.
- Deployed `~/Applications/Espalier.app`, screenshot shows two visually-distinct rows: "projects/blindsp… main" and "6750/blinds… (detached)" with the branch piece dimmed. Both uniquely identifiable even when truncated.

### Follow-up (same cycle, per user feedback)
- User: "let's special case the main checkout of the repo" + "maybe a different symbol for the main checkout & the worktrees?"
- For the main checkout (`path == repo.path`), sidebar label is now just the branch name (no disambiguated "projects/blindspots" noise). Linked worktrees keep the collision-aware label.
- Added a leading SF Symbol to `WorktreeRow`: `house` for the main checkout, `arrow.triangle.branch` for linked worktrees. Subtle but instantly distinguishes the canonical source from ephemeral branch workspaces.
- `SidebarView.label(for:in:)` helper special-cases main; computed once per worktree and handed to `WorktreeRow` along with an `isMainCheckout: Bool`.
- Deployed. Screenshot confirms clean layout: main checkout shows as "🏠 main", linked worktrees show as "🌿 6750/bli… (detached)".

### Separately observed (noted for next cycle)
- AppleScript `keystroke` sends to the frontmost process, but keystrokes don't appear to reach the libghostty `NSTextInputClient` surface — the terminal prompt stayed unchanged despite sending `echo hello`. Real user keyboard input works (the prompt is visible and running). This is a test/automation limitation, not a product bug.
- The sidebar labels truncate at narrow widths. Full paths would be useful in a tooltip / popover. Polish item.

### Try next cycle
- NSSplitView autosave vs state.json sovereignty.
- Tooltip or popover with full worktree path.
- The socket server's `handleClient` does a blocking `read` loop — slow clients could starve others.
- No `applicationWillTerminate` save belt-and-suspenders.
