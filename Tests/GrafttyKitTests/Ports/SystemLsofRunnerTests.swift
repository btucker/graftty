// Tests/GrafttyKitTests/Ports/SystemLsofRunnerTests.swift
import Testing
import Foundation
@testable import GrafttyKit

@Suite("@spec PORTS-1.6: The application shall bound each `lsof` port-scan subprocess with a 5-second timeout, and if that timeout expires, then the application shall treat the scan as an lsof failure so the next tick can scan again.")
struct SystemLsofRunnerTests {
    /// `-b -w` keeps lsof off `stat`/`readlink` (which fork a child and wait
    /// up to lsof's own 15 s default on an unreachable network mount), so
    /// a healthy scan fits inside the 5 s bound.
    private static let args = ["-b", "-w", "-nP", "-a", "-iTCP", "-sTCP:LISTEN", "-p", "42"]

    @Test
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

    /// A timed-out scan reaches `PortScanner` as a nil lsof result. The
    /// scanner must release its single-flight guard so the next tick scans
    /// and publishes again.
    @Test func scannerRecoversOnNextTickAfterTimedOutScan() async {
        let runner = StubLsofRunner(output: nil)
        let scanner = PortScanner(runner: runner, walker: StubProcessTreeWalker(result: []))
        let pane = PaneSlotID()
        await scanner.registerPane(pane, shellPID: 1234)

        await scanner.tick()
        #expect(await scanner.bindings(for: pane).isEmpty)

        await runner.setOutput("node 1234 me 3u IPv4 0x1 0t0 TCP 127.0.0.1:3000 (LISTEN)")
        await scanner.tick()
        #expect(await scanner.bindings(for: pane).map(\.port) == [3000])
        #expect(await runner.calls.count == 2)
    }
}
