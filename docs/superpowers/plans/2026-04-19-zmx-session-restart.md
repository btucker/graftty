# zmx Session Restart Recovery — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Detect zmx session loss at the two moments Espalier touches zmx (cold-start surface creation, libghostty close-callback) and recover with one shared mechanism — no pane disappears just because a daemon died.

**Architecture:** Add one detection helper (`ZmxLauncher.isSessionMissing(_:)`), one piece of TerminalManager state (`intentionalCloses` populated by `killZmxSession`), and two effects: clear the `wasRehydrated` label on cold-start when the daemon is dead (so the default command runs), and rebuild the surface in place on mid-flight death (so the pane stays).

**Tech Stack:** Swift 6, Swift Testing (`@Test`), XCTest legacy in some files, `@MainActor` isolation for TerminalManager, libghostty C bridge via GhosttyKit.

**Spec:** `docs/superpowers/specs/2026-04-19-zmx-session-restart-design.md`

---

## File Structure

| File | Disposition | Responsibility |
| ---- | ----------- | -------------- |
| `Sources/EspalierKit/Zmx/ZmxLauncher.swift` | Modify | Add `isSessionMissing(_:)` wrapping `listSessions()` |
| `Sources/EspalierKit/Zmx/SessionRestartBanner.swift` | Create | Pure function: timestamp → banner string for `initial_input` |
| `Sources/Espalier/Terminal/TerminalManager.swift` | Modify | Add `intentionalCloses`, `clearRehydrated`, `restartSurface`, `shouldRestartInsteadOfClose`; populate `intentionalCloses` from `killZmxSession`; check + clear in `createSurface(s)` |
| `Sources/Espalier/EspalierApp.swift` | Modify | Route `onCloseRequest` through `shouldRestartInsteadOfClose` to decide destroy vs restart |
| `Tests/EspalierKitTests/Zmx/ZmxLauncherTests.swift` | Modify | Unit tests for `isSessionMissing` |
| `Tests/EspalierKitTests/Zmx/SessionRestartBannerTests.swift` | Create | Pure unit tests for banner formatting |
| `Tests/EspalierKitTests/Zmx/ZmxSurvivalIntegrationTests.swift` | Modify | Integration test for `isSessionMissing` against real zmx |
| `SPECS.md` | Modify | Add §13.7 (ZMX-7.1 — ZMX-7.4); amend ZMX-4.3 |

The `SessionRestartBanner` lives in `EspalierKit/Zmx/` rather than at the EspalierKit root because it's a zmx-survival concern; co-locating with `ZmxLauncher` keeps the surface cohesive.

The split between TerminalManager and EspalierApp matches the existing pattern: TerminalManager exposes capabilities (`restartSurface`, `shouldRestartInsteadOfClose`); EspalierApp's `startup()` closure picks the policy (destroy vs restart). This mirrors `onCloseRequest` → `closePane` and `onSplitRequest` → `splitPane`.

---

## Task 1: Add `isSessionMissing(_:)` to `ZmxLauncher`

**Files:**
- Modify: `Sources/EspalierKit/Zmx/ZmxLauncher.swift` (after `listSessions()` near line 213)
- Test: `Tests/EspalierKitTests/Zmx/ZmxLauncherTests.swift` (add a `MARK: isSessionMissing` block at the end of the suite)

- [ ] **Step 1: Write failing tests**

Append to `Tests/EspalierKitTests/Zmx/ZmxLauncherTests.swift`, just inside the `}` that closes the test struct:

```swift
    // MARK: isSessionMissing
    //
    // The fail-safe direction is "not missing" — if `listSessions` itself
    // throws (e.g., binary missing), every other zmx interaction is
    // already broken, so flagging panes as session-lost would only
    // amplify the failure into spurious restart cycles. These tests lock
    // that bias.

    @Test func isSessionMissingTrueWhenAbsent() throws {
        // Use a launcher whose listSessions() returns an empty set: the
        // binary is missing → isAvailable is false → listSessions returns []
        // → any name is "missing".
        let launcher = ZmxLauncher(
            executable: URL(fileURLWithPath: "/nonexistent/path/zmx")
        )
        #expect(launcher.isSessionMissing("espalier-aaaa1111") == false)
        // ^ binary missing means listSessions returns [] without throwing
        // (per its `guard isAvailable else { return [] }` clause). Empty
        // set → not missing? No — empty set means we observed zero
        // sessions, which means the named one is genuinely absent.
        // The current behavior (returns []) makes "not missing" the
        // safe answer when nothing else can tell us. We assert that
        // contract here.
    }

    @Test func isSessionMissingHandlesEmptyName() throws {
        let launcher = ZmxLauncher(
            executable: URL(fileURLWithPath: "/nonexistent/path/zmx")
        )
        // Empty session name still goes through the same "not missing"
        // safe-default path when listSessions() can't run.
        #expect(launcher.isSessionMissing("") == false)
    }
```

Wait — re-read the spec: the contract is **"returns false on any query failure."** And `listSessions()` returns `[]` when `isAvailable` is false (line 207–208 of `ZmxLauncher.swift`), without throwing. So when the binary is missing, `listSessions` returns `[]`, and `contains(name)` would say "not present, so it IS missing." But the spec wants the opposite — "binary unavailable ⇒ assume not missing."

Resolve by making `isSessionMissing` short-circuit: if `!isAvailable`, return `false`. Update the test to reflect the contract:

Replace the test block above with:

```swift
    // MARK: isSessionMissing
    //
    // The fail-safe direction is "not missing": if zmx itself can't tell
    // us what's alive (binary unavailable, subprocess threw), we don't
    // want to fabricate session-loss events that would trigger spurious
    // restarts. These tests lock that contract.

    @Test func isSessionMissingFalseWhenBinaryUnavailable() throws {
        let launcher = ZmxLauncher(
            executable: URL(fileURLWithPath: "/nonexistent/path/zmx")
        )
        // Binary missing — no way to query — return "not missing" so
        // callers don't react to a pseudo-loss.
        #expect(launcher.isSessionMissing("espalier-aaaa1111") == false)
    }

    @Test func isSessionMissingTrueWhenAbsentFromListSessions() throws {
        // Build a launcher where isAvailable is true but listSessions
        // returns a set NOT containing the queried name. We can't easily
        // mock listSessions; cover this path in the integration tests
        // (next task). Here, just verify the helper exists and the
        // empty-name edge case doesn't crash.
        let launcher = ZmxLauncher(executable: URL(fileURLWithPath: "/bin/sh"))
        // /bin/sh is executable, so isAvailable is true; listSessions
        // will throw because /bin/sh isn't zmx. The catch arm returns
        // false (= not missing). Locks the throw → false bias.
        #expect(launcher.isSessionMissing("anything") == false)
    }
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
swift test --filter ZmxLauncherTests.isSessionMissingFalseWhenBinaryUnavailable 2>&1 | tail -20
```

Expected: compile error — `isSessionMissing` not defined on `ZmxLauncher`.

- [ ] **Step 3: Add `isSessionMissing` to `ZmxLauncher`**

In `Sources/EspalierKit/Zmx/ZmxLauncher.swift`, immediately after `listSessions()` (around line 213), insert:

```swift
    /// Whether the zmx daemon for the given session name is *known to be
    /// absent* from our `ZMX_DIR`. Returns `false` (i.e., "not missing")
    /// on any query failure — when zmx itself can't answer, we bias
    /// toward not fabricating a session-loss event, since spurious
    /// restarts are visible to the user and missed restarts are not.
    ///
    /// Use at the two moments Espalier touches zmx for a specific pane:
    /// before creating a surface for a rehydrated pane (cold-start
    /// daemon-loss detection), and inside the close-surface handler
    /// (mid-flight daemon-loss detection).
    public func isSessionMissing(_ sessionName: String) -> Bool {
        guard isAvailable else { return false }
        guard let sessions = try? listSessions() else { return false }
        return !sessions.contains(sessionName)
    }
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
swift test --filter ZmxLauncherTests.isSessionMissing 2>&1 | tail -20
```

Expected: both tests PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/EspalierKit/Zmx/ZmxLauncher.swift Tests/EspalierKitTests/Zmx/ZmxLauncherTests.swift
git commit -m "$(cat <<'EOF'
feat(zmx): add isSessionMissing helper for session-loss detection

Wraps listSessions() with the "fail-safe to not-missing" bias so that
transient zmx unavailability does not cascade into spurious pane
restarts.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: Integration test for `isSessionMissing` against real zmx

**Files:**
- Test: `Tests/EspalierKitTests/Zmx/ZmxSurvivalIntegrationTests.swift` (add a new `@Test` near the end of the suite)

- [ ] **Step 1: Write failing test**

Append to `Tests/EspalierKitTests/Zmx/ZmxSurvivalIntegrationTests.swift`, inside the `struct ZmxSurvivalIntegrationTests`:

```swift
    @Test func isSessionMissingFlipsAfterKill() throws {
        try Self.withScopedZmxDir { launcher in
            let name = "espalier-detect1"
            // Create a session by spawning a noop-ish attach via PTY
            // (mirroring the helper used elsewhere in this suite).
            let pty = try Self.spawnAttach(launcher: launcher, sessionName: name)
            defer { _ = try? pty.terminate() }

            // Wait briefly for the daemon to register.
            try Self.waitForSession(launcher: launcher, name: name, timeout: 2.0)

            #expect(launcher.isSessionMissing(name) == false)

            launcher.kill(sessionName: name)
            // listSessions should now omit the killed name. Poll for up
            // to a second to absorb the daemon's exit latency.
            let deadline = Date().addingTimeInterval(1.0)
            while Date() < deadline {
                if launcher.isSessionMissing(name) { break }
                Thread.sleep(forTimeInterval: 0.05)
            }
            #expect(launcher.isSessionMissing(name) == true)
        }
    }
```

If the suite does not already have `spawnAttach` and `waitForSession` helpers with these signatures, inspect the file's existing helpers and adapt — the existing `PtyAttach` struct (line ~67) is the building block. If a `spawnAttach`-like helper does not exist as a top-level static, factor one out from the existing tests' setup to keep the new test honest about what it's exercising:

```swift
    static func spawnAttach(launcher: ZmxLauncher, sessionName: String) throws -> PtyAttach {
        // Open a PTY pair; spawn `zmx attach <name> /bin/sh` against
        // the slave; return the master fd + Process. The shell stays
        // alive (no `exit` typed) so the session is real. Caller is
        // responsible for terminate().
        // Body: copy from the existing PTY-spawning test's setup.
        fatalError("Implement by extracting the existing PTY-spawn pattern in this file")
    }

    static func waitForSession(launcher: ZmxLauncher, name: String, timeout: TimeInterval) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let names = try? launcher.listSessions(), names.contains(name) { return }
            Thread.sleep(forTimeInterval: 0.05)
        }
        throw NSError(domain: "ZmxSurvivalIntegrationTests", code: 1,
                      userInfo: [NSLocalizedDescriptionKey:
                                 "session \(name) did not appear within \(timeout)s"])
    }
```

When extracting, keep the `withScopedZmxDir` helper unchanged — it owns the lifecycle.

- [ ] **Step 2: Run test to verify it fails (or compiles + passes if helpers exist)**

```bash
swift test --filter ZmxSurvivalIntegrationTests.isSessionMissingFlipsAfterKill 2>&1 | tail -30
```

Expected: PASS (this test exercises the new code from Task 1, which is already correct). If it fails, the failure points at one of: real zmx behavior differing from what the spec assumed (investigate before forcing the test green), or the helpers being misused.

- [ ] **Step 3: Commit**

```bash
git add Tests/EspalierKitTests/Zmx/ZmxSurvivalIntegrationTests.swift
git commit -m "$(cat <<'EOF'
test(zmx): integration test for isSessionMissing against real daemon

Spawns a real zmx session via PTY, kills it, and verifies
isSessionMissing flips false → true within the daemon's exit latency.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: Pure-function `SessionRestartBanner` for the in-pane banner

**Files:**
- Create: `Sources/EspalierKit/Zmx/SessionRestartBanner.swift`
- Test: `Tests/EspalierKitTests/Zmx/SessionRestartBannerTests.swift`

- [ ] **Step 1: Write failing test**

Create `Tests/EspalierKitTests/Zmx/SessionRestartBannerTests.swift`:

```swift
import Testing
import Foundation
@testable import EspalierKit

@Suite("SessionRestartBanner")
struct SessionRestartBannerTests {

    /// The banner is the bytes Espalier prepends to a rebuilt pane's
    /// initial_input so the user sees a visible marker that the
    /// underlying zmx session was replaced. We test the pure formatter
    /// here; placement into initial_input is exercised by integration
    /// tests of the rebuild path.

    @Test func bannerWrapsTimestampInDimAnsi() {
        // 14:23 (2:23 PM)
        let date = Self.dateAt(hour: 14, minute: 23)
        let banner = sessionRestartBanner(at: date)
        // Must contain the timestamp formatted as HH:MM (zero-padded).
        #expect(banner.contains("14:23"))
        // Must use ANSI dim (\033[2m) and reset (\033[0m) around the message.
        #expect(banner.contains("\u{1B}[2m"))
        #expect(banner.contains("\u{1B}[0m"))
    }

    @Test func bannerEndsWithExecutableNewline() {
        let banner = sessionRestartBanner(at: Self.dateAt(hour: 9, minute: 5))
        // The very last byte must be '\n' so the outer shell executes
        // the printf line — without it the line sits in the input buffer
        // and the user would have to press Enter.
        #expect(banner.last == "\n")
    }

    @Test func bannerInvokesPrintfNotEcho() {
        // Portability requirement: the banner must work in bash, zsh,
        // and fish. Command substitution syntax differs across shells;
        // printf doesn't. Lock that printf is what we emit.
        let banner = sessionRestartBanner(at: Self.dateAt(hour: 0, minute: 0))
        #expect(banner.hasPrefix("printf "))
    }

    @Test func bannerZeroPadsSingleDigitHourAndMinute() {
        // 09:05, not 9:5 — terminal columns line up better and matches
        // the spec's HH:MM format.
        let banner = sessionRestartBanner(at: Self.dateAt(hour: 9, minute: 5))
        #expect(banner.contains("09:05"))
    }

    private static func dateAt(hour: Int, minute: Int) -> Date {
        var comps = DateComponents()
        comps.year = 2026
        comps.month = 4
        comps.day = 19
        comps.hour = hour
        comps.minute = minute
        // Use the current calendar so the formatter inside the function,
        // which also uses the current calendar's HH:MM, agrees with us.
        return Calendar.current.date(from: comps)!
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
swift test --filter SessionRestartBannerTests 2>&1 | tail -20
```

Expected: compile error — `sessionRestartBanner` and source file don't exist.

- [ ] **Step 3: Create the banner module**

Create `Sources/EspalierKit/Zmx/SessionRestartBanner.swift`:

```swift
import Foundation

/// Bytes Espalier prepends to a rebuilt pane's `initial_input` so the
/// user sees a visible marker that the underlying zmx session has been
/// replaced. Intended to be concatenated *before* the existing
/// `exec zmx attach …` line.
///
/// Shape: `printf '\n\033[2m— session restarted at HH:MM —\033[0m\n'\n`
///
/// We deliberately use `printf` (not `echo -e`, not `$(date …)`) for
/// portability — the outer shell that interprets this banner can be
/// bash, zsh, or fish, and only `printf` behaves identically across all
/// three. The timestamp is computed in Swift and embedded as a literal
/// so we do not need command substitution at all.
///
/// ANSI dim (`\033[2m`) + reset (`\033[0m`) wrap the message so it is
/// visually distinct from real shell output without being noisy.
public func sessionRestartBanner(at date: Date) -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "HH:mm"
    let stamp = formatter.string(from: date)
    // Use \u{1B} (ESC, 0x1B) explicitly rather than \033, then let
    // printf re-emit the literal escape sequence the terminal will
    // interpret. The format string itself is single-quoted so the
    // shell does not interpret anything.
    return "printf '\\n\\033[2m— session restarted at \(stamp) —\\033[0m\\n'\n"
}
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
swift test --filter SessionRestartBannerTests 2>&1 | tail -20
```

Expected: all four tests PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/EspalierKit/Zmx/SessionRestartBanner.swift Tests/EspalierKitTests/Zmx/SessionRestartBannerTests.swift
git commit -m "$(cat <<'EOF'
feat(zmx): pure-function banner for restarted sessions

Emits a portable printf line that the rebuilt pane's outer shell will
echo before exec'ing into a fresh zmx attach. printf (not echo -e or
$(date)) keeps the line working under bash, zsh, and fish.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: TerminalManager — `intentionalCloses` tracking + `clearRehydrated`

**Files:**
- Modify: `Sources/Espalier/Terminal/TerminalManager.swift`

- [ ] **Step 1: Add the state and the clear method**

In `Sources/Espalier/Terminal/TerminalManager.swift`, just below the existing `private var rehydratedSurfaces: Set<TerminalID> = []` declaration (around line 49), insert:

```swift
    /// Terminal IDs whose close was initiated by Espalier — user Cmd+W,
    /// shell-driven exit propagation, Stop-worktree. Consulted by the
    /// close handler to distinguish "we wanted this gone" from
    /// "the daemon died underneath us." Populated by `killZmxSession`
    /// (which is the single funnel for every Espalier-initiated kill)
    /// and consumed by `shouldRestartInsteadOfClose`.
    private var intentionalCloses: Set<TerminalID> = []
```

Then below `markRehydrated` (around line 388), add:

```swift
    /// Drop the rehydration label for a terminal. Called by the cold-
    /// start session-loss check in `createSurface(s)` when the pane's
    /// expected zmx session is absent — a freshly-spawned daemon should
    /// not be treated as "the previous session" by
    /// `defaultCommandDecision`.
    func clearRehydrated(_ terminalID: TerminalID) {
        rehydratedSurfaces.remove(terminalID)
    }
```

- [ ] **Step 2: Populate `intentionalCloses` from `killZmxSession`**

In `Sources/Espalier/Terminal/TerminalManager.swift`, modify `killZmxSession` (around line 448) to insert into `intentionalCloses` as its first action:

```swift
    private func killZmxSession(for terminalID: TerminalID) {
        // First, mark this close as intentional so the imminent
        // close_surface_cb is not misclassified as a session-loss event
        // by `shouldRestartInsteadOfClose`. Membership is consumed
        // there.
        intentionalCloses.insert(terminalID)

        guard let launcher = zmxLauncher, launcher.isAvailable else { return }
        let name = launcher.sessionName(for: terminalID.id)
        DispatchQueue.global(qos: .utility).async {
            launcher.kill(sessionName: name)
        }
    }
```

- [ ] **Step 3: Clean up `intentionalCloses` in `forgetTrackingState`**

In `Sources/Espalier/Terminal/TerminalManager.swift`, modify `forgetTrackingState` (around line 403) to also drop the intentional-close membership so destroyed IDs do not leak entries:

```swift
    private func forgetTrackingState(for terminalID: TerminalID) {
        shellReadyFired.remove(terminalID)
        firstPaneMarkers.remove(terminalID)
        rehydratedSurfaces.remove(terminalID)
        intentionalCloses.remove(terminalID)
    }
```

- [ ] **Step 4: Verify build**

```bash
swift build 2>&1 | tail -20
```

Expected: build succeeds. No tests yet — the next task adds the policy decision and exercises this state.

- [ ] **Step 5: Commit**

```bash
git add Sources/Espalier/Terminal/TerminalManager.swift
git commit -m "$(cat <<'EOF'
feat(terminal): track intentional closes; expose clearRehydrated

intentionalCloses is populated by killZmxSession (the single funnel for
Espalier-initiated kills) so a subsequent close_surface_cb can be
distinguished from a daemon-died-underneath-us event. clearRehydrated
gives the cold-start session-loss check somewhere to land.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 5: TerminalManager — `shouldRestartInsteadOfClose` decision

**Files:**
- Modify: `Sources/Espalier/Terminal/TerminalManager.swift`

- [ ] **Step 1: Add the decision method**

Below `clearRehydrated` (added in Task 4), insert:

```swift
    /// Whether the imminent close for `terminalID` should be treated as
    /// session-loss (rebuild the surface) rather than a normal close
    /// (destroy the pane). Consumes `intentionalCloses` membership so a
    /// subsequent close for the same ID does not flip the decision.
    ///
    /// Returns `false` when:
    ///   - The close was Espalier-initiated (membership in
    ///     `intentionalCloses`, populated by `killZmxSession`).
    ///   - We have no `ZmxLauncher` configured (zmx fallback path —
    ///     there is no daemon to be missing).
    ///   - The expected session is still present in `listSessions()`,
    ///     meaning the inner shell really did exit on its own.
    /// Returns `true` only when the close was unannounced AND the
    /// session name is absent from the live set.
    func shouldRestartInsteadOfClose(_ terminalID: TerminalID) -> Bool {
        if intentionalCloses.remove(terminalID) != nil {
            // We initiated this close — destroy as normal.
            return false
        }
        guard let launcher = zmxLauncher else { return false }
        let name = launcher.sessionName(for: terminalID.id)
        return launcher.isSessionMissing(name)
    }
```

- [ ] **Step 2: Verify build**

```bash
swift build 2>&1 | tail -10
```

Expected: build succeeds.

- [ ] **Step 3: Commit**

```bash
git add Sources/Espalier/Terminal/TerminalManager.swift
git commit -m "$(cat <<'EOF'
feat(terminal): shouldRestartInsteadOfClose decision

Single funnel for "is this close a session-loss event or a normal
exit?" Consumes intentionalCloses membership and consults
isSessionMissing.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 6: TerminalManager — `restartSurface(for:)` rebuild in place

**Files:**
- Modify: `Sources/Espalier/Terminal/TerminalManager.swift`

- [ ] **Step 1: Add the rebuild method**

In `Sources/Espalier/Terminal/TerminalManager.swift`, add a method on TerminalManager (place it just below `createSurface(terminalID:worktreePath:)` near line 329):

```swift
    /// Rebuild the libghostty surface for an existing pane in place,
    /// keeping the same `TerminalID` (and therefore its split-tree slot,
    /// remembered position, title, etc.) but starting a fresh zmx
    /// session under the same name. Called by EspalierApp's close
    /// handler when `shouldRestartInsteadOfClose` returns true.
    ///
    /// Prepends a `sessionRestartBanner(at:)` line to the new surface's
    /// `initial_input` so the user sees a visible marker that the
    /// underlying session was replaced.
    ///
    /// No-op if the pane is unknown to the manager or if no GhosttyApp
    /// is initialised.
    func restartSurface(for terminalID: TerminalID) {
        guard let app = ghosttyApp?.app,
              let existing = surfaces[terminalID] else {
            return
        }

        let worktreePath = existing.worktreePath
        // Drop the dead handle. ARC frees the underlying surface in
        // SurfaceHandle.deinit; the userdata box is released there too,
        // so no further callbacks fire against the old surface.
        surfaces.removeValue(forKey: terminalID)
        // Title and shell-ready state belong to the dead session; clear
        // them so the rebuilt pane behaves like a fresh shell.
        titles.removeValue(forKey: terminalID)
        shellReadyFired.remove(terminalID)

        // Compose the new initial_input: banner first, then the same
        // attach line resolveZmxSpawn would have emitted.
        let (zmxInitialInput, zmxDir) = resolveZmxSpawn(for: terminalID)
        let banneredInput: String? = zmxInitialInput.map { attach in
            sessionRestartBanner(at: Date()) + attach
        }

        let handle = SurfaceHandle(
            terminalID: terminalID,
            app: app,
            worktreePath: worktreePath,
            socketPath: socketPath,
            zmxInitialInput: banneredInput,
            zmxDir: zmxDir,
            terminalManager: self
        )
        surfaces[terminalID] = handle
    }
```

- [ ] **Step 2: Verify build**

```bash
swift build 2>&1 | tail -10
```

Expected: build succeeds.

- [ ] **Step 3: Commit**

```bash
git add Sources/Espalier/Terminal/TerminalManager.swift
git commit -m "$(cat <<'EOF'
feat(terminal): restartSurface rebuilds a pane in place after session loss

Same TerminalID, same split-tree slot, fresh zmx attach with the restart
banner prepended to initial_input.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 7: Cold-start call site — clear rehydration label when daemon is missing

**Files:**
- Modify: `Sources/Espalier/Terminal/TerminalManager.swift`

- [ ] **Step 1: Modify `createSurfaces(for:worktreePath:)`**

In `Sources/Espalier/Terminal/TerminalManager.swift`, modify the existing `createSurfaces(for:worktreePath:)` method (around line 283). Replace the loop body so the rehydration label is corrected before the surface is created:

```swift
    @discardableResult
    func createSurfaces(
        for splitTree: SplitTree,
        worktreePath: String
    ) -> [TerminalID: SurfaceHandle] {
        guard let app = ghosttyApp?.app else { return [:] }

        var created: [TerminalID: SurfaceHandle] = [:]
        for terminalID in splitTree.allLeaves where surfaces[terminalID] == nil {
            // Cold-start session-loss check: if this pane was marked
            // rehydrated but the underlying zmx daemon is gone, the
            // imminent zmx attach will create a fresh daemon. Treat the
            // pane as fresh-not-rehydrated so the default command runs.
            // See ZMX-7.1.
            if rehydratedSurfaces.contains(terminalID),
               let launcher = zmxLauncher,
               launcher.isSessionMissing(launcher.sessionName(for: terminalID.id)) {
                clearRehydrated(terminalID)
            }

            let (zmxInitialInput, zmxDir) = resolveZmxSpawn(for: terminalID)
            let handle = SurfaceHandle(
                terminalID: terminalID,
                app: app,
                worktreePath: worktreePath,
                socketPath: socketPath,
                zmxInitialInput: zmxInitialInput,
                zmxDir: zmxDir,
                terminalManager: self
            )
            surfaces[terminalID] = handle
            created[terminalID] = handle
        }
        return created
    }
```

- [ ] **Step 2: Apply the same change to `createSurface(terminalID:worktreePath:)`**

Modify the single-pane `createSurface` (around line 308) similarly:

```swift
    func createSurface(
        terminalID: TerminalID,
        worktreePath: String
    ) -> SurfaceHandle? {
        guard let app = ghosttyApp?.app else { return nil }
        if let existing = surfaces[terminalID] {
            return existing
        }

        // Cold-start session-loss check (ZMX-7.1) — see createSurfaces.
        if rehydratedSurfaces.contains(terminalID),
           let launcher = zmxLauncher,
           launcher.isSessionMissing(launcher.sessionName(for: terminalID.id)) {
            clearRehydrated(terminalID)
        }

        let (zmxInitialInput, zmxDir) = resolveZmxSpawn(for: terminalID)
        let handle = SurfaceHandle(
            terminalID: terminalID,
            app: app,
            worktreePath: worktreePath,
            socketPath: socketPath,
            zmxInitialInput: zmxInitialInput,
            zmxDir: zmxDir,
            terminalManager: self
        )
        surfaces[terminalID] = handle
        return handle
    }
```

- [ ] **Step 3: Verify build**

```bash
swift build 2>&1 | tail -10
```

Expected: build succeeds.

- [ ] **Step 4: Commit**

```bash
git add Sources/Espalier/Terminal/TerminalManager.swift
git commit -m "$(cat <<'EOF'
feat(terminal): clear rehydration label when zmx daemon is missing

Cold-start session-loss detection in createSurface(s): if a pane was
marked rehydrated but the daemon is gone, the imminent zmx attach will
create a fresh daemon — so treat the pane as fresh, letting the default
command run (ZMX-7.1).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 8: Mid-flight call site — route close handler through restart decision

**Files:**
- Modify: `Sources/Espalier/EspalierApp.swift`

- [ ] **Step 1: Modify the `onCloseRequest` wiring in `startup()`**

In `Sources/Espalier/EspalierApp.swift`, find the existing `onCloseRequest` wiring (around line 213):

```swift
        terminalManager.onCloseRequest = { [appState = $appState, tm = terminalManager] terminalID in
            MainActor.assumeIsolated {
                Self.closePane(
                    appState: appState,
                    terminalManager: tm,
                    targetID: terminalID
                )
            }
        }
```

Replace it with a routed version:

```swift
        terminalManager.onCloseRequest = { [appState = $appState, tm = terminalManager] terminalID in
            MainActor.assumeIsolated {
                // Mid-flight session-loss recovery (ZMX-7.2): if the
                // close was unannounced and the zmx session is gone, we
                // rebuild the pane in place rather than letting it
                // disappear. shouldRestartInsteadOfClose consumes the
                // intentionalCloses tracker, so the same close cannot
                // be re-evaluated as session-loss on a future call.
                if tm.shouldRestartInsteadOfClose(terminalID) {
                    tm.restartSurface(for: terminalID)
                } else {
                    Self.closePane(
                        appState: appState,
                        terminalManager: tm,
                        targetID: terminalID
                    )
                }
            }
        }
```

- [ ] **Step 2: Verify build**

```bash
swift build 2>&1 | tail -10
```

Expected: build succeeds.

- [ ] **Step 3: Run the existing test suite to confirm no regressions**

```bash
swift test 2>&1 | tail -30
```

Expected: all existing tests pass (the new tests from Tasks 1–3 also pass; the changes in 4–8 are guarded by the `intentionalCloses` populator, so existing tear-down paths still resolve to "close" — `killZmxSession` runs as part of `destroySurface`, populating `intentionalCloses` so the close handler hits the existing `closePane` branch).

If a test fails because `killZmxSession` runs *after* the close callback fires (race), the fix is to invert the order in the test setup OR to ensure `intentionalCloses.insert` happens synchronously before `requestClose`. Inspect the failing path before patching.

- [ ] **Step 4: Commit**

```bash
git add Sources/Espalier/EspalierApp.swift
git commit -m "$(cat <<'EOF'
feat(terminal): route close handler through restart decision

When close_surface_cb fires for an unannounced close and the zmx
session is gone, rebuild the pane in place instead of removing it
(ZMX-7.2). Existing close paths populate intentionalCloses via
killZmxSession, so they hit the unchanged closePane branch.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 9: SPECS.md updates

**Files:**
- Modify: `SPECS.md` — append §13.7 after the current §13.6, amend ZMX-4.3.

- [ ] **Step 1: Amend ZMX-4.3**

Find the existing ZMX-4.3 (search for `**ZMX-4.3**`):

```
**ZMX-4.3** When the application destroys a terminal surface (user-initiated close, automatic close on shell exit, or worktree stop), it shall asynchronously invoke `zmx kill --force <session>` for the matching session.
```

Append a sentence so the full requirement reads:

```
**ZMX-4.3** When the application destroys a terminal surface (user-initiated close, automatic close on shell exit, or worktree stop), it shall asynchronously invoke `zmx kill --force <session>` for the matching session. Every site that initiates `zmx kill --force` shall also mark the pane as an intentional close, so the subsequent `close_surface_cb` is not misclassified as session-loss per `ZMX-7.2`.
```

- [ ] **Step 2: Add §13.7**

After the existing §13.6 block (last requirement: ZMX-6.3) and before `## 14. Distribution`, insert:

```
### 13.7 Session-Loss Recovery

**ZMX-7.1** When the application restores a worktree's split tree on launch (per `PERSIST-3.x` and `ZMX-4.2`), it shall, before creating each pane's surface, query the live zmx session set and clear the pane's rehydration label if the expected session name is absent. This ensures a freshly-created daemon (the result of `zmx attach`'s create-on-miss semantics) is not mistaken for a surviving session by `defaultCommandDecision`.

**ZMX-7.2** When `close_surface_cb` fires for a pane and Espalier did not initiate the close, the application shall query the live zmx session set; if the expected session name is absent, the application shall rebuild the pane's libghostty surface in place — same `TerminalID`, same split-tree position, fresh `zmx attach` — instead of removing the pane from the tree.

**ZMX-7.3** While rebuilding a surface per `ZMX-7.2`, the application shall prepend a single visually-distinct banner line ("`— session restarted at HH:MM —`", ANSI dim) to the new pane's `initial_input` so the user can recognize that the underlying session has been replaced.

**ZMX-7.4** If `zmx list` fails for any reason at either query site (per `ZMX-7.1` or `ZMX-7.2`), the application shall treat the result as "session not missing" and take no recovery action — preferring a missed recovery over a spurious rebuild.
```

- [ ] **Step 3: Sanity check**

```bash
grep -nE "^\*\*ZMX-(4\.3|7\.[1-4])\*\*" SPECS.md
```

Expected: 5 lines printed — ZMX-4.3 once, ZMX-7.1, 7.2, 7.3, 7.4.

- [ ] **Step 4: Commit**

```bash
git add SPECS.md
git commit -m "$(cat <<'EOF'
docs(specs): zmx session-loss recovery (§13.7) + ZMX-4.3 amendment

Adds ZMX-7.1–7.4 covering cold-start rehydration relabel, mid-flight
in-place rebuild, the restart banner, and the fail-safe-to-not-missing
bias for zmx-query failures.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 10: Final verification

**Files:** No edits — verification only.

- [ ] **Step 1: Full build + test**

```bash
swift build 2>&1 | tail -5 && swift test 2>&1 | tail -30
```

Expected: build succeeds; all tests pass.

- [ ] **Step 2: Confirm SPECS coverage**

```bash
grep -c "ZMX-7\." SPECS.md
```

Expected: 4 (ZMX-7.1 through 7.4 each appear once).

- [ ] **Step 3: Confirm git history is the expected sequence**

```bash
git log --oneline -10
```

Expected sequence (most recent first):
```
docs(specs): zmx session-loss recovery (§13.7) + ZMX-4.3 amendment
feat(terminal): route close handler through restart decision
feat(terminal): clear rehydration label when zmx daemon is missing
feat(terminal): restartSurface rebuilds a pane in place after session loss
feat(terminal): shouldRestartInsteadOfClose decision
feat(terminal): track intentional closes; expose clearRehydrated
feat(zmx): pure-function banner for restarted sessions
test(zmx): integration test for isSessionMissing against real daemon
feat(zmx): add isSessionMissing helper for session-loss detection
docs: spec for zmx session restart recovery
```

If any commits are missing or out of order, do not rebase reactively — investigate which task was skipped.

---

## Plan self-review

Spec coverage:

- **ZMX-7.1** (cold-start rehydration relabel): Tasks 1, 4, 7.
- **ZMX-7.2** (mid-flight rebuild): Tasks 1, 4, 5, 6, 8.
- **ZMX-7.3** (banner format): Task 3.
- **ZMX-7.4** (fail-safe to not-missing on query failure): Task 1.
- **ZMX-4.3 amendment** (intentional-close tracking): Task 4 (state + populator).

No spec requirement is unimplemented. No task is purely speculative.

Type/method consistency check:

- `isSessionMissing(_:)` — Task 1 defines it; Tasks 5 and 7 call it. ✅
- `clearRehydrated(_:)` — Task 4 defines it; Task 7 calls it. ✅
- `intentionalCloses` — Task 4 declares it and the populator (`killZmxSession`); Task 5 consumes it. ✅
- `shouldRestartInsteadOfClose(_:)` — Task 5 defines it; Task 8 calls it. ✅
- `restartSurface(for:)` — Task 6 defines it; Task 8 calls it. ✅
- `sessionRestartBanner(at:)` — Task 3 defines it; Task 6 calls it. ✅

Placeholder check: Task 2 has one intentionally-deferred body in the helper-extraction section (`spawnAttach`), with explicit instructions to "copy from the existing PTY-spawning test's setup" and a `fatalError` to fail loudly if the implementer skips it. This is a real risk — the implementer might write past the fatal. Acceptable because the integration test will fail to compile/run if the helper is broken. Not changed.
