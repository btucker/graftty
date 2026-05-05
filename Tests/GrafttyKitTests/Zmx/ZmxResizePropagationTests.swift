import Testing
import Foundation
import Darwin
@testable import GrafttyKit

/// Verifies TIOCSWINSZ on a `zmx attach` PTY propagates to the zmx
/// daemon's inner session — the invariant `WEB-4.7` protects.
///
/// `.serialized` because `PtyProcess.spawn` uses raw `fork(2)` to set
/// up `setsid` + `TIOCSCTTY`; two concurrent forks from Swift Testing's
/// parallel tasks can deadlock the child inside libmalloc (fork from
/// a multi-threaded process is only async-signal-safe until `execve`).
@Suite("Zmx — SIGWINCH resize propagation", .serialized)
struct ZmxResizePropagationTests {

    // MARK: - Shared helpers

    /// Distinctive size chosen to be unlikely to appear in zmx's default
    /// paths (24×80 is the POSIX default, 1×1 is our pre-layout init, and
    /// we avoid common values). Unique match on `resize rows=29 cols=73`.
    private static let targetRows: UInt16 = 29
    private static let targetCols: UInt16 = 73

    /// Initial size we set on the outer PTY BEFORE spawning `zmx attach`,
    /// so the client's startup `ipc.getTerminalSize(STDOUT_FILENO)` reads
    /// this value and sends Init with it. The daemon applies that size to
    /// the inner PTY; any subsequent resize has to come from SIGWINCH.
    /// 24×80 (POSIX default) is the natural "starting point size" — it
    /// keeps zmx's inner shell well-behaved while still differing from
    /// our distinctive target, so a post-init resize has to actually
    /// propagate to show up.
    private static let initialRows: UInt16 = 24
    private static let initialCols: UInt16 = 80

    /// A running `zmx attach` child with a properly-configured PTY
    /// (setsid + TIOCSCTTY + dup2 in the child, via PtyProcess.spawn),
    /// so TIOCSWINSZ on `masterFd` actually fires SIGWINCH at the
    /// child's process group. Cleans up via `terminate()`.
    struct PtyAttach {
        let pid: pid_t
        let masterFd: Int32

        /// Aggressively tear down: SIGKILL the attach client directly
        /// (no wait, no subprocess kill-by-session — this test doesn't
        /// care whether the daemon gets cleaned up, only that we don't
        /// block here. Leftover zmx daemons get reaped by launchd at
        /// session end; the scoped ZMX_DIR keeps their state isolated
        /// from other tests).
        func terminate() {
            _ = Darwin.kill(pid, SIGKILL)
            Darwin.close(masterFd)
        }
    }

    /// Scope an ephemeral ZMX_DIR for a single test. Tests kill their
    /// known session directly; teardown only removes filesystem state so
    /// degraded daemon paths do not stack extra subprocess waits.
    private static func withScopedZmxDir<T>(_ body: (ZmxLauncher) throws -> T) throws -> T {
        let zmx = try #require(
            ZmxSurvivalIntegrationTests.vendoredZmx(),
            "zmx binary not vendored — run scripts/bump-zmx.sh"
        )
        // /tmp (4-char base) leaves ample room under the 104-byte
        // Unix-domain-socket path limit for our 16-char session name.
        let tmpDir = URL(fileURLWithPath: "/tmp")
            .appendingPathComponent("zmx-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        let launcher = ZmxLauncher(executable: zmx, zmxDir: tmpDir)
        defer {
            try? FileManager.default.removeItem(at: tmpDir)
        }
        return try body(launcher)
    }

    /// Spawn a `zmx attach` child whose outer PTY starts at
    /// `(cols, rows)`. Uses `PtyProcess.spawn` directly so the child
    /// becomes the foreground process group leader of the slave PTY —
    /// required for any TIOCSWINSZ to actually deliver SIGWINCH.
    private static func spawnAttachWithInitialSize(
        launcher: ZmxLauncher,
        sessionName: String,
        cols: UInt16,
        rows: UInt16,
        resetSignalMask: Bool = true
    ) throws -> PtyAttach {
        let env = launcher.subprocessEnv(from: ProcessInfo.processInfo.environment)
            .merging(["SHELL": "/bin/sh"]) { _, new in new }
        let spawned = try PtyProcess.spawn(
            argv: launcher.attachArgv(sessionName: sessionName, userShell: "/bin/sh"),
            env: env,
            initialSize: (cols: cols, rows: rows),
            resetSignalMask: resetSignalMask
        )

        // Non-blocking master so test reads don't hang if we ever decide
        // to drain output. (We mostly avoid reading in these tests — the
        // whole point is to observe zmx's log file side-channel, not
        // what the inner shell prints.)
        let flags = fcntl(spawned.masterFD, F_GETFL)
        _ = fcntl(spawned.masterFD, F_SETFL, flags | O_NONBLOCK)

        return PtyAttach(pid: spawned.pid, masterFd: spawned.masterFD)
    }

    private static func withSIGWINCHBlocked<T>(_ body: () throws -> T) rethrows -> T {
        var set = sigset_t()
        sigemptyset(&set)
        sigaddset(&set, SIGWINCH)
        pthread_sigmask(SIG_BLOCK, &set, nil)
        defer { pthread_sigmask(SIG_UNBLOCK, &set, nil) }
        return try body()
    }

    /// Read the session's zmx daemon log file and return its full contents.
    /// Returns an empty string if the file doesn't exist yet.
    private static func readSessionLog(
        launcher: ZmxLauncher,
        sessionName: String
    ) -> String {
        let url = launcher.logFile(forSession: sessionName)
        guard let data = try? Data(contentsOf: url) else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// Poll the session log for a substring until `deadline` elapses.
    /// Returns the final log contents regardless of whether the match
    /// appeared — tests inspect it to produce a useful failure message.
    private static func waitForLogContains(
        launcher: ZmxLauncher,
        sessionName: String,
        needle: String,
        timeout: TimeInterval
    ) -> String {
        let deadline = Date().addingTimeInterval(timeout)
        var log = ""
        while Date() < deadline {
            log = readSessionLog(launcher: launcher, sessionName: sessionName)
            if log.contains(needle) { return log }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return log
    }

    /// Needle matching the daemon's post-init `handleResize` log line
    /// for the given dimensions. The scope prefix `(default): ` is what
    /// distinguishes it from `(default): init resize rows=…` which also
    /// contains the same numbers on startup but is emitted by
    /// `handleInit`, not `handleResize`.
    private static func resizeNeedle(rows: UInt16, cols: UInt16) -> String {
        "(default): resize rows=\(rows) cols=\(cols)"
    }

    /// Wait until the daemon has fully processed the startup Init → setLeader
    /// → Resize round-trip (indicated by `resize rows=<initial> cols=<initial>`
    /// appearing in the session log). At that point the attach client is in
    /// its steady-state poll loop — the SIGWINCH handler is installed and
    /// the subsequent TIOCSWINSZ we perform will be observed as a real
    /// resize event, not lost to the "signal delivered before handler
    /// installed" startup window.
    private static func waitForSteadyState(
        launcher: ZmxLauncher,
        sessionName: String,
        initialCols: UInt16,
        initialRows: UInt16,
        timeout: TimeInterval = 5
    ) throws {
        let needle = resizeNeedle(rows: initialRows, cols: initialCols)
        let log = waitForLogContains(
            launcher: launcher,
            sessionName: sessionName,
            needle: needle,
            timeout: timeout
        )
        if !log.contains(needle) {
            throw NSError(
                domain: "ZmxResizePropagationTests",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey:
                    "session \(sessionName) never reached steady state within \(timeout)s; log=\(log)"]
            )
        }
    }

    // MARK: - Tests

    /// `zmx attach` must forward a PTY resize to the daemon even when
    /// the attached session is idle. zmx 0.5.0 had a SIGWINCH → `poll(-1)`
    /// race: if SIGWINCH arrived just before the client entered `poll`,
    /// the resize flag stayed stranded until a later keystroke or daemon
    /// output woke the loop. That matched the user-visible symptom where
    /// a just-reattached Claude Code pane kept the old dimensions until
    /// the user typed.
    @Test(.timeLimit(.minutes(1)))
    func resizeIsPropagatedWithoutUserInput() throws {
        try Self.withScopedZmxDir { launcher in
            let session = launcher.sessionName(for: UUID())
            defer { launcher.kill(sessionName: session) }
            let attach = try Self.spawnAttachWithInitialSize(
                launcher: launcher,
                sessionName: session,
                cols: Self.initialCols,
                rows: Self.initialRows
            )
            defer { attach.terminate() }

            // Wait for the daemon to register the session and process its
            // startup Init → setLeader → Resize round-trip. The
            // `resize rows=24 cols=80` log line is emitted by the daemon
            // only AFTER the attach client has completed its Init, been
            // promoted to leader, and responded to the daemon's Resize
            // query — i.e. the client is now in its main poll loop with
            // its SIGWINCH handler installed. That's the state we need
            // to isolate the swap-to-poll race.
            try Self.waitForSteadyState(
                launcher: launcher,
                sessionName: session,
                initialCols: Self.initialCols,
                initialRows: Self.initialRows
            )

            try PtyProcess.resize(
                masterFD: attach.masterFd,
                cols: Self.targetCols,
                rows: Self.targetRows
            )

            let needle = Self.resizeNeedle(rows: Self.targetRows, cols: Self.targetCols)
            let log = Self.waitForLogContains(
                launcher: launcher,
                sessionName: session,
                needle: needle,
                timeout: 2.0
            )

            #expect(
                log.contains(needle),
                """
                daemon session log never showed `\(needle)` within 2s \
                of TIOCSWINSZ — SIGWINCH appears to have been lost in \
                zmx's poll-race window. Full log:
                \(log)
                """
            )
        }
    }

    /// Mirrors the Ghostty-launched shell path: the intermediate shell can
    /// exec `zmx attach` with the parent's SIGWINCH mask intact. zmx itself
    /// must unblock SIGWINCH before installing its wake handler, otherwise
    /// resize remains pending until unrelated input changes the session.
    @Test(.timeLimit(.minutes(1)))
    func resizeIsPropagatedWhenSIGWINCHStartsBlocked() throws {
        try Self.withScopedZmxDir { launcher in
            let session = launcher.sessionName(for: UUID())
            defer { launcher.kill(sessionName: session) }
            let attach = try Self.withSIGWINCHBlocked {
                try Self.spawnAttachWithInitialSize(
                    launcher: launcher,
                    sessionName: session,
                    cols: Self.initialCols,
                    rows: Self.initialRows,
                    resetSignalMask: false
                )
            }
            defer { attach.terminate() }

            try Self.waitForSteadyState(
                launcher: launcher,
                sessionName: session,
                initialCols: Self.initialCols,
                initialRows: Self.initialRows
            )

            try PtyProcess.resize(
                masterFD: attach.masterFd,
                cols: Self.targetCols,
                rows: Self.targetRows
            )

            let needle = Self.resizeNeedle(rows: Self.targetRows, cols: Self.targetCols)
            let log = Self.waitForLogContains(
                launcher: launcher,
                sessionName: session,
                needle: needle,
                timeout: 2.0
            )

            #expect(
                log.contains(needle),
                """
                daemon session log never showed `\(needle)` within 2s \
                when zmx attach inherited a blocked SIGWINCH mask. Full log:
                \(log)
                """
            )
        }
    }

    /// Regression test for the Graftty-side half of the resize bug:
    /// SIGWINCH must actually reach zmx-attach's handler. We set up
    /// steady state, TIOCSWINSZ, then nudge with a single LF — any
    /// byte zmx's `isUserInput` considers "real" input. If SIGWINCH
    /// landed in zmx's swap-to-poll race window, its flag is still
    /// set, and the LF waking `poll` drains that flag into a Resize
    /// IPC. The daemon logs `resize rows=29 cols=73` and we pass.
    ///
    /// Before `PtyProcess.spawn` switched to `posix_spawn` with
    /// `POSIX_SPAWN_SETSIGMASK`, the Swift runtime's inherited sigmask
    /// blocked SIGWINCH delivery to zmx entirely — the handler never
    /// fired, so even the LF nudge couldn't recover a resize that was
    /// never seen. This test asserts that's no longer the case.
    @Test("""
    @spec WEB-4.7: When the application transitions the forked child into `zmx attach`, the final `execve` shall be performed via `posix_spawn` with `POSIX_SPAWN_SETEXEC | POSIX_SPAWN_SETSIGMASK` and an empty initial signal mask. `fork(2)` preserves the parent's sigmask and plain `execve(2)` carries it across — and the Swift runtime (GCD/Dispatch) blocks a family of signals on its service threads, so a child inheriting that mask starts with SIGWINCH blocked. `zmx attach` installs a SIGWINCH handler to forward PTY resize events to the daemon; if SIGWINCH is blocked the handler never fires, the kernel sets the signal pending, and WebSocket-sent resize events silently vanish until an unrelated signal or explicit unblock drains them. The spawn-level mask reset is the kernel-boundary fix that guarantees the exec'd image starts with every signal unblocked.
    """, .timeLimit(.minutes(1)))
    func resizeIsPropagatedAfterUserInput() throws {
        try Self.withScopedZmxDir { launcher in
            let session = launcher.sessionName(for: UUID())
            defer { launcher.kill(sessionName: session) }
            let attach = try Self.spawnAttachWithInitialSize(
                launcher: launcher,
                sessionName: session,
                cols: Self.initialCols,
                rows: Self.initialRows
            )
            defer { attach.terminate() }

            try Self.waitForSteadyState(
                launcher: launcher,
                sessionName: session,
                initialCols: Self.initialCols,
                initialRows: Self.initialRows
            )

            try PtyProcess.resize(
                masterFD: attach.masterFd,
                cols: Self.targetCols,
                rows: Self.targetRows
            )

            // Small settle so the race (if hit) has a chance to strand
            // the flag, then nudge with input. A bare newline is the
            // smallest "user input" zmx recognizes (isUserInput matches
            // LF via the `execute` branch).
            Thread.sleep(forTimeInterval: 0.2)
            let newline: [UInt8] = [0x0A]
            _ = newline.withUnsafeBufferPointer { ptr in
                Darwin.write(attach.masterFd, ptr.baseAddress, ptr.count)
            }

            let needle = Self.resizeNeedle(rows: Self.targetRows, cols: Self.targetCols)
            let log = Self.waitForLogContains(
                launcher: launcher,
                sessionName: session,
                needle: needle,
                timeout: 2.0
            )

            #expect(
                log.contains(needle),
                """
                daemon session log never showed `\(needle)` even after \
                an input byte — something's wrong with the test setup, \
                not the SIGWINCH race. Full log:
                \(log)
                """
            )
        }
    }
}
