import Testing
import Foundation
import Darwin
@testable import GrafttyKit

@Suite("ZmxRunner")
struct ZmxRunnerTests {

    // We use /bin/echo as a stand-in for any executable — it's universally
    // present and its behavior (echo args + newline) is trivially verifiable.

    @Test func runReturnsStdoutOnZeroExit() throws {
        let result = try ZmxRunner.run(
            executable: URL(fileURLWithPath: "/bin/echo"),
            args: ["hello", "world"],
            env: [:]
        )
        #expect(result == "hello world\n")
    }

    @Test func runThrowsOnNonZeroExit() throws {
        // /usr/bin/false is a builtin-ish that always exits 1.
        #expect(throws: ZmxRunner.Error.self) {
            _ = try ZmxRunner.run(
                executable: URL(fileURLWithPath: "/usr/bin/false"),
                args: [],
                env: [:]
            )
        }
    }

    @Test func captureReturnsStdoutAndExitCodeWithoutThrowing() throws {
        let result = try ZmxRunner.capture(
            executable: URL(fileURLWithPath: "/usr/bin/false"),
            args: [],
            env: [:]
        )
        #expect(result.stdout == "")
        #expect(result.exitCode == 1)
    }

    @Test func captureAllReturnsStderrSeparately() throws {
        // /bin/sh -c 'echo out; echo err >&2; exit 2'
        let result = try ZmxRunner.captureAll(
            executable: URL(fileURLWithPath: "/bin/sh"),
            args: ["-c", "echo out; echo err >&2; exit 2"],
            env: [:]
        )
        #expect(result.stdout == "out\n")
        #expect(result.stderr == "err\n")
        #expect(result.exitCode == 2)
    }

    @Test("""
@spec ZMX-4.6: When a synchronous zmx subprocess emits more than a pipe buffer on stdout or stderr, the application shall drain both streams while the child is running so `pane show` and maintenance commands complete instead of deadlocking while waiting for the child to exit.
""", .timeLimit(.minutes(1)))
    func captureAllDrainsLargeStdoutAndStderrWhileChildRuns() throws {
        let byteCount = 256 * 1024
        let result = try ZmxRunner.captureAll(
            executable: URL(fileURLWithPath: "/bin/sh"),
            args: [
                "-c",
                """
                # `yes` may diagnose EPIPE after `head` has collected enough
                # bytes, so discard generator diagnostics from the measured streams.
                /usr/bin/yes o 2>/dev/null | /usr/bin/head -c \(byteCount)
                /usr/bin/yes e 2>/dev/null | /usr/bin/head -c \(byteCount) >&2
                """,
            ],
            env: [:],
            timeout: 2.0
        )

        #expect(result.stdout.utf8.count == byteCount)
        #expect(result.stderr.utf8.count == byteCount)
        #expect(result.exitCode == 0)
    }

    @Test func captureDoesNotWaitForDescendantHoldingStdoutOpen() throws {
        let pidFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("graftty-zmx-runner-descendant-\(UUID().uuidString).pid")
        defer { try? FileManager.default.removeItem(at: pidFile) }

        let start = Date()
        let result = try ZmxRunner.capture(
            executable: URL(fileURLWithPath: "/bin/sh"),
            args: ["-c", "/bin/sleep 2 & echo $! > \"$PID_FILE\"; echo ready"],
            env: ["PID_FILE": pidFile.path],
            timeout: 1.0
        )
        let elapsed = Date().timeIntervalSince(start)

        #expect(result.stdout == "ready\n")
        #expect(result.exitCode == 0)
        #expect(elapsed < 1.0)

        if let childPID = try? Self.pid(from: pidFile) {
            _ = kill(childPID, SIGTERM)
        }
    }

    @Test("""
@spec ZMX-4.5: When the application invokes synchronous zmx maintenance commands such as `zmx list --short` or `zmx kill --force <session>`, the subprocess wrapper shall apply a bounded timeout and terminate the command if it does not exit promptly. Cleanup paths, including test teardown, shall not block indefinitely on a degraded zmx daemon, because a wedged cleanup can leave `zmx attach` clients and their PTYs orphaned.
""", .timeLimit(.minutes(1)))
    func captureThrowsOnTimeout() throws {
        let pidFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("graftty-zmx-runner-timeout-\(UUID().uuidString).pid")
        defer { try? FileManager.default.removeItem(at: pidFile) }

        #expect(throws: ZmxRunner.Error.timedOut) {
            _ = try ZmxRunner.capture(
                executable: URL(fileURLWithPath: "/bin/sh"),
                args: ["-c", "/bin/sleep 5 & echo $! > \"$PID_FILE\"; wait"],
                env: ["PID_FILE": pidFile.path],
                timeout: 0.2
            )
        }

        let childPID = try Self.pid(from: pidFile)
        let deadline = Date().addingTimeInterval(1.0)
        while Self.processExists(childPID), Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        #expect(!Self.processExists(childPID))
    }

    @Test func captureChecksTimeoutWhileStdoutRemainsBusy() throws {
        let start = Date()
        #expect(throws: ZmxRunner.Error.timedOut) {
            _ = try ZmxRunner.capture(
                executable: URL(fileURLWithPath: "/bin/sh"),
                args: [
                    "-c",
                    """
                    writers=""
                    for _ in 1 2 3 4 5 6 7 8; do
                        /usr/bin/yes busy &
                        writers="$writers $!"
                    done
                    /bin/sleep 0.5
                    kill $writers
                    wait $writers 2>/dev/null
                    """,
                ],
                env: [:],
                timeout: 0.05
            )
        }
        #expect(Date().timeIntervalSince(start) < 1.5)
    }

    @Test func envIsPassedToTheChild() throws {
        let result = try ZmxRunner.run(
            executable: URL(fileURLWithPath: "/bin/sh"),
            args: ["-c", "echo $ZMX_TEST_VAR"],
            env: ["ZMX_TEST_VAR": "marker"]
        )
        #expect(result == "marker\n")
    }

    private static func pid(from file: URL) throws -> Int32 {
        let pidText = try String(contentsOf: file, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return try #require(Int32(pidText))
    }

    private static func processExists(_ pid: Int32) -> Bool {
        errno = 0
        if kill(pid, 0) == 0 { return true }
        return errno != ESRCH
    }
}
