import Foundation
import Testing
@testable import GrafttyKit
import GrafttyProtocol

@Suite("Attention file handoff")
struct AttentionFileHandoffTests {
    @Test("@spec REMOTE-23.9: When a host consumes Attention events, the application shall retain events for worktrees owned by another host.")
    func retainsOtherHostsEvents() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let handoff = AttentionFileHandoff(rootDirectory: root)
        for index in 0..<105 {
            try handoff.progress(worktree: "/other", agentID: "codex-\(index)", runtime: .codex, sessionID: nil)
        }
        try handoff.progress(worktree: "/mine", agentID: "codex-mine", runtime: .codex, sessionID: nil)
        #expect(try handoff.consumeActivities(acceptingWorktree: { $0 == "/mine" }) { _ in } == 1)
        #expect(try handoff.consumeActivities { _ in } == 100)
        #expect(try handoff.consumeActivities { _ in } == 5)
    }

    @Test("@spec REMOTE-23.10: If an Attention event handler cannot persist its result, then the application shall retain the event for retry.")
    func failedHandlerRetainsEvent() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let handoff = AttentionFileHandoff(rootDirectory: root)
        try handoff.progress(worktree: "/mine", agentID: "codex-mine", runtime: .codex, sessionID: nil)
        #expect(throws: CocoaError.self) {
            try handoff.consumeActivities { _ in throw CocoaError(.fileWriteNoPermission) }
        }
        #expect(try handoff.consumeActivities { _ in } == 1)
    }

    @Test func removeReportsAnEventFileItCannotDeleteAndStillDeletesTheRest() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let handoff = AttentionFileHandoff(rootDirectory: root)
        try handoff.progress(worktree: "/mine", agentID: "codex-mine", runtime: .codex, sessionID: nil)
        let handled = try handoff.takeActivities { _ in }
        // A path below a regular file cannot be removed, even by root.
        let undeletable = try #require(handled.first).appendingPathComponent("child.json")

        #expect(throws: (any Error).self, "an undeletable event would be replayed every scan with no log") {
            try handoff.remove([undeletable] + handled)
        }
        #expect(try handoff.takeActivities { _ in }.isEmpty)
    }

    @Test("@spec AGENT-3.23: When a staged recap lacks an emoji, the Stop hook shall preserve the legacy recap without requesting a correction turn.")
    func legacyRecapStopsQuietly() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let handoff = AttentionFileHandoff(rootDirectory: root)
        let legacy = AttentionRecap(title: "Push notifications", completed: "Wired the client.", next: "Test delivery.")
        try handoff.stage(legacy, worktree: "/repo/one", agentID: "codex-1")
        #expect(try handoff.stop(worktree: "/repo/one", agentID: "codex-1", runtime: .codex,
            sessionID: "one", paneSessionName: nil, stopHookActive: false) == .queued)
        var events: [AttentionFileStopEvent] = []
        #expect(try handoff.consumeStops { events.append($0) } == 1)
        #expect(events.first?.recap == legacy)
    }

    @Test("@spec AGENT-3.21: When an agent resumes in a sandbox after a stopped turn, the application shall consume its durable progress event and clear only an older stopped card from that session.")
    func resumedAgentProgressFollowsStopInTimestampOrder() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("graftty-attention-progress-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let handoff = AttentionFileHandoff(rootDirectory: root)
        let first = Date(timeIntervalSince1970: 100)
        let second = Date(timeIntervalSince1970: 200)

        try handoff.progress(worktree: "/repo/one", agentID: "codex-1", runtime: .codex,
                             sessionID: "thread-1", progressedAt: second)
        _ = try handoff.stop(worktree: "/repo/one", agentID: "codex-1", runtime: .codex,
                             sessionID: "thread-1", paneSessionName: nil,
                             stopHookActive: true, stoppedAt: first)

        var events: [AttentionFileActivityEvent] = []
        #expect(try handoff.consumeActivities { events.append($0) } == 2)
        guard events.count == 2 else {
            Issue.record("expected stop and progress events")
            return
        }
        guard case .stop = events[0], case .progress = events[1] else {
            Issue.record("stop must be applied before later progress")
            return
        }
    }

    @Test("@spec AGENT-3.19: When a tracked agent has no Graftty wrapper identity, a valid recap shall appear in Attention immediately, and its next matching Stop hook shall not create a duplicate card.")
    func unmanagedAgentReportAppearsWithoutStopHook() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("graftty-attention-unmanaged-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let handoff = AttentionFileHandoff(rootDirectory: root)
        let recap = AttentionRecap(title: "Copy wrapped prose", completed: "Fixed mid-line copy.",
                                   next: "Verify in the installed app.", emoji: "📋")

        try handoff.publishUnmanaged(recap, worktree: "/repo/copy-new-lines",
                                     agentID: "codex-session", runtime: .codex,
                                     sessionID: "thread-1", paneSessionName: nil)
        var events: [AttentionFileStopEvent] = []
        #expect(try handoff.consumeStops { events.append($0) } == 1)
        #expect(events.first?.recap == recap)
        #expect(try handoff.stop(worktree: "/repo/copy-new-lines",
                                 agentID: "codex-session", runtime: .codex,
                                 sessionID: "thread-1", paneSessionName: nil,
                                 stopHookActive: false, turnID: "turn-1") == .queued)
        #expect(try handoff.consumeStops { events.append($0) } == 0)
    }

    @Test("@spec AGENT-3.13: When a sandboxed agent reports a recap and then stops, the application shall consume one durable stopped-turn file containing that recap without requiring control-socket access.")
    func stagedRecapBecomesOneStoppedTurn() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("graftty-attention-handoff-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let handoff = AttentionFileHandoff(rootDirectory: root)
        let recap = AttentionRecap(title: "Posting eval", context: "Testing a smaller extraction model.",
                                   completed: "Ran the holdout.", next: "Review the results.",
                                   emoji: "🧪", emojiAlternatives: ["🔬", "📊"])

        try handoff.stage(recap, worktree: "/repo/one", agentID: "codex-1")
        #expect(try handoff.stop(
            worktree: "/repo/one", agentID: "codex-1", runtime: .codex,
            sessionID: "thread-1", paneSessionName: "pane-1", stopHookActive: false
        ) == .queued)

        var events: [AttentionFileStopEvent] = []
        #expect(try handoff.consumeStops { events.append($0) } == 1)
        #expect(events.count == 1)
        #expect(events.first?.recap == recap)
        #expect(events.first?.worktree == "/repo/one")
        #expect(events.first?.agentID == "codex-1")
        #expect(events.first?.paneSessionName == "pane-1")
        #expect(try handoff.consumeStops { events.append($0) } == 0)
    }

    @Test("@spec AGENT-3.14: When a sandboxed agent stops without a recap, the Stop hook shall queue a generic stopped card without requesting a continuation.")
    func missingRecapStopsQuietly() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("graftty-attention-handoff-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let handoff = AttentionFileHandoff(rootDirectory: root)

        #expect(try handoff.stop(
            worktree: "/repo/one", agentID: "codex-1", runtime: .codex,
            sessionID: nil, paneSessionName: nil, stopHookActive: false
        ) == .queued)

        var events: [AttentionFileStopEvent] = []
        #expect(try handoff.consumeStops { events.append($0) } == 1)
        #expect(events.first?.recap == nil)
    }

    @Test("@spec AGENT-3.27: When a new user turn starts, the application shall discard that agent's unconsumed recap and native-report receipt so a later Stop cannot reuse an earlier turn's report.")
    func newTurnDiscardsUnconsumedReport() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let handoff = AttentionFileHandoff(rootDirectory: root)
        let recap = AttentionRecap(title: "Old turn", completed: "Old progress", next: "Review", emoji: "🧪")
        try handoff.stage(recap, worktree: "/repo", agentID: "codex-1")
        try handoff.progress(worktree: "/repo", agentID: "codex-1", runtime: .codex,
            sessionID: "thread", startsTurn: true)
        _ = try handoff.stop(worktree: "/repo", agentID: "codex-1", runtime: .codex,
            sessionID: "thread", paneSessionName: nil, stopHookActive: false, turnID: "new")
        var events: [AttentionFileStopEvent] = []
        #expect(try handoff.consumeStops { events.append($0) } == 1)
        #expect(events.first?.recap == nil)
    }

    @Test("@spec AGENT-3.15: When stopped-turn files exist before or arrive after the Attention watcher starts, the application shall process both through directory events with a periodic scan as backup.")
    func observerReplaysAndDetectsNewStops() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("graftty-attention-observer-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let handoff = AttentionFileHandoff(rootDirectory: root)
        let observed = DispatchSemaphore(value: 0)
        let observer = AttentionFileHandoffObserver(handoff: handoff)
        defer { observer.stop() }

        _ = try handoff.stop(worktree: "/repo/one", agentID: nil, runtime: .codex,
                             sessionID: nil, paneSessionName: nil, stopHookActive: false)
        try observer.start {
            _ = try? handoff.consumeStops { _ in observed.signal() }
        }
        #expect(observed.wait(timeout: .now() + 5) == .success)

        _ = try handoff.stop(worktree: "/repo/two", agentID: nil, runtime: .claude,
                             sessionID: nil, paneSessionName: nil, stopHookActive: false)
        #expect(observed.wait(timeout: .now() + 5) == .success)
    }

    @Test("Duplicate Claude Stop handlers share the current user turn receipt")
    func duplicateStopsWithoutProviderTurnID() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let handoff = AttentionFileHandoff(rootDirectory: root)
        let transcript = root.appendingPathComponent("claude-transcript.jsonl")
        try handoff.progress(worktree: "/repo", agentID: "claude-1", runtime: .claude,
            sessionID: "session", startsTurn: true)
        for turn in 0..<2 {
            try Data(String(repeating: "reply\n", count: turn + 1).utf8).write(to: transcript)
            for _ in 0..<2 {
                _ = try handoff.stop(worktree: "/repo", agentID: "claude-1", runtime: .claude,
                    sessionID: "session", paneSessionName: nil, stopHookActive: false,
                    turnID: AgentStopHookFilter.turnID(stdinJSON: ["transcript_path": transcript.path]))
            }
            #expect(try handoff.consumeStops { _ in } == 1)
        }
    }

    @Test("Concurrent duplicate Stop hooks consume a report exactly once")
    func concurrentStopHooksAreSerialized() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let handoff = AttentionFileHandoff(rootDirectory: root)
        try handoff.stage(AttentionRecap(title: "Recap", completed: "Done", next: "Review", emoji: "🧪"),
            worktree: "/repo", agentID: "codex-1")
        DispatchQueue.concurrentPerform(iterations: 32) { _ in
            do {
                _ = try handoff.stop(worktree: "/repo", agentID: "codex-1", runtime: .codex,
                    sessionID: "session", paneSessionName: nil, stopHookActive: false, turnID: "same-turn")
            } catch { Issue.record(error) }
        }
        #expect(try handoff.consumeStops { _ in } == 1)
    }

    @Test("@spec AGENT-3.16: When duplicate Stop hooks run for the same provider turn, the application shall queue one stopped card and shall not request another recap after the first hook consumes it.")
    func duplicateStopForTurnDoesNotRequestAgain() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("graftty-attention-duplicate-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let handoff = AttentionFileHandoff(rootDirectory: root)
        let recap = AttentionRecap(title: "Posting eval", completed: "Ran holdout.", next: "Review results.", emoji: "🧪")
        try handoff.stage(recap, worktree: "/repo/one", agentID: "codex-1")

        for _ in 0..<2 {
            #expect(try handoff.stop(
                worktree: "/repo/one", agentID: "codex-1", runtime: .codex,
                sessionID: "session-1", paneSessionName: nil,
                stopHookActive: false, turnID: "turn-1"
            ) == .queued)
        }
        #expect(try handoff.consumeStops { _ in } == 1)

        try handoff.stage(recap, worktree: "/repo/one", agentID: "codex-1")
        #expect(try handoff.stop(
            worktree: "/repo/one", agentID: "codex-1", runtime: .codex,
            sessionID: "session-1", paneSessionName: nil,
            stopHookActive: false, turnID: "turn-2"
        ) == .queued)
        #expect(try handoff.consumeStops { _ in } == 1)
    }
}
