import Foundation
import Testing
@testable import GrafttyKit

@Suite("Subprocess termination")
struct SubprocessTerminationTests {
    /// Swift concurrency runs `Subprocess.run` on dispatch worker threads,
    /// which block SIGTERM. A Linux child spawned from one inherited that mask,
    /// so every timeout waited out the SIGKILL grace (#736).
    @Test("@spec CLI-1.7: When the application stops a subprocess on timeout or cancellation, the application shall deliver SIGTERM to a child that does not handle it so the child exits without waiting for the SIGKILL escalation, whichever thread launched it.")
    func terminateStopsAChildWithoutTheKillEscalation() async throws {
        let child = try SubprocessTestChild()
        defer { child.finish() }
        let scheduler = ManualSubprocessScheduler()
        defer { scheduler.finish() }
        var launch = SubprocessLaunch(
            executable: "/bin/sh", arguments: child.arguments(),
            directory: child.root.path, timeout: .seconds(30), timeoutLabel: "sh")
        launch.scheduler = scheduler.scheduler
        let run = Task { try await Subprocess.run(launch) }
        try #require(await child.readyPID() != nil)

        let timeout = try #require(await scheduler.nextAction())
        timeout.run() // SIGTERM only; the SIGKILL escalation stays pending.
        let result = try await subprocessResult(run)
        #expect(throws: CLIError.self) { _ = try result.get() }
    }
}
