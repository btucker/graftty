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

### Try next cycle
- `sidebarWidth` has the same "never written" bug as the original windowFrame: `.navigationSplitViewColumnWidth(ideal: appState.sidebarWidth, ...)` reads it, but dragging the sidebar divider doesn't update it.
- The fallback window from cycle 4 came up at 260×234. Something is undersizing the window when the saved frame is rejected. Investigate whether `.defaultSize` is being honored at all.
- `Install CLI Tool...` menu — what happens when `/usr/local/bin/` write fails without admin? Expect the fix to need `NSWorkspace.open` for authorization or a sudo-prompting helper.
- Stale socket file: kill -9 the app, check that the next launch cleanly removes the old socket. `SocketServer.start` calls `unlink(socketPath)` first, so this should work — but unverified.
- Race in `offerCLIInstallIfNeeded`: uses `DispatchQueue.main.asyncAfter(deadline: .now() + 1)` to delay the prompt. If the app quits within that second, the prompt fires against a dying window. Trivial but worth fixing.
