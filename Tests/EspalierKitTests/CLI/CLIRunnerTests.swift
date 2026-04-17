import Testing
import Foundation
@testable import EspalierKit

@Suite("CLIRunner Tests")
struct CLIRunnerTests {
    let runner = CLIRunner()

    @Test func echoesStdout() async throws {
        let output = try await runner.run(command: "echo", args: ["hello"], at: NSTemporaryDirectory())
        #expect(output.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "hello")
        #expect(output.exitCode == 0)
    }

    @Test func capturesStderrAndExitCode() async throws {
        // `sh -c 'echo oops 1>&2; exit 3'` — capture, don't throw.
        let output = try await runner.capture(
            command: "sh",
            args: ["-c", "echo oops 1>&2; exit 3"],
            at: NSTemporaryDirectory()
        )
        #expect(output.stderr.contains("oops"))
        #expect(output.exitCode == 3)
    }

    @Test func runThrowsOnNonZeroExit() async throws {
        do {
            _ = try await runner.run(
                command: "sh",
                args: ["-c", "exit 5"],
                at: NSTemporaryDirectory()
            )
            Issue.record("should have thrown")
        } catch CLIError.nonZeroExit(_, let code, _) {
            #expect(code == 5)
        }
    }

    @Test func notFoundForMissingCommand() async throws {
        do {
            _ = try await runner.run(
                command: "totally-not-a-real-command-zzzzz",
                args: [],
                at: NSTemporaryDirectory()
            )
            Issue.record("should have thrown")
        } catch CLIError.notFound(let cmd) {
            #expect(cmd == "totally-not-a-real-command-zzzzz")
        }
    }

    @Test func pathEnrichmentIncludesHomebrewAndLocal() {
        let env = CLIRunner.enrichedEnvironment(base: ["PATH": "/usr/bin"])
        let path = env["PATH"] ?? ""
        let parts = path.split(separator: ":").map(String.init)
        #expect(parts.contains("/opt/homebrew/bin"))
        #expect(parts.contains("/usr/local/bin"))
        #expect(parts.contains("/usr/bin"))
        // Homebrew should come before /usr/bin so brewed git beats Xcode's.
        let homebrewIdx = parts.firstIndex(of: "/opt/homebrew/bin") ?? Int.max
        let usrBinIdx = parts.firstIndex(of: "/usr/bin") ?? -1
        #expect(homebrewIdx < usrBinIdx)
    }

    @Test func pathEnrichmentDoesNotDuplicate() {
        let env = CLIRunner.enrichedEnvironment(base: [
            "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin"
        ])
        let path = env["PATH"] ?? ""
        let parts = path.split(separator: ":").map(String.init)
        #expect(parts.filter { $0 == "/opt/homebrew/bin" }.count == 1)
        #expect(parts.filter { $0 == "/usr/local/bin" }.count == 1)
    }
}
