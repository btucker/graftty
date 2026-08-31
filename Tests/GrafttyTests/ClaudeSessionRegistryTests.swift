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

    /// @spec AGENT-2.4: When a slow poll is superseded by a newer refresh, the
    /// application shall drop the stale poll's late write so the newer result wins.
    @Test func staleRefreshIsDroppedByGenerationGuard() async {
        // The first `claude agents` call blocks until released; a later refresh
        // returns immediately. The stale (slow) write must lose to the fresh one.
        let exec = GatedExecutor(
            slowOutput: #"[{"pid":100,"cwd":"/a","kind":"interactive","sessionId":"s","startedAt":1,"status":"busy"}]"#,
            fastOutput: #"[{"pid":100,"cwd":"/a","kind":"interactive","sessionId":"s","startedAt":1,"status":"idle"}]"#,
            ps: "100 claude ZMX_SESSION=graftty-aaaa1111")
        let r = ClaudeSessionRegistry(executor: exec, claudePath: "claude")

        // Kick off the slow refresh (generation 1); it parks inside `claude agents`.
        async let slow: Void = r.refresh()
        await exec.waitUntilSlowEntered()

        // A fresh refresh (generation 2) runs fully while the slow one is parked.
        await r.refresh()
        #expect(r.generation == 2)
        #expect(r.livenessBySession["graftty-aaaa1111"] == .idle)

        // Release the slow poll; its late write must be dropped by the guard.
        exec.releaseSlow()
        await slow
        #expect(r.generation == 2)
        #expect(r.livenessBySession["graftty-aaaa1111"] == .idle)
    }
}

/// First `claude` call awaits `release` (signalling once it has entered);
/// every later `claude` call returns `fastOutput` immediately. `ps` is constant.
private final class GatedExecutor: CLIExecutor, @unchecked Sendable {
    private let lock = NSLock()
    private let slowOutput: String
    private let fastOutput: String
    private let ps: String
    private var claudeCallCount = 0
    private let entered = AsyncSignal()
    private let release = AsyncSignal()

    init(slowOutput: String, fastOutput: String, ps: String) {
        self.slowOutput = slowOutput
        self.fastOutput = fastOutput
        self.ps = ps
    }

    func waitUntilSlowEntered() async { await entered.wait() }
    func releaseSlow() { release.signal() }

    func run(command: String, args: [String], at directory: String) async throws -> CLIOutput {
        try await capture(command: command, args: args, at: directory)
    }

    func capture(command: String, args: [String], at directory: String) async throws -> CLIOutput {
        if command == "ps" { return CLIOutput(stdout: ps, stderr: "", exitCode: 0) }
        let callNumber = lock.withLock {
            claudeCallCount += 1
            return claudeCallCount
        }
        if callNumber == 1 {
            entered.signal()
            await release.wait()
            return CLIOutput(stdout: slowOutput, stderr: "", exitCode: 0)
        }
        return CLIOutput(stdout: fastOutput, stderr: "", exitCode: 0)
    }
}

/// One-shot continuation gate: `wait()` suspends until `signal()` fires once;
/// `wait()` after a prior `signal()` returns immediately.
private final class AsyncSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func signal() {
        let pending = lock.withLock {
            fired = true
            let pending = waiters
            waiters.removeAll()
            return pending
        }
        for w in pending { w.resume() }
    }

    func wait() async {
        await withCheckedContinuation { continuation in
            let resumeImmediately = lock.withLock {
                if fired { return true }
                waiters.append(continuation)
                return false
            }
            if resumeImmediately { continuation.resume() }
        }
    }
}
