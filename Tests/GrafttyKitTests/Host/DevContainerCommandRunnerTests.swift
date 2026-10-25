import Foundation
import Testing
@testable import GrafttyKit
#if os(Linux)
import Glibc
#endif

@Suite("Dev Container command completion")
struct DevContainerCommandRunnerTests {
    #if os(Linux)
    @Test("@spec REMOTE-26.30: When a Linux Dev Container command is canceled or times out, the application shall stop its isolated process group, including descendants that ignore graceful termination, before reporting cancellation or timeout.", arguments: [false, true])
    func cancellationAndTimeoutStopTermIgnoringDescendants(timeout: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("container-cancel-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let pidFile = root.appendingPathComponent("child.pid")
        let marker = root.appendingPathComponent("survived")
        let script = """
        /bin/sh -c 'trap "" TERM; printf "%s" "$$" > "$1"; sleep 3; printf survived > "$2"; exec sleep 30' fixture "$1" "$2" &
        wait
        """
        let task = Task {
            try await DevContainerCommandRunner().capture(command: "/bin/sh", args: ["-c", script, "fixture", pidFile.path, marker.path],
                at: root.path, timeout: timeout ? .seconds(1) : nil)
        }
        var child: pid_t?
        defer {
            task.cancel()
            if let child { _ = kill(child, SIGKILL) }
            try? FileManager.default.removeItem(at: root)
        }
        let readyDeadline = ContinuousClock.now.advanced(by: .seconds(5))
        while ContinuousClock.now < readyDeadline {
            if let text = try? String(contentsOf: pidFile, encoding: .utf8), let pid = pid_t(text) { child = pid; break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let pid = try #require(child, "Descendant did not become ready")
        let stoppedAt = ContinuousClock.now
        if !timeout { task.cancel() }
        do {
            _ = try await task.value
            Issue.record("Canceled lifecycle command returned success")
        } catch is CancellationError { #expect(!timeout) }
        catch let error as CLIError {
            #expect(timeout)
            #expect(error == .timedOut(command: "/bin/sh", seconds: 1))
        }
        #expect(ContinuousClock.now - stoppedAt < .seconds(4))
        // Orphans can remain zombies until PID 1 reaps them. They cannot write.
        let status = (try? String(contentsOfFile: "/proc/\(pid)/stat", encoding: .utf8)) ?? ""
        let state = status.split(separator: ")", maxSplits: 1).last?.split(separator: " ").first
        #expect(status.isEmpty || state == "Z", "Descendant is still running after cancellation")
        try await Task.sleep(for: .milliseconds(3200))
        #expect(!FileManager.default.fileExists(atPath: marker.path))
    }
    #endif

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
