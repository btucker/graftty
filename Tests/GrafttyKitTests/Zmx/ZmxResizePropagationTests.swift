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

        func write(_ text: String) {
            text.utf8CString.withUnsafeBufferPointer { bytes in
                _ = Darwin.write(masterFd, bytes.baseAddress, bytes.count - 1)
            }
        }

        func waitForOutput(_ marker: String, timeout: TimeInterval = 5) -> String {
            let deadline = Date().addingTimeInterval(timeout)
            var output = Data()
            var buffer = [UInt8](repeating: 0, count: 4_096)
            while Date() < deadline {
                let count = buffer.withUnsafeMutableBufferPointer {
                    Darwin.read(masterFd, $0.baseAddress, $0.count)
                }
                if count > 0 {
                    output.append(contentsOf: buffer[0..<count])
                    if String(decoding: output, as: UTF8.self).contains(marker) {
                        break
                    }
                } else if count < 0, errno != EAGAIN, errno != EWOULDBLOCK {
                    break
                }
                Thread.sleep(forTimeInterval: 0.02)
            }
            return String(decoding: output, as: UTF8.self)
        }

        /// Aggressively tear down: SIGKILL the attach client directly,
        /// reap it, and leave session cleanup to the scoped launcher.
        func terminate() {
            _ = Darwin.kill(pid, SIGKILL)
            var status: Int32 = 0
            while Darwin.waitpid(pid, &status, 0) == -1, errno == EINTR {}
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
        xpixel: UInt16 = 0,
        ypixel: UInt16 = 0,
        resetSignalMask: Bool = true
    ) throws -> PtyAttach {
        let env = launcher.subprocessEnv(from: ProcessInfo.processInfo.environment)
            .merging(["SHELL": "/bin/sh"]) { _, new in new }
        let spawned = try PtyProcess.spawn(
            argv: launcher.attachArgv(sessionName: sessionName, userShell: "/bin/sh"),
            env: env,
            initialWindowSize: PtyProcess.WindowSize(
                cols: cols,
                rows: rows,
                xpixel: xpixel,
                ypixel: ypixel
            ),
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

    private static func resizeNeedle(
        rows: UInt16,
        cols: UInt16,
        xpixel: UInt16,
        ypixel: UInt16
    ) -> String {
        "\(resizeNeedle(rows: rows, cols: cols)) xpixel=\(xpixel) ypixel=\(ypixel)"
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
    @Test("""
    @spec ZMX-9.1: When the bundled `zmx attach` client receives a PTY resize event while idle, it shall forward the new grid without requiring a later keystroke or daemon output to wake its poll loop. This protects restored or lazily reattached panes: when Graftty resizes the outer PTY as a pane comes into view, the daemon's inner PTY must receive the new grid immediately so full-screen programs such as Claude Code, vim, and htop repaint at the visible pane size before user input.
    """, .timeLimit(.minutes(1)))
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

    @Test("""
    @spec ZMX-9.2: When the bundled Graftty `zmx` client and daemon negotiate pixel-size support, the client shall send pixel metadata immediately before the unchanged legacy 4-byte row/column Resize message. When only the outer PTY's pixel dimensions change, the new pixels shall reach the daemon's inner PTY without requiring a grid change, while the vendoring compatibility gate shall continue to accept old-daemon/new-client and new-daemon/old-client attachments.
    """, .timeLimit(.minutes(1)))
    func negotiatedPixelOnlyResizeIsPropagated() throws {
        try Self.withScopedZmxDir { launcher in
            let session = launcher.sessionName(for: UUID())
            defer { launcher.kill(sessionName: session) }
            let attach = try Self.spawnAttachWithInitialSize(
                launcher: launcher,
                sessionName: session,
                cols: Self.initialCols,
                rows: Self.initialRows,
                xpixel: 960,
                ypixel: 576
            )
            defer { attach.terminate() }

            try Self.waitForSteadyState(
                launcher: launcher,
                sessionName: session,
                initialCols: Self.initialCols,
                initialRows: Self.initialRows
            )

            let resized = PtyProcess.WindowSize(
                cols: Self.initialCols,
                rows: Self.initialRows,
                xpixel: 1_280,
                ypixel: 720
            )
            try PtyProcess.resize(masterFD: attach.masterFd, windowSize: resized)

            let needle = Self.resizeNeedle(
                rows: resized.rows,
                cols: resized.cols,
                xpixel: resized.xpixel,
                ypixel: resized.ypixel
            )
            let log = Self.waitForLogContains(
                launcher: launcher,
                sessionName: session,
                needle: needle,
                timeout: 2.0
            )

            #expect(
                log.contains(needle),
                """
                daemon session log never showed negotiated pixel-only resize \
                `\(needle)` within 2s. Full log:
                \(log)
                """
            )

            // The daemon logs the requested size after an unchecked ioctl.
            // Query from a child of the inner shell so this test proves the
            // PTY adopted the dimensions rather than merely logging them.
            let innerMarker = "INNER_WINDOW:\(resized.rows):\(resized.cols):"
                + "\(resized.xpixel):\(resized.ypixel)"
            attach.write(
                "python3 -c \"import fcntl,struct,termios;"
                    + "r,c,x,y=struct.unpack('HHHH',fcntl.ioctl(0,termios.TIOCGWINSZ,bytes(8)));"
                    + "print(f'INNER_WINDOW:{r}:{c}:{x}:{y}')\"\n"
            )
            let output = attach.waitForOutput(innerMarker)
            #expect(
                output.contains(innerMarker),
                "inner PTY did not adopt the negotiated pixel resize; output=\(output)"
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

    /// Poll the session log until `needle` has appeared at least
    /// `count` times. Needed by the re-attach test: the first attach
    /// already emits the steady-state needle once, so the second
    /// attach's round-trip is only proven by a *second* occurrence.
    private static func waitForLogOccurrences(
        launcher: ZmxLauncher,
        sessionName: String,
        needle: String,
        count: Int,
        timeout: TimeInterval
    ) -> String {
        let deadline = Date().addingTimeInterval(timeout)
        var log = ""
        while Date() < deadline {
            log = readSessionLog(launcher: launcher, sessionName: sessionName)
            if log.components(separatedBy: needle).count - 1 >= count { return log }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return log
    }

    /// Root cause of the "last screenful repeated" LRU re-show bug: the
    /// pixel-size extension made the daemon build every `TIOCSWINSZ` from
    /// `client.pixel_size`, but Init is a client's *first* message —
    /// `PixelSize` can only arrive after the daemon's Capabilities
    /// advertisement. A fresh client therefore dips the session PTY's
    /// pixels to 0 at Init and restores them at the leader size
    /// round-trip. XNU raises SIGWINCH on *any* winsize field change
    /// (pixels included), so every re-attach delivered two spurious
    /// SIGWINCHes and zsh repainted its prompt over the just-replayed
    /// screen. The pre-pixel-extension 0.5 binary delivers zero.
    ///
    /// Observable: a WINCH trap in the inner shell printing an epoch
    /// marker. The marker is assembled via `printf "__W_%s__" B` so
    /// neither command echo nor zmx's replay of that echo can satisfy
    /// the match — only a genuinely delivered signal can.
    @Test("""
    @spec ZMX-9.4: When a `zmx attach` client attaches to an existing session whose winsize (cells and pixels) matches the outer PTY's, the daemon shall deliver no SIGWINCH to the session's foreground process: until that client sends a PixelSize message, the daemon's winsize writes shall preserve the session PTY's current pixel dimensions rather than substitute the client's unset zeros, so an unchanged-size re-attach is a kernel no-op and the shell does not repaint its prompt over the replayed screen.
    """, .timeLimit(.minutes(1)))
    func identicalReattachDeliversNoSIGWINCH() throws {
        try Self.withScopedZmxDir { launcher in
            let session = launcher.sessionName(for: UUID())
            defer { launcher.kill(sessionName: session) }
            let size = PtyProcess.WindowSize(
                cols: Self.initialCols,
                rows: Self.initialRows,
                xpixel: 960,
                ypixel: 576
            )

            let first = try Self.spawnAttachWithInitialSize(
                launcher: launcher,
                sessionName: session,
                cols: size.cols,
                rows: size.rows,
                xpixel: size.xpixel,
                ypixel: size.ypixel
            )
            var firstTerminated = false
            defer { if !firstTerminated { first.terminate() } }

            try Self.waitForSteadyState(
                launcher: launcher,
                sessionName: session,
                initialCols: Self.initialCols,
                initialRows: Self.initialRows
            )

            // Arm the epoch-B trap *before* detaching so any SIGWINCH
            // raised by the second attach sequence prints the marker.
            first.write("trap 'printf \"__W_%s__\\n\" B' WINCH\n")
            first.write("printf '__TRAP_%s__\\n' SET\n")
            let armed = first.waitForOutput("__TRAP_SET__")
            #expect(armed.contains("__TRAP_SET__"), "trap arming never confirmed; output=\(armed)")

            first.terminate()
            firstTerminated = true
            Thread.sleep(forTimeInterval: 0.3)

            let second = try Self.spawnAttachWithInitialSize(
                launcher: launcher,
                sessionName: session,
                cols: size.cols,
                rows: size.rows,
                xpixel: size.xpixel,
                ypixel: size.ypixel
            )
            defer { second.terminate() }

            // Steady state for the SECOND attach = second occurrence of
            // the daemon's post-init resize line (the first attach
            // already logged one).
            let steadyNeedle = Self.resizeNeedle(rows: Self.initialRows, cols: Self.initialCols)
            let log = Self.waitForLogOccurrences(
                launcher: launcher,
                sessionName: session,
                needle: steadyNeedle,
                count: 2,
                timeout: 5.0
            )
            #expect(
                log.components(separatedBy: steadyNeedle).count - 1 >= 2,
                "second attach never completed its resize round-trip; log=\(log)"
            )

            // Bounded drain: waitForOutput returns everything read within
            // the window whether or not the marker appears. Any __W_B__
            // is a SIGWINCH the identical-size re-attach fabricated.
            let output = second.waitForOutput("__W_B__", timeout: 1.5)
            let spurious = output.components(separatedBy: "__W_B__").count - 1
            #expect(
                spurious == 0,
                """
                identical-winsize re-attach delivered \(spurious) spurious \
                SIGWINCH(es) to the session shell — the daemon substituted \
                the client's unset pixel_size zeros into TIOCSWINSZ. \
                Output: \(output)
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
