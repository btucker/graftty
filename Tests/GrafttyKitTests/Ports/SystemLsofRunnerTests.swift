// Tests/GrafttyKitTests/Ports/SystemLsofRunnerTests.swift
import Testing
import Foundation
@testable import GrafttyKit

@Suite("SystemLsofRunner")
struct SystemLsofRunnerTests {
    /// `-b -w` keeps lsof off `stat`/`readlink` (which fork a child and wait
    /// up to lsof's own 15 s default on an unreachable network mount), so
    /// a healthy scan fits inside the 5 s bound.
    private static let args = ["-b", "-w", "-nP", "-a", "-iTCP", "-sTCP:LISTEN", "-p", "42"]

    @Test("@spec PORTS-1.6: The application shall bound each `lsof` port-scan subprocess with a 5-second timeout, and if that timeout expires, then the application shall treat the scan as an lsof failure so the next tick can scan again.")
    func lsofIsBoundedByTimeout() async {
        let output = "node 42 me 3u IPv4 0x1 0t0 TCP 127.0.0.1:3000 (LISTEN)"
        let exec = FakeCLIExecutor()
        exec.stub(command: "lsof", args: Self.args, output: CLIOutput(stdout: output, stderr: "", exitCode: 0))
        let runner = SystemLsofRunner(executor: exec)
        #expect(await runner.run(pids: "42") == output)
        #expect(exec.invocations.map(\.timeout) == [.seconds(5)])

        exec.stub(command: "lsof", args: Self.args, error: .timedOut(command: "lsof", seconds: 5))
        #expect(await runner.run(pids: "42") == nil)
    }
}
