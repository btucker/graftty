import Foundation
import Testing
@testable import GrafttyKit

@Suite("@spec TEAM-8.1: When the application starts, the application shall best-effort run `claude mcp remove graftty-channel`, ignoring non-zero exit and logging failure.")
struct LegacyChannelCleanupTests {
    @Test func unregistersMCPServer() async {
        let exec = FakeCLIExecutor()
        exec.stub(
            command: "claude",
            args: ["mcp", "remove", "graftty-channel"],
            output: CLIOutput(stdout: "", stderr: "", exitCode: 0)
        )

        await LegacyChannelCleanup.unregisterMCPServer(executor: exec)

        let invokedArgs = exec.invocations.map(\.args)
        #expect(invokedArgs == [["mcp", "remove", "graftty-channel"]])
        #expect(exec.invocations.first?.command == "claude")
    }

    @Test func unregisterToleratesNonZeroExit() async {
        let exec = FakeCLIExecutor()
        exec.stub(
            command: "claude",
            args: ["mcp", "remove", "graftty-channel"],
            output: CLIOutput(stdout: "", stderr: "no such server", exitCode: 1)
        )

        // No throw; command was still attempted.
        await LegacyChannelCleanup.unregisterMCPServer(executor: exec)

        #expect(exec.invocations.count == 1)
    }

    @Test func unregisterToleratesMissingCLI() async {
        let exec = FakeCLIExecutor()
        exec.stub(
            command: "claude",
            args: ["mcp", "remove", "graftty-channel"],
            error: CLIError.notFound(command: "claude")
        )

        // No throw; logger absorbs it.
        await LegacyChannelCleanup.unregisterMCPServer(executor: exec)

        #expect(exec.invocations.count == 1)
    }
}
