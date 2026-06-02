import Testing
import Foundation
@testable import GrafttyKit

private struct FakeExecutor: CLIExecutor {
    let outputs: [String: CLIOutput]   // keyed by command basename
    func run(command: String, args: [String], at directory: String) async throws -> CLIOutput {
        try await capture(command: command, args: args, at: directory)
    }
    func capture(command: String, args: [String], at directory: String) async throws -> CLIOutput {
        outputs[command] ?? CLIOutput(stdout: "", stderr: "", exitCode: 0)
    }
}

@MainActor
@Suite("ClaudeSessionRegistry refresh populates liveness and survives failure (AGENT-2.3 refresh-level).")
struct ClaudeSessionRegistryTests {
    private func registry(json: String, ps: String, claudeCmd: String = "claude")
        -> ClaudeSessionRegistry {
        let exec = FakeExecutor(outputs: [
            claudeCmd: CLIOutput(stdout: json, stderr: "", exitCode: 0),
            "ps": CLIOutput(stdout: ps, stderr: "", exitCode: 0),
        ])
        return ClaudeSessionRegistry(executor: exec, claudePath: claudeCmd)
    }

    @Test func refreshPopulatesLiveness() async {
        let r = registry(
            json: #"[{"pid":100,"cwd":"/a","kind":"interactive","sessionId":"s","startedAt":1,"status":"busy"}]"#,
            ps: "100 claude ZMX_SESSION=graftty-aaaa1111")
        await r.refresh()
        #expect(r.livenessBySession["graftty-aaaa1111"] == .busy)
    }

    @Test func failedClaudeYieldsEmpty() async {
        let exec = FakeExecutor(outputs: [
            "claude": CLIOutput(stdout: "", stderr: "boom", exitCode: 1),
        ])
        let r = ClaudeSessionRegistry(executor: exec, claudePath: "claude")
        await r.refresh()
        #expect(r.livenessBySession.isEmpty)
    }
}
