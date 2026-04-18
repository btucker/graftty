import Testing
import Foundation
import Darwin
@testable import EspalierKit

@Suite("PtyProcess — PTY allocation + fork/exec")
struct PtyProcessTests {

    /// Read from the master fd until `stop` returns true or the deadline
    /// passes. Tolerates the macOS PTY-master behavior where reads return
    /// -1 (EIO) after the slave closes: treat as "stop reading" but don't
    /// fail the test on its own.
    private static func drain(masterFD: Int32, deadlineSeconds: TimeInterval, stop: (Data) -> Bool) -> Data {
        var collected = Data()
        var buf = [UInt8](repeating: 0, count: 256)
        let deadline = Date().addingTimeInterval(deadlineSeconds)
        while Date() < deadline {
            var readSet = fd_set()
            fdZero(&readSet)
            fdSet(masterFD, &readSet)
            var tv = timeval(tv_sec: 0, tv_usec: 100_000)  // 100 ms poll
            let ready = select(masterFD + 1, &readSet, nil, nil, &tv)
            if ready <= 0 { continue }
            let n = buf.withUnsafeMutableBufferPointer { Darwin.read(masterFD, $0.baseAddress, $0.count) }
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
}

// MARK: - fd_set helpers (Swift doesn't expose FD_ZERO/FD_SET as macros)

private func fdZero(_ set: inout fd_set) {
    set = fd_set()
}

private func fdSet(_ fd: Int32, _ set: inout fd_set) {
    let intOffset = Int(fd) / 32
    let bitOffset = Int(fd) % 32
    let mask: Int32 = 1 << bitOffset
    withUnsafeMutablePointer(to: &set.fds_bits) { ptr in
        let tuple = ptr
        let raw = UnsafeMutableRawPointer(tuple)
        let array = raw.assumingMemoryBound(to: Int32.self)
        array[intOffset] |= mask
    }
}
