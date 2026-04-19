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

    // All external tool output that we parse (git diff --shortstat,
    // gh pr checks, zmx list, etc.) has English word markers baked in
    // at call sites ("insertion", "deletion", "pass"). On a user with
    // `LANG=de_DE.UTF-8` (or any non-English locale) those tools may
    // emit localized messages that our parsers won't match. Force
    // LC_ALL=C on every invocation so output stays English regardless
    // of the user's shell settings.

    @Test func enrichedEnvironmentForcesCLocaleEvenWhenBaseIsLocalized() {
        let env = CLIRunner.enrichedEnvironment(base: [
            "PATH": "/usr/bin",
            "LANG": "de_DE.UTF-8",
            "LC_MESSAGES": "fr_FR.UTF-8",
            "LC_ALL": "ja_JP.UTF-8",
        ])
        #expect(env["LC_ALL"] == "C")
    }

    @Test func enrichedEnvironmentAddsCLocaleWhenUnset() {
        let env = CLIRunner.enrichedEnvironment(base: ["PATH": "/usr/bin"])
        #expect(env["LC_ALL"] == "C")
    }

    /// Regression guard for the pipe buffer deadlock: if we read stdout only
    /// after the process exits, a child that writes more than the pipe
    /// capacity (~16–64 KB on macOS) blocks on write and never terminates.
    /// Emits exactly 262144 bytes ("1\n" × 131072) and asserts the full
    /// payload comes through. Without `readabilityHandler` draining, this
    /// test hangs forever.
    @Test func largeStdoutDoesNotDeadlock() async throws {
        let lineCount = 131072 // 131072 × 2 bytes = 262144 bytes (256 KiB)
        let output = try await runner.run(
            command: "sh",
            args: ["-c", "yes 1 | head -n \(lineCount)"],
            at: NSTemporaryDirectory()
        )
        #expect(output.exitCode == 0)
        #expect(output.stdout.utf8.count == lineCount * 2)
        // Spot-check content integrity: all lines should be "1".
        let lines = output.stdout.split(separator: "\n", omittingEmptySubsequences: false)
        // split produces lineCount + 1 elements because of the trailing newline.
        #expect(lines.count == lineCount + 1)
        #expect(lines.first == "1")
        #expect(lines[lineCount - 1] == "1")
    }
}
