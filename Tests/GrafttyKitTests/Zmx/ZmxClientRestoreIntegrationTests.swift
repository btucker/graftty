import Testing
import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
@testable import GrafttyKit

// Runs the bundled macOS zmx through ZmxNativeHostManagedIntegrationTests'
// helpers, which Linux excludes (linuxPendingKitTests).
#if os(macOS)
/// Bundled-zmx behavior around a client leaving or rejoining a session:
/// what the outer terminal is left with, and what a reattach replays.
@Suite("Zmx — attach client terminal restore", .serialized)
struct ZmxClientRestoreIntegrationTests {
    private typealias Native = ZmxNativeHostManagedIntegrationTests

    /// RIS followed by OSC 110/111/112 (reset foreground, background, cursor color).
    private static let terminalRestore = "\u{1B}c\u{1B}]110\u{1B}\\\u{1B}]111\u{1B}\\\u{1B}]112\u{1B}\\"
    private static let canonicalFlags = tcflag_t(ECHO | ICANON | ISIG)

    @Test("""
    @spec ZMX-9.9: When a bundled `zmx attach` client receives SIGTERM, SIGHUP, or SIGINT, it shall restore the outer terminal's termios and reset its modes, then terminate by that same signal, leaving the session running.
    """, .timeLimit(.minutes(1)))
    func signaledClientRestoresTerminalAndKeepsSession() throws {
        try Native.withScopedZmxDir { launcher in
            let session = launcher.sessionName(for: UUID())
            let owner = try Native.spawnHostManagedAttach(launcher: launcher, sessionName: session)
            defer {
                owner.terminate()
                launcher.kill(sessionName: session)
            }
            try Native.waitForAttachReady(owner)
            try Native.waitForSession(launcher: launcher, name: session, timeout: 5.0)

            for sig in [SIGTERM, SIGHUP, SIGINT] {
                try Self.signalClient(launcher: launcher, session: session, signal: sig)
                #expect(try launcher.listSessions().contains(session), "signal \(sig) ended the session")
            }

            try owner.write("printf '__OWNER_%s__\\n' ALIVE\n")
            let alive = Native.readUntil(marker: "__OWNER_ALIVE__", from: owner, deadline: 5.0)
            #expect(alive.contains("__OWNER_ALIVE__"))
        }
    }

    @Test("""
    @spec ZMX-9.10: When a bundled `zmx attach` client reattaches to a session, it shall reset text attributes before clearing the screen and the replay shall restore the session's cursor style.
    """, .timeLimit(.minutes(1)))
    func reattachResetsAttributesAndRestoresCursorStyle() throws {
        try Native.withScopedZmxDir { launcher in
            let session = launcher.sessionName(for: UUID())
            let first = try Native.spawnHostManagedAttach(launcher: launcher, sessionName: session)
            var firstRunning = true
            defer {
                if firstRunning { first.terminate() }
                launcher.kill(sessionName: session)
            }
            try Native.waitForAttachReady(first)
            try Native.disableEcho(in: first)
            // Steady bar cursor (DECSCUSR 6); the marker is assembled by
            // printf so command echo cannot satisfy the wait.
            try first.write("printf '\\033[6 q'; printf '__CURSOR_%s__\\n' SET\n")
            let set = Native.readUntil(marker: "__CURSOR_SET__", from: first, deadline: 5.0)
            #expect(set.contains("__CURSOR_SET__"))
            first.terminate()
            firstRunning = false
            try Native.waitForSession(launcher: launcher, name: session, timeout: 2.0)

            let second = try Native.spawnHostManagedAttach(launcher: launcher, sessionName: session)
            defer { second.terminate() }
            let replay = Native.readUntil(marker: "\u{1B}[6 q", from: second, deadline: 5.0)
            #expect(replay.hasPrefix("\u{1B}[0m\u{1B}[2J\u{1B}[H"), "clear did not reset attributes first: \(replay.debugDescription)")
            #expect(replay.contains("\u{1B}[6 q"), "replay did not restore the cursor style: \(replay.debugDescription)")
        }
    }

    /// Runs one attach client on a PTY whose slave this test keeps open, so
    /// the client's final output and termios survive its exit.
    private static func signalClient(launcher: ZmxLauncher, session: String, signal sig: Int32) throws {
        let master = posix_openpt(O_RDWR | O_NOCTTY)
        try #require(master >= 0, "posix_openpt failed")
        defer { GrafttyPOSIX.close(master) }
        try #require(grantpt(master) == 0 && unlockpt(master) == 0, "grantpt/unlockpt failed")
        let slaveName = try #require(GrafttyPOSIX.ptySlavePath(master))
        let slave = GrafttyPOSIX.open(slaveName, O_RDWR | O_NOCTTY)
        try #require(slave >= 0, "open slave PTY failed")
        defer { GrafttyPOSIX.close(slave) }
        _ = fcntl(master, F_SETFL, fcntl(master, F_GETFL) | O_NONBLOCK)
        // A 0x0 PTY makes the client size itself from the runner's /dev/tty.
        try PtyProcess.resize(masterFD: master, cols: 80, rows: 24)

        var original = termios()
        try #require(tcgetattr(slave, &original) == 0)

        var env = launcher.subprocessEnv(from: ProcessInfo.processInfo.environment)
        env["SHELL"] = "/bin/sh"
        env["TERM"] = env["TERM"] ?? "xterm-256color"
        let slaveHandle = FileHandle(fileDescriptor: slave, closeOnDealloc: false)
        let process = Process()
        process.executableURL = launcher.executable
        process.arguments = ["attach", session, "/bin/sh"]
        process.environment = env
        process.standardInput = slaveHandle
        process.standardOutput = slaveHandle
        process.standardError = slaveHandle
        try process.run()
        defer {
            // SIGTERM can leave a client blocked on unread output, so force it.
            if process.isRunning {
                _ = kill(process.processIdentifier, SIGKILL)
                process.waitUntilExit()
            }
        }
        let client = Native.PtyAttach(pid: process.processIdentifier, masterFd: master)

        var current = termios()
        let rawDeadline = Date().addingTimeInterval(5.0)
        while tcgetattr(slave, &current) == 0, current.c_lflag & canonicalFlags != 0 {
            try #require(process.isRunning && Date() < rawDeadline, "signal \(sig): client never entered raw mode")
            Thread.sleep(forTimeInterval: 0.02)
        }
        Thread.sleep(forTimeInterval: 0.2)
        _ = client.readAvailable()

        _ = kill(process.processIdentifier, sig)
        // Keep reading while the client exits: its TCSAFLUSH termios restore
        // waits until the master drains any output still queued for it.
        var output = ""
        let exitDeadline = Date().addingTimeInterval(5.0)
        while process.isRunning, Date() < exitDeadline {
            output += client.readAvailable()
            Thread.sleep(forTimeInterval: 0.02)
        }
        try #require(!process.isRunning, "signal \(sig): client still running 5 s after the signal")
        process.waitUntilExit()
        output += client.readAvailable()
        #expect(process.terminationReason == .uncaughtSignal, "signal \(sig): client exited normally")
        #expect(process.terminationStatus == sig, "signal \(sig): client died by \(process.terminationStatus)")

        #expect(output.contains(terminalRestore), "signal \(sig): no terminal reset in \(output.debugDescription)")
        try #require(tcgetattr(slave, &current) == 0)
        #expect(current.c_lflag == original.c_lflag, "signal \(sig): local modes not restored")
        #expect(current.c_iflag == original.c_iflag, "signal \(sig): input modes not restored")
        #expect(current.c_oflag == original.c_oflag, "signal \(sig): output modes not restored")
    }
}
#endif
