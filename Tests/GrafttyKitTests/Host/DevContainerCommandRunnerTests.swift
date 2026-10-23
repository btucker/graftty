import Foundation
import Testing
@testable import GrafttyKit

@Suite("Dev Container command completion")
struct DevContainerCommandRunnerTests {
    @Test("@spec REMOTE-26.28: When a Dev Container command exits while a background descendant remains running, the application shall return the command's output and exit status without waiting for the descendant.")
    func backgroundDescendantDoesNotHoldCompletion() async throws {
        let started = ContinuousClock.now
        let output = try await DevContainerCommandRunner().capture(
            command: "/bin/sh", args: ["-c", "printf ready; printf detail >&2; sleep 6 & exit 7"],
            at: FileManager.default.temporaryDirectory.path, timeout: .seconds(10))
        #expect(output.stdout == "ready")
        #expect(output.stderr == "detail")
        #expect(output.exitCode == 7)
        #expect(ContinuousClock.now - started < .seconds(3))
    }

    @Test("Large output, working directory, and late failure survive command capture")
    func capturesCompleteOutputAndFailure() async throws {
        let root = CanonicalPath.canonicalize(FileManager.default.temporaryDirectory.path)
        let output = try await DevContainerCommandRunner().capture(command: "/bin/sh",
            args: ["-c", "head -c 200000 /dev/zero | tr '\\0' a; printf tail; pwd >&2; exit 9"], at: root)
        #expect(output.stdout.utf8.count == 200_004)
        #expect(output.stdout.hasSuffix("tail"))
        #expect(output.stderr == root + "\n")
        #expect(output.exitCode == 9)
        await #expect(throws: CLIError.nonZeroExit(command: "/bin/sh", exitCode: 9, stderr: "failed")) {
            try await DevContainerCommandRunner().run(command: "/bin/sh", args: ["-c", "printf failed >&2; exit 9"], at: root)
        }
    }

    @Test("Timeout and cancellation stop lifecycle commands")
    func timeoutAndCancellation() async throws {
        let runner = DevContainerCommandRunner()
        let directory = FileManager.default.temporaryDirectory.path
        let started = ContinuousClock.now
        await #expect(throws: CLIError.timedOut(command: "/bin/sh", seconds: 0.1)) {
            try await runner.run(command: "/bin/sh", args: ["-c", "exec sleep 20"], at: directory, timeout: .milliseconds(100))
        }
        let task = Task { try await runner.run(command: "/bin/sh", args: ["-c", "exec sleep 20"], at: directory) }
        try await Task.sleep(for: .milliseconds(100))
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(ContinuousClock.now - started < .seconds(5))
    }
}
