import Testing
import Foundation
@testable import GrafttyKit
import GrafttyProtocol

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
    @Test("@spec AGENT-2.5: When Codex or Claude hooks report turn activity, the application shall include their working panes in Running and project working counts, remove stopped or waiting panes, and clear activity when the pane's command ends.")
    func providerHooksPopulateRunningActivity() async {
        let r = registry(json: "[]", ps: "")
        for runtime in [TeamHookRuntime.codex, .claude] {
            let pane = "pane-" + runtime.rawValue
            r.recordHook(runtime: runtime, event: .userPromptSubmit, sessionID: "session", paneSessionName: pane, attentionReason: nil)
            await r.refresh()
            #expect(r.livenessBySession[pane] == .busy)
            let row = WorktreePanes(path: "/repo", displayName: "main", repoDisplayName: "Repo", displayBranch: "main",
                state: .running, isMainCheckout: true, prBadge: nil, stats: nil, attentionText: nil,
                layout: .leaf(sessionName: pane, title: runtime.rawValue, attentionText: nil,
                    isBusy: AgentLivenessMerge.isPaneBusy(sessionName: pane, liveness: r.livenessBySession), attentionSource: nil))
            let items = SidebarProjection.activity([row])
            #expect(SidebarActivityFilter.running.apply(to: items).count == 1)
            #expect(SidebarActivityCounts(items: items).workingByProject.values.first == 1)
            r.recordHook(runtime: runtime, event: .preToolUse, sessionID: "session", paneSessionName: pane, attentionReason: .question)
            #expect(r.livenessBySession[pane] == .idle)
            r.recordHook(runtime: runtime, event: .postToolUse, sessionID: "session", paneSessionName: pane, attentionReason: nil)
            #expect(r.livenessBySession[pane] == .busy)
            r.recordHook(runtime: runtime, event: .stop, sessionID: "session", paneSessionName: pane, attentionReason: nil)
            #expect(r.livenessBySession[pane] == .idle)
            r.recordHook(runtime: runtime, event: .userPromptSubmit, sessionID: "session", paneSessionName: pane, attentionReason: nil)
            r.removePane(pane)
            #expect(r.livenessBySession[pane] == nil)
            await r.refresh()
            #expect(r.livenessBySession[pane] == nil)
        }
    }

    @Test("Hook activity survives failed Claude polling and respects separate provider sessions")
    func hookActivitySurvivesPolling() async {
        let r = registry(json: "invalid", ps: "")
        r.recordHook(runtime: .codex, event: .preToolUse, sessionID: "one", paneSessionName: "pane", attentionReason: nil)
        r.recordHook(runtime: .codex, event: .preToolUse, sessionID: "two", paneSessionName: "pane", attentionReason: nil)
        r.recordHook(runtime: .codex, event: .stop, sessionID: "one", paneSessionName: "pane", attentionReason: nil)
        await r.refresh()
        #expect(r.livenessBySession["pane"] == .busy)
        r.recordHook(runtime: .codex, event: .permissionRequest, sessionID: "two", paneSessionName: "pane", attentionReason: nil)
        #expect(r.livenessBySession["pane"] == .busy)
        r.recordHook(runtime: .codex, event: .stop, sessionID: "two", paneSessionName: "pane", attentionReason: nil)
        #expect(r.livenessBySession["pane"] == .idle)
    }

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
        r.recordHook(runtime: .codex, event: .userPromptSubmit, sessionID: "codex", paneSessionName: "codex-pane", attentionReason: nil)

        // A fresh refresh (generation 2) runs fully while the slow one is parked.
        await r.refresh()
        #expect(r.generation == 2)
        #expect(r.livenessBySession["graftty-aaaa1111"] == .idle)
        #expect(r.livenessBySession["codex-pane"] == .busy)

        // Release the slow poll; its late write must be dropped by the guard.
        exec.releaseSlow()
        await slow
        #expect(r.generation == 2)
        #expect(r.livenessBySession["graftty-aaaa1111"] == .idle)
        #expect(r.livenessBySession["codex-pane"] == .busy)
    }

    @Test("@spec AGENT-2.6: The application shall bound each `claude agents --json` and `ps` liveness-poll subprocess with a 5-second timeout, and if that timeout expires, then the application shall produce an empty Claude polling result so the next tick can poll again.")
    func pollSubprocessesAreBoundedByTimeout() async {
        let exec = TimeoutRecordingExecutor(
            agentsJSON: #"[{"pid":100,"cwd":"/a","kind":"interactive","sessionId":"s","startedAt":1,"status":"busy"}]"#,
            ps: "100 claude ZMX_SESSION=graftty-aaaa1111")
        let r = ClaudeSessionRegistry(executor: exec, claudePath: "claude")
        await r.refresh()
        #expect(r.livenessBySession["graftty-aaaa1111"] == .busy)
        #expect(exec.timeouts.map(\.command) == ["claude", "ps"])
        #expect(exec.timeouts.allSatisfy { $0.timeout == .seconds(5) })

        for command in ["claude", "ps"] {
            exec.timingOutCommand = command
            await r.refresh()
            #expect(r.livenessBySession.isEmpty, "\(command) timeout")
            exec.timingOutCommand = nil
            await r.refresh()
            #expect(r.livenessBySession["graftty-aaaa1111"] == .busy, "next tick after \(command) timeout")
        }
    }
}

/// Records the `timeout:` passed to each capture. Calls that reach the
/// unbounded overload record a `nil` timeout.
private final class TimeoutRecordingExecutor: CLIExecutor, @unchecked Sendable {
    private let lock = NSLock()
    private let agentsJSON: String
    private let ps: String
    private var _timeouts: [(command: String, timeout: Duration?)] = []
    private var _timingOutCommand: String?
    var timeouts: [(command: String, timeout: Duration?)] { lock.withLock { _timeouts } }
    var timingOutCommand: String? {
        get { lock.withLock { _timingOutCommand } }
        set { lock.withLock { _timingOutCommand = newValue } }
    }

    init(agentsJSON: String, ps: String) {
        self.agentsJSON = agentsJSON
        self.ps = ps
    }

    func run(command: String, args: [String], at directory: String) async throws -> CLIOutput {
        try await capture(command: command, args: args, at: directory)
    }

    func capture(command: String, args: [String], at directory: String) async throws -> CLIOutput {
        try await capture(command: command, args: args, at: directory, timeout: nil)
    }

    func capture(command: String, args: [String], at directory: String,
                 timeout: Duration?) async throws -> CLIOutput {
        let timesOut = lock.withLock {
            _timeouts.append((command, timeout))
            return command == _timingOutCommand
        }
        if timesOut { throw CLIError.timedOut(command: command, seconds: 5) }
        return CLIOutput(stdout: command == "ps" ? ps : agentsJSON, stderr: "", exitCode: 0)
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
