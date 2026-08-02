import Foundation
import Testing
import Darwin
@testable import GrafttyKit

@Suite("WorktreeStatsStore — bounded local Git polling", .serialized)
struct WorktreeStatsStoreLocalGitTimeoutTests {
    @Test("""
    @spec DIVERGE-4.12: When recurring divergence computation invokes local Git commands, the application shall bound every subprocess below the 30-second in-flight abandonment threshold so a filesystem-blocked command is terminated before a replacement can be dispatched, preventing child-process and pipe-descriptor accumulation.
    """)
    func recurringComputeBoundsEveryGitSubprocess() async throws {
        let executor = TimeoutRecordingCLIExecutor()
        GitRunner.configure(executor: executor)
        defer { GitRunner.resetForTests() }

        let result = await WorktreeStatsStore.defaultCompute(
            "/worktree",
            "/repo",
            "feature",
            nil
        )

        #expect(result.stats != nil)
        let invocations = executor.recordedInvocations
        #expect(invocations.count == 7)
        #expect(
            invocations.allSatisfy { $0.timeout == .seconds(20) },
            "every poll-driven local Git subprocess must finish before the 30-second replacement threshold"
        )
    }

    @Test(
        "A Git process blocked reading repository metadata is terminated at its deadline.",
        .timeLimit(.minutes(1))
    )
    func blockedMetadataReadIsTerminated() async throws {
        let repo = FileManager.default.temporaryDirectory
            .appendingPathComponent("graftty-blocked-git-\(UUID().uuidString)")
        let gitDirectory = repo.appendingPathComponent(".git")
        try FileManager.default.createDirectory(
            at: gitDirectory.appendingPathComponent("objects"),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: gitDirectory.appendingPathComponent("refs"),
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: repo) }

        let headPath = gitDirectory.appendingPathComponent("HEAD").path
        guard mkfifo(headPath, 0o600) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }

        do {
            _ = try await CLIRunner().run(
                command: "git",
                args: ["rev-parse", "--git-dir"],
                at: repo.path,
                timeout: .milliseconds(100)
            )
            Issue.record("the blocked Git process should have timed out")
        } catch CLIError.timedOut(let command, _) {
            #expect(command == "git")
        }
    }
}

private final class TimeoutRecordingCLIExecutor: CLIExecutor, @unchecked Sendable {
    struct Invocation: Sendable {
        let args: [String]
        let timeout: Duration?
    }

    private let lock = NSLock()
    private var invocations: [Invocation] = []

    var recordedInvocations: [Invocation] {
        lock.lock()
        defer { lock.unlock() }
        return invocations
    }

    func run(command: String, args: [String], at directory: String) async throws -> CLIOutput {
        try await run(command: command, args: args, at: directory, timeout: nil)
    }

    func run(
        command: String,
        args: [String],
        at directory: String,
        timeout: Duration?
    ) async throws -> CLIOutput {
        record(args: args, timeout: timeout)
        return output(for: args)
    }

    func capture(command: String, args: [String], at directory: String) async throws -> CLIOutput {
        record(args: args, timeout: nil)
        return output(for: args)
    }

    func capture(
        command: String,
        args: [String],
        at directory: String,
        timeout: Duration?
    ) async throws -> CLIOutput {
        record(args: args, timeout: timeout)
        return output(for: args)
    }

    private func record(args: [String], timeout: Duration?) {
        lock.lock()
        defer { lock.unlock() }
        invocations.append(Invocation(args: args, timeout: timeout))
    }

    private func output(for args: [String]) -> CLIOutput {
        let stdout = args.first == "rev-list" ? "0\n" : ""
        return CLIOutput(stdout: stdout, stderr: "", exitCode: 0)
    }
}
