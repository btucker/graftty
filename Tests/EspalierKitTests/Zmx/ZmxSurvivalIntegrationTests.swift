import Testing
import Foundation
import Darwin
@testable import EspalierKit

@Suite("ZmxLauncher — survival contract (integration)")
struct ZmxSurvivalIntegrationTests {

    // MARK: Helpers

    /// Locate the bundled zmx binary by walking up from this source file
    /// to the repo root and looking under `Resources/zmx-binary/zmx`.
    /// Returns nil if the binary hasn't been vendored — tests should
    /// `try #require()` on this and surface a helpful skip message.
    static func vendoredZmx() -> URL? {
        // #file resolves to /…/Tests/EspalierKitTests/Zmx/ZmxSurvivalIntegrationTests.swift
        // Walk up: Zmx → EspalierKitTests → Tests → repo-root.
        let here = URL(fileURLWithPath: #file)
        let repoRoot = here
            .deletingLastPathComponent()  // Zmx/
            .deletingLastPathComponent()  // EspalierKitTests/
            .deletingLastPathComponent()  // Tests/
            .deletingLastPathComponent()  // repo root
        let candidate = repoRoot
            .appendingPathComponent("Resources")
            .appendingPathComponent("zmx-binary")
            .appendingPathComponent("zmx")
        guard FileManager.default.isExecutableFile(atPath: candidate.path) else {
            return nil
        }
        return candidate
    }

    /// Allocate a fresh ZMX_DIR under NSTemporaryDirectory, run the
    /// body, then force-kill any leaked sessions on exit.
    static func withScopedZmxDir<T>(_ body: (ZmxLauncher) throws -> T) throws -> T {
        let zmx = try #require(
            vendoredZmx(),
            "zmx binary not vendored — run scripts/bump-zmx.sh"
        )
        // Use /tmp directly (not NSTemporaryDirectory) because zmx sockets
        // are Unix domain sockets with a 104-byte path limit on macOS.
        // NSTemporaryDirectory() expands to /var/folders/…/T/ (48+ chars),
        // leaving too little room for our 17-char session name after
        // appending the UUID-based subdirectory name. /tmp is a 4-char
        // base that keeps the full path well inside the 104-byte limit.
        let tmpDir = URL(fileURLWithPath: "/tmp")
            .appendingPathComponent("zmx-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        let launcher = ZmxLauncher(executable: zmx, zmxDir: tmpDir)
        defer {
            // Reap anything still alive in this scoped dir.
            if let names = try? launcher.listSessions() {
                for name in names {
                    launcher.kill(sessionName: name)
                }
            }
            try? FileManager.default.removeItem(at: tmpDir)
        }
        return try body(launcher)
    }

    /// A running `zmx attach` process backed by a real PTY master/slave
    /// pair. Using a PTY is required because zmx attach uses PTY semantics
    /// for its terminal session — with bare pipes zmx exits immediately
    /// rather than creating a daemon. The master fd is used to write
    /// commands and read output; the slave fd is given to the subprocess.
    struct PtyAttach {
        let process: Process
        /// The master side of the PTY — write to send keystrokes, read to
        /// receive terminal output.
        let masterFd: Int32

        func write(_ string: String) throws {
            guard let data = string.data(using: .utf8) else { return }
            try data.withUnsafeBytes { ptr in
                guard let base = ptr.baseAddress else { return }
                let n = Darwin.write(masterFd, base, ptr.count)
                if n < 0 {
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
                }
            }
        }

        /// Non-blocking drain of available bytes from the master fd.
        func readAvailable() -> String {
            var buf = [UInt8](repeating: 0, count: 4096)
            var result = ""
            while true {
                let n = buf.withUnsafeMutableBytes { ptr in
                    Darwin.read(masterFd, ptr.baseAddress!, ptr.count)
                }
                if n <= 0 { break }
                result += String(bytes: buf.prefix(n), encoding: .utf8) ?? ""
            }
            return result
        }

        func terminate() {
            // SIGTERM first; if the child doesn't exit within 2s, escalate to SIGKILL.
            // Without this bound, a wedged `zmx attach` would hang the test forever
            // (no per-test timeout in Swift Testing by default).
            process.terminate()
            let deadline = Date().addingTimeInterval(2.0)
            while process.isRunning && Date() < deadline {
                Thread.sleep(forTimeInterval: 0.05)
            }
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
                process.waitUntilExit()
            }
            Darwin.close(masterFd)
        }
    }

    /// Spawn a `zmx attach` child via a real PTY master/slave pair.
    /// - The slave PTY fd is passed as the child's stdin, stdout, stderr.
    /// - The master PTY fd is returned for the caller to read/write.
    static func spawnAttach(
        launcher: ZmxLauncher,
        sessionName: String
    ) throws -> PtyAttach {
        // Open a master PTY.
        let master = posix_openpt(O_RDWR | O_NOCTTY)
        guard master >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno),
                          userInfo: [NSLocalizedDescriptionKey: "posix_openpt failed"])
        }
        guard grantpt(master) == 0, unlockpt(master) == 0 else {
            Darwin.close(master)
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno),
                          userInfo: [NSLocalizedDescriptionKey: "grantpt/unlockpt failed"])
        }
        guard let slaveNamePtr = ptsname(master) else {
            Darwin.close(master)
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno),
                          userInfo: [NSLocalizedDescriptionKey: "ptsname failed"])
        }
        let slaveName = String(cString: slaveNamePtr)

        // Set the master fd to non-blocking so readAvailable() doesn't hang.
        let flags = fcntl(master, F_GETFL)
        _ = fcntl(master, F_SETFL, flags | O_NONBLOCK)

        // Open the slave side.
        let slave = Darwin.open(slaveName, O_RDWR | O_NOCTTY)
        guard slave >= 0 else {
            Darwin.close(master)
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno),
                          userInfo: [NSLocalizedDescriptionKey: "open slave PTY failed: \(slaveName)"])
        }

        // closeOnDealloc: false — we'll close the raw fd ourselves below
        // after process.run() so the parent doesn't keep the slave alive.
        let slaveHandle = FileHandle(fileDescriptor: slave, closeOnDealloc: false)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", launcher.attachCommand(sessionName: sessionName)]
        var env = launcher.subprocessEnv(from: ProcessInfo.processInfo.environment)
        // Force a deterministic shell so prompt-detection and SHELL
        // expansion behave the same on every dev machine.
        env["SHELL"] = "/bin/sh"
        process.environment = env
        process.standardInput = slaveHandle
        process.standardOutput = slaveHandle
        process.standardError = slaveHandle
        try process.run()

        // Standard POSIX pattern: now that the child has inherited the slave fd
        // via the Process's stdin/stdout/stderr, the parent must close its copy
        // so EOF on the master correctly signals "child gone." Without this, the
        // master-side reader would never see EOF if the child crashes, since
        // the parent's still-open slave keeps the kernel's pipe alive.
        Darwin.close(slave)

        return PtyAttach(process: process, masterFd: master)
    }

    /// Wait until accumulated output from `attach` contains `marker` or
    /// the deadline elapses.
    static func readUntil(
        marker: String,
        from attach: PtyAttach,
        deadline: TimeInterval = 5
    ) -> String {
        var accumulated = ""
        let end = Date().addingTimeInterval(deadline)
        while Date() < end {
            let chunk = attach.readAvailable()
            if !chunk.isEmpty {
                accumulated += chunk
                if accumulated.contains(marker) { return accumulated }
            } else {
                Thread.sleep(forTimeInterval: 0.05)
            }
        }
        return accumulated
    }

    // MARK: Tests

    @Test func sessionSurvivesClientDetachAndReattachRestoresMarker() throws {
        try Self.withScopedZmxDir { launcher in
            let session = launcher.sessionName(for: UUID())
            let marker = "MARKER_\(UUID().uuidString.prefix(8))"

            // ── First client: write the marker into the session. ──────
            let first = try Self.spawnAttach(launcher: launcher, sessionName: session)
            // Wait for zmx to start before writing the command.
            // zmx attach sends \u{001B}[2J\u{001B}[H (clear-screen) as its first
            // output when it connects; waiting for it confirms the daemon socket
            // exists and the inner shell is ready to accept input.
            _ = Self.readUntil(marker: "\u{001B}[2J", from: first, deadline: 5)
            // Echo the marker into the inner shell.
            try first.write("echo \(marker)\n")
            // Wait for the marker to appear in the live stream — proves
            // the shell is up and zmx is forwarding bytes. Use the full
            // output string (not just the echo), so we see the shell actually
            // executed the command, not just PTY echoing our keystrokes.
            let liveOutput = Self.readUntil(marker: marker, from: first)
            #expect(
                liveOutput.contains(marker),
                "marker never appeared in live output — got: \(liveOutput)"
            )

            // Detach by terminating the client process. Daemon should keep running.
            first.terminate()

            // ── Verify the daemon survived. ───────────────────────────
            let alive = try launcher.listSessions()
            #expect(
                alive.contains(session),
                "session \(session) didn't survive client detach; alive: \(alive)"
            )

            // ── Second client: reattach and verify marker is replayed. ─
            let second = try Self.spawnAttach(launcher: launcher, sessionName: session)
            let replay = Self.readUntil(marker: marker, from: second)
            #expect(
                replay.contains(marker),
                "reattach didn't restore marker; got: \(replay)"
            )

            // Cleanup
            second.terminate()
            launcher.kill(sessionName: session)
        }
    }

    @Test func killRemovesSessionFromList() throws {
        try Self.withScopedZmxDir { launcher in
            let session = launcher.sessionName(for: UUID())
            let attach = try Self.spawnAttach(launcher: launcher, sessionName: session)
            // Wait for the session to register before killing it.
            // zmx's clear-screen sequence confirms the daemon is ready.
            _ = Self.readUntil(marker: "\u{001B}[2J", from: attach, deadline: 3)
            attach.terminate()

            #expect(try launcher.listSessions().contains(session))
            launcher.kill(sessionName: session)
            #expect(!(try launcher.listSessions()).contains(session))
        }
    }

    @Test func killOfNonexistentSessionIsHarmless() throws {
        try Self.withScopedZmxDir { launcher in
            // Should not throw and should not crash.
            launcher.kill(sessionName: "espalier-doesnotexist")
        }
    }
}
