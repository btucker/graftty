import Testing
import Foundation
@testable import EspalierKit

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

    @Test func envIsPassedToTheChild() throws {
        let result = try ZmxRunner.run(
            executable: URL(fileURLWithPath: "/bin/sh"),
            args: ["-c", "echo $ZMX_TEST_VAR"],
            env: ["ZMX_TEST_VAR": "marker"]
        )
        #expect(result == "marker\n")
    }
}
