import Foundation
import Testing
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
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

    @Test("@spec CLI-1.8: If the Linux reaper collects a stopped subprocess while its SIGKILL escalation is checking that the child still runs, then the application shall not signal the PID the reaper released.")
    func escalationNeverSignalsAReleasedPID() throws {
        // Clean up only children this test has not reaped: signalling a
        // reaped PID is the hazard under test.
        var unreaped: [pid_t] = []
        defer {
            for pid in unreaped {
                _ = kill(pid, SIGKILL)
                var status: Int32 = 0
                _ = waitpid(pid, &status, 0)
            }
        }
        let child = try Self.sleeper()
        unreaped.append(child)
        let reused = try Self.sleeper()
        unreaped.append(reused)
        let process = ReapedDuringRunningCheck(childPID: child, reusedPID: reused)
        let scheduler = ManualSubprocessScheduler()
        defer { scheduler.finish() }
        let termination = SubprocessTermination(process: process, scheduler: scheduler.scheduler)
        try termination.start()
        termination.stop(timedOut: true)
        let escalation = try #require(scheduler.pendingAction())
        escalation.run()

        // A SIGKILL sent by the escalation is already pending and outranks
        // this SIGTERM, so the exit signal says which one stopped it.
        _ = kill(reused, SIGTERM)
        var status: Int32 = 0
        let reapedReused = waitpid(reused, &status, 0) == reused
        if reapedReused { unreaped.removeAll { $0 == reused } }
        #expect(reapedReused)
        #expect(status & 0x7F == SIGTERM)
    }

    #if os(Linux)
    @Test("@spec CLI-1.9: If another waiter already reaped a Linux subprocess so that its exit status is lost, then the application shall report the lost status as an error instead of exit status 0, or report the timeout or cancellation that stopped the child.")
    func lostExitStatusIsAnError() async throws {
        var exited = SubprocessLaunch(executable: "/bin/sh", arguments: ["-c", "exit 3"], timeoutLabel: "sh")
        exited.waitpid = Self.lostStatus
        let exit = try await subprocessResult(Task { try await Subprocess.run(exited) })
        #expect(throws: POSIXError(.ECHILD)) { _ = try exit.get() }

        let child = try SubprocessTestChild()
        defer { child.finish() }
        let scheduler = ManualSubprocessScheduler()
        defer { scheduler.finish() }
        var stopped = SubprocessLaunch(
            executable: "/bin/sh", arguments: child.arguments(),
            directory: child.root.path, timeout: .seconds(30), timeoutLabel: "sh")
        stopped.waitpid = Self.lostStatus
        stopped.scheduler = scheduler.scheduler
        let run = Task { try await Subprocess.run(stopped) }
        try #require(await child.readyPID() != nil)
        try #require(await scheduler.nextAction()).run()
        let timeout = try await subprocessResult(run)
        #expect(throws: CLIError.timedOut(command: "sh", seconds: 30)) { _ = try timeout.get() }
    }

    /// Another waiter collects the status first.
    private static let lostStatus: @Sendable (pid_t, UnsafeMutablePointer<Int32>, Int32) -> pid_t = { pid, status, options in
        _ = waitpid(pid, status, options)
        errno = ECHILD
        return -1
    }
    #endif

    private static func sleeper() throws -> pid_t {
        // Corelibs' `FileHandle.nullDevice` has no usable descriptor.
        let null = open("/dev/null", O_WRONLY | O_CLOEXEC)
        guard null >= 0 else { throw POSIXError(.EIO) }
        defer { close(null) }
        return try SpawnedProcessGroup.spawn(
            executable: URL(fileURLWithPath: "/bin/sleep"), args: ["30"], env: [:], resetsSignals: true,
            standardOutput: null, standardError: nil, closeDescriptors: [])
    }
}

/// A stopped child whose reaper runs, releasing its PID to `reusedPID`, just
/// after the first `isRunning` check that follows SIGTERM.
private final class ReapedDuringRunningCheck: TerminableSubprocess, @unchecked Sendable {
    private let lock = NSLock()
    private let childPID: pid_t
    private let reusedPID: pid_t
    private var terminated = false
    private var reaped = false

    init(childPID: pid_t, reusedPID: pid_t) {
        self.childPID = childPID
        self.reusedPID = reusedPID
    }

    var isRunning: Bool {
        lock.withLock {
            defer { if terminated { reaped = true } }
            return !reaped
        }
    }

    /// What a PID read separate from the running check would see.
    var processIdentifier: Int32 { lock.withLock { reaped ? reusedPID : childPID } }

    func run() {}

    func terminate() { lock.withLock { terminated = true } }

    func killIfRunning() {
        lock.withLock {
            if !reaped { _ = kill(childPID, SIGKILL) }
        }
    }
}
