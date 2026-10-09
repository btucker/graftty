import Testing
import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
@testable import GrafttyKit

/// `.serialized` because `PtyProcess.spawn` uses raw `fork(2)`. Concurrent
/// forks from Swift Testing tasks can deadlock a child in process-global
/// runtime state before `execve`.
@Suite("PtyProcess — PTY allocation + fork/exec", .serialized)
struct PtyProcessTests {

    @Test("@spec REMOTE-23.8: When the host ignores termination signals for its event loop, the application shall restore normal termination signals in spawned terminal processes.")
    func childRestoresIgnoredTerminationSignal() throws {
        let previous = signal(SIGTERM, SIG_IGN)
        defer { _ = signal(SIGTERM, previous) }
        let child = try PtyProcess.spawn(argv: ["/bin/sh", "-c", "kill -TERM $$; exit 77"], env: [:])
        _ = signal(SIGTERM, previous)
        defer { close(child.masterFD) }
        var status: Int32 = 0
        #expect(waitpid(child.pid, &status, 0) == child.pid)
        #expect(status & 0x7f == SIGTERM)
    }

    /// Read from the master fd until `stop` returns true or the deadline
    /// passes. Tolerates the macOS PTY-master behavior where reads return
    /// -1 (EIO) after the slave closes: treat as "stop reading" but don't
    /// fail the test on its own.
    private static func drain(masterFD: Int32, deadlineSeconds: TimeInterval, stop: (Data) -> Bool) -> Data {
        var collected = Data()
        var buf = [UInt8](repeating: 0, count: 256)
        let deadline = Date().addingTimeInterval(deadlineSeconds)
        while Date() < deadline {
            var descriptor = pollfd(fd: masterFD, events: Int16(POLLIN), revents: 0)
            let ready = GrafttyPOSIX.poll(&descriptor, 1, 100)
            if ready <= 0 { continue }
            let n = buf.withUnsafeMutableBufferPointer { GrafttyPOSIX.read(masterFD, $0.baseAddress, $0.count) }
            if n <= 0 { break }
            collected.append(contentsOf: buf[0..<n])
            if stop(collected) { break }
        }
        return collected
    }

    @Test func spawns_childEchoAndExit() throws {
        // Use `echo` (with newline) + a long-enough sleep. The newline
        // flushes the PTY line buffer; the sleep keeps the slave open
        // long enough for the parent to consume the bytes before slave
        // close turns the master into EIO territory.
        let spawn = try PtyProcess.spawn(
            argv: ["/bin/sh", "-c", "echo hello; sleep 1"],
            env: [:]
        )
        defer { close(spawn.masterFD) }

        let collected = Self.drain(masterFD: spawn.masterFD, deadlineSeconds: 5) {
            String(data: $0, encoding: .utf8)?.contains("hello") == true
        }
        #expect(String(data: collected, encoding: .utf8)?.contains("hello") == true,
                "expected 'hello' in output; got \(collected.count) bytes: \(String(data: collected, encoding: .utf8) ?? "<non-utf8>")")

        // Kill the sleep so waitpid doesn't block on the full second.
        kill(spawn.pid, SIGTERM)
        var status: Int32 = 0
        _ = waitpid(spawn.pid, &status, 0)
    }

    @Test func childHasControllingTerminal() throws {
        // `tty -s` exits 0 iff stdin is a terminal. If our PTY setup is
        // correct, the child should report success.
        let spawn = try PtyProcess.spawn(
            argv: ["/usr/bin/tty", "-s"],
            env: [:]
        )
        defer { close(spawn.masterFD) }
        var status: Int32 = 0
        _ = waitpid(spawn.pid, &status, 0)
        let exitCode = (status >> 8) & 0xFF
        #expect(exitCode == 0)
    }

    @Test func resize_ioctlAppliesDimensions() throws {
        let spawn = try PtyProcess.spawn(
            argv: ["/bin/sh", "-c", "sleep 0.2; stty size; sleep 1"],
            env: [:]
        )
        defer { close(spawn.masterFD) }
        try PtyProcess.resize(masterFD: spawn.masterFD, cols: 42, rows: 13)

        let collected = Self.drain(masterFD: spawn.masterFD, deadlineSeconds: 5) {
            String(data: $0, encoding: .utf8)?.contains("13 42") == true
        }
        kill(spawn.pid, SIGTERM)
        var status: Int32 = 0
        _ = waitpid(spawn.pid, &status, 0)
        #expect(String(data: collected, encoding: .utf8)?.contains("13 42") == true,
                "expected '13 42' in output; got \(collected.count) bytes: \(String(data: collected, encoding: .utf8) ?? "<non-utf8>")")
    }

    @Test func fullWindowSizeAppliesCellAndPixelDimensions() throws {
        let initial = PtyProcess.WindowSize(
            cols: 120,
            rows: 40,
            xpixel: 1_440,
            ypixel: 960
        )
        let spawn = try PtyProcess.spawn(
            argv: ["/bin/sh", "-c", "sleep 2"],
            env: [:],
            initialWindowSize: initial
        )
        defer {
            kill(spawn.pid, SIGTERM)
            close(spawn.masterFD)
            var status: Int32 = 0
            _ = waitpid(spawn.pid, &status, 0)
        }

        #expect(PtyProcess.currentWindowSize(masterFD: spawn.masterFD) == initial)

        let pixelOnlyResize = PtyProcess.WindowSize(
            cols: 120,
            rows: 40,
            xpixel: 1_800,
            ypixel: 1_200
        )
        try PtyProcess.resize(masterFD: spawn.masterFD, windowSize: pixelOnlyResize)

        #expect(PtyProcess.currentWindowSize(masterFD: spawn.masterFD) == pixelOnlyResize)
    }

    @Test("""
    @spec WEB-4.6: When the application forks a `zmx attach` child for a web WebSocket, the child shall close every inherited file descriptor above 2 before `execve`. Rationale: without this, parent-opened sockets (notably the `WebServer` listen socket) without `FD_CLOEXEC` leak into the zmx child and survive the parent. After Graftty quits, the listen port stays bound to an orphan zmx process and the next Graftty launch cannot rebind.
    """)
    func inheritedFileDescriptorsAboveStdioAreClosedBeforeExec() throws {
        let temp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pty-fd-leak-\(UUID().uuidString)")
        _ = FileManager.default.createFile(atPath: temp.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: temp) }

        let rawFD = GrafttyPOSIX.open(temp.path, O_RDWR)
        #expect(rawFD > 2)
        let duplicatedFD = fcntl(rawFD, F_DUPFD, 200)
        close(rawFD)
        let inheritedFD = try #require(duplicatedFD >= 200 ? duplicatedFD : nil)
        #expect(inheritedFD >= 200)
        defer { close(inheritedFD) }

        let script = "if sh -c ': >&\(inheritedFD)' 2>/dev/null; then echo leaked; else echo closed; fi; sleep 1"
        let spawn = try PtyProcess.spawn(
            argv: ["/bin/sh", "-c", script],
            env: [:]
        )
        defer { close(spawn.masterFD) }

        let collected = Self.drain(masterFD: spawn.masterFD, deadlineSeconds: 5) {
            let text = String(data: $0, encoding: .utf8) ?? ""
            return text.contains("closed") || text.contains("leaked")
        }
        kill(spawn.pid, SIGTERM)
        var status: Int32 = 0
        _ = waitpid(spawn.pid, &status, 0)

        let text = String(data: collected, encoding: .utf8) ?? ""
        #expect(text.contains("closed"), "expected child fd \(inheritedFD) to be closed; got \(text)")
        #expect(!text.contains("leaked"), "child inherited fd \(inheritedFD): \(text)")
    }
}
