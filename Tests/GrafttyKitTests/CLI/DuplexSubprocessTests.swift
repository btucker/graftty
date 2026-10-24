import Foundation
import Testing
@testable import GrafttyKit
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

struct DuplexSubprocessTests {
    @Test("@spec REMOTE-26.23: When a provider proxy stops, fails, or loses its owner, the application shall serialize concurrent shutdown, close its streams, stop its process group and reap its child without callback deadlocks, and retain only bounded diagnostic output.")
    func duplexBytesAndCleanup() async throws {
        let child = try DuplexSubprocess(executable: URL(fileURLWithPath: "/bin/cat"), arguments: [], environment: [:])
        let pid = child.processID
        try child.input.write(contentsOf: Data("echo\n".utf8))
        #expect(try child.output.read(upToCount: 5) == Data("echo\n".utf8))
        await child.stop()
        await child.stop()
        #expect(kill(pid, 0) == -1)
        #expect(errno == ESRCH)
    }

    @Test("@spec REMOTE-30.22: When launching MCP servers or provider proxies, the application shall pass only their standard streams and shall close unrelated inherited file descriptors so child processes cannot retain parent connections.")
    func childDoesNotInheritUnrelatedDescriptors() async throws {
        let pipe = Pipe()
        let inherited = fcntl(pipe.fileHandleForReading.fileDescriptor, F_DUPFD, 100)
        try #require(inherited >= 100)
        defer { _ = close(inherited) }
        try #require(fcntl(inherited, F_SETFD, 0) == 0)
        let script = "import os,sys\ntry: os.fstat(int(sys.argv[1])); print('inherited')\nexcept OSError: print('closed')"
        let child = try DuplexSubprocess(executable: URL(fileURLWithPath: "/usr/bin/python3"),
            arguments: ["-c", script, String(inherited)], environment: [:])
        let output = try child.output.readToEnd() ?? Data()
        await child.stop()
        #expect(String(decoding: output, as: UTF8.self) == "closed\n")
    }

    @Test func diagnosticsAreBoundedAndNoisyChildCannotBlock() async throws {
        let child = try DuplexSubprocess(executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "head -c 131072 /dev/zero >&2; printf ready; cat"], environment: ["PATH": "/usr/bin:/bin"])
        #expect(try child.output.read(upToCount: 5) == Data("ready".utf8))
        await child.stop()
        #expect(child.diagnostics.utf8.count <= 65536)
    }

    @Test func missingExecutableFailsWithoutLeakingDescriptors() throws {
        #expect(throws: (any Error).self) {
            _ = try DuplexSubprocess(executable: URL(fileURLWithPath: "/graftty-missing-proxy"), arguments: [], environment: [:])
        }
    }

    @Test func concurrentStopsCompleteDuringStderrActivity() async throws {
        for _ in 0..<8 {
            let completions = AsyncThrowingStream<Bool, Error>.makeStream()
            defer { completions.continuation.finish() }
            // Dedicated threads keep a blocked NSLock or Foundation queue from
            // starving the cooperative executor that enforces the deadline.
            Thread {
                do {
                    let child = try Self.noisyChild()
                    let start = DispatchSemaphore(value: 0)
                    for _ in 0..<4 {
                        let scope = DuplexSubprocessScope()
                        _ = try scope.launch { child }
                        Thread {
                            guard start.wait(timeout: .now() + 5) == .success else {
                                completions.continuation.finish(throwing: StopDeadlineExceeded())
                                return
                            }
                            withExtendedLifetime(child) {
                                scope.close()
                                completions.continuation.yield(Self.isReaped(child.processID))
                            }
                        }.start()
                    }
                    for _ in 0..<4 { start.signal() }
                } catch { completions.continuation.finish(throwing: error) }
            }.start()
            let results = try await Self.waitForCompletions(completions.stream, count: 4)
            #expect(results.allSatisfy { $0 }, "Each concurrent stop must return after child reaping")
        }
    }

    @Test func releasingOwnerDuringStderrActivityStopsChild() async throws {
        for _ in 0..<8 {
            let completions = AsyncThrowingStream<Bool, Error>.makeStream()
            defer { completions.continuation.finish() }
            Thread {
                do {
                    var child: DuplexSubprocess? = try Self.noisyChild()
                    let pid = child!.processID
                    weak var owner = child
                    child = nil
                    let deadline = ContinuousClock.now.advanced(by: .seconds(2))
                    while owner != nil, ContinuousClock.now < deadline { Thread.sleep(forTimeInterval: 0.001) }
                    let released = owner == nil
                    owner = nil
                    completions.continuation.yield(released && Self.isReaped(pid))
                } catch { completions.continuation.finish(throwing: error) }
            }.start()
            #expect(try await Self.waitForCompletions(completions.stream, count: 1) == [true])
        }
    }

    private struct StopDeadlineExceeded: Error {}

    private static func noisyChild() throws -> DuplexSubprocess {
        let child = try DuplexSubprocess(executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "while :; do printf 'diagnostic-ready\\n' >&2; done"], environment: [:])
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while child.diagnostics.isEmpty, ContinuousClock.now < deadline { Thread.sleep(forTimeInterval: 0.001) }
        guard !child.diagnostics.isEmpty else { throw StopDeadlineExceeded() }
        return child
    }

    private static func isReaped(_ pid: Int32) -> Bool {
        var status: Int32 = 0
        return waitpid(pid, &status, WNOHANG) == -1 && errno == ECHILD
    }

    private static func waitForCompletions(_ stream: AsyncThrowingStream<Bool, Error>, count: Int) async throws -> [Bool] {
        try await withThrowingTaskGroup(of: [Bool].self) { group in
            group.addTask {
                var results: [Bool] = []
                for try await result in stream {
                    results.append(result)
                    if results.count == count { return results }
                }
                throw StopDeadlineExceeded()
            }
            group.addTask {
                try await Task.sleep(for: .seconds(5))
                throw StopDeadlineExceeded()
            }
            defer { group.cancelAll() }
            // Only cancellable stream/timer tasks are joined. A deadlocked
            // stop thread must not keep a failed RED test from returning.
            return try await group.next()!
        }
    }

    @Test(.timeLimit(.minutes(1))) func stopsDescendantsEvenAfterLeaderExits() async throws {
        let marker = FileManager.default.temporaryDirectory.appendingPathComponent("proxy-descendant-\(UUID())")
        defer { try? FileManager.default.removeItem(at: marker) }
        let child = try DuplexSubprocess(executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "(sleep 1; touch \"$1\") & printf ready", "proxy", marker.path],
            environment: ["PATH": "/usr/bin:/bin"])
        #expect(try child.output.read(upToCount: 5) == Data("ready".utf8))
        await child.stop()
        try await Task.sleep(for: .milliseconds(1200))
        #expect(!FileManager.default.fileExists(atPath: marker.path))
    }
}
