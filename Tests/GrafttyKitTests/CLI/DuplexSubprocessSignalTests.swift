import Foundation
import Testing
@testable import GrafttyKit
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

@Suite("@spec REMOTE-30.25: When launching MCP servers or provider proxies from a thread with blocked signals, the application shall give the child an empty signal mask and default signal dispositions, preserve the launching thread's mask, and allow the child to receive SIGTERM and SIGCHLD.")
struct DuplexSubprocessSignalTests {
    @Test func childMaskIsEmptyAndParentMaskIsPreserved() throws {
        let scope = DuplexSubprocessScope()
        defer { scope.close() }
        let child = try withBlockedSignals {
            try scope.launch {
                try DuplexSubprocess(executable: URL(fileURLWithPath: "/usr/bin/python3"), arguments: ["-c", """
                    import os, signal
                    blocked = signal.pthread_sigmask(signal.SIG_BLOCK, [])
                    print(','.join(str(int(s)) for s in sorted(blocked)), flush=True)
                    print(int(signal.getsignal(signal.SIGTERM) == signal.SIG_DFL), flush=True)
                    print(int(signal.getsignal(signal.SIGCHLD) == signal.SIG_DFL), flush=True)
                    print(int(os.getpgrp() == os.getpid()), flush=True)
                    # Keep the process alive while Linux /proc is inspected.
                    os.read(0, 1)
                    """], environment: [:])
            }
        }
        #expect(try readLine(child.output) == "")
        #expect(try readLine(child.output) == "1")
        #expect(try readLine(child.output) == "1")
        #expect(try readLine(child.output) == "1")
        #if os(Linux)
        let status = try String(contentsOfFile: "/proc/\(child.processID)/status", encoding: .utf8)
        let mask = try #require(status.split(separator: "\n").first { $0.hasPrefix("SigBlk:") })
        #expect(UInt64(mask.dropFirst("SigBlk:".count).trimmingCharacters(in: .whitespaces), radix: 16) == 0)
        #endif
    }

    @Test func childReceivesTerminationAndChildExitSignals() throws {
        let scope = DuplexSubprocessScope()
        defer { scope.close() }
        let child = try withBlockedSignals {
            try scope.launch {
                try DuplexSubprocess(executable: URL(fileURLWithPath: "/usr/bin/python3"), arguments: ["-c", """
                    import os, signal, sys, time
                    signal.signal(signal.SIGCHLD, lambda *_: os.write(1, b'chld\\n'))
                    signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
                    descendant = os.fork()
                    if descendant == 0:
                        os._exit(0)
                    os.waitpid(descendant, 0)
                    while True:
                        time.sleep(1)
                    """], environment: [:])
            }
        }
        // Receipt proves the child can observe and reap its own descendants.
        #expect(try readLine(child.output) == "chld")
        try #require(kill(child.processID, SIGTERM) == 0)
        #expect(try readLine(child.output) == nil, "SIGTERM should close stdout without stop()'s SIGKILL")
    }

    /// No suspension may occur between masking and restoration. This changes
    /// only the current test thread, never the process-wide dispositions.
    private func withBlockedSignals<T>(_ body: () throws -> T) throws -> T {
        var blocked = sigset_t()
        sigemptyset(&blocked)
        for signal in [SIGTERM, SIGCHLD, SIGINT, SIGHUP] { sigaddset(&blocked, signal) }
        var original = sigset_t()
        try #require(pthread_sigmask(SIG_BLOCK, &blocked, &original) == 0)
        defer { pthread_sigmask(SIG_SETMASK, &original, nil) }
        let result = try body()
        var after = sigset_t()
        try #require(pthread_sigmask(SIG_BLOCK, nil, &after) == 0)
        for signal in Int32(1)..<Int32(NSIG) {
            let expected = sigismember(&original, signal) == 1 || sigismember(&blocked, signal) == 1
            #expect((sigismember(&after, signal) == 1) == expected)
        }
        return result
    }

    private struct ReadDeadlineExceeded: Error {}

    /// Bound failures without relying on a blocked child's eventual exit.
    private func readLine(_ handle: FileHandle) throws -> String? {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        var bytes = Data()
        while ContinuousClock.now < deadline {
            var descriptor = pollfd(fd: handle.fileDescriptor, events: Int16(POLLIN), revents: 0)
            let ready = poll(&descriptor, 1, 50)
            if ready < 0 && errno == EINTR { continue }
            guard ready >= 0 else { throw POSIXError(.EIO) }
            guard ready > 0 else { continue }
            guard let byte = try handle.read(upToCount: 1), !byte.isEmpty else {
                return bytes.isEmpty ? nil : String(decoding: bytes, as: UTF8.self)
            }
            if byte == Data([10]) { return String(decoding: bytes, as: UTF8.self) }
            bytes.append(byte)
        }
        throw ReadDeadlineExceeded()
    }
}
