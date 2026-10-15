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

    @Test("@spec AGENT-3.23: When a staged recap lacks an emoji, the Stop hook shall request one correction, preserve the recap if no correction arrives, and accept a corrected report without another continuation.")
    func legacyRecapRequestsEmojiOnce() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("emoji-retry-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let handoff = AttentionFileHandoff(rootDirectory: root)
        let legacy = AttentionRecap(title: "Push notifications", completed: "Wired the client.", next: "Test delivery.")
        try handoff.stage(legacy, worktree: "/repo/one", agentID: "codex-1")
        #expect(try handoff.stop(worktree: "/repo/one", agentID: "codex-1", runtime: .codex,
            sessionID: "one", paneSessionName: nil, stopHookActive: false) == .requestRecap)
        var events: [AttentionFileStopEvent] = []
        #expect(try handoff.consumeStops { events.append($0) } == 0)
        #expect(try handoff.stop(worktree: "/repo/one", agentID: "codex-1", runtime: .codex,
            sessionID: "one", paneSessionName: nil, stopHookActive: true) == .queued)
        #expect(try handoff.consumeStops { events.append($0) } == 1)
        #expect(events.first?.recap == legacy)

        try handoff.stage(legacy, worktree: "/repo/one", agentID: "codex-1")
        #expect(try handoff.stop(worktree: "/repo/one", agentID: "codex-1", runtime: .codex,
            sessionID: "one", paneSessionName: nil, stopHookActive: false) == .requestRecap)
        var corrected = legacy
        corrected.emoji = "🔔"
        try handoff.stage(corrected, worktree: "/repo/one", agentID: "codex-1")
        #expect(try handoff.stop(worktree: "/repo/one", agentID: "codex-1", runtime: .codex,
            sessionID: "one", paneSessionName: nil, stopHookActive: true) == .queued)
        #expect(try handoff.consumeStops { events.append($0) } == 1)
        #expect(events.last?.recap == corrected)
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

    @Test("@spec AGENT-3.14: When a sandboxed agent stops without a recap, the Stop hook shall request one recap once and then queue a generic stopped card if the continued turn still has none.")
    func stopRequestsOnceThenQueuesGenericCard() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("graftty-attention-handoff-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let handoff = AttentionFileHandoff(rootDirectory: root)

        #expect(try handoff.stop(
            worktree: "/repo/one", agentID: "codex-1", runtime: .codex,
            sessionID: nil, paneSessionName: nil, stopHookActive: false
        ) == .requestRecap)
        #expect(try handoff.stop(
            worktree: "/repo/one", agentID: "codex-1", runtime: .codex,
            sessionID: nil, paneSessionName: nil, stopHookActive: true
        ) == .queued)

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

    @Test("@spec AGENT-3.16: When duplicate Stop hooks run for the same Codex turn, the application shall queue one stopped card and shall not request another recap after the first hook consumes it.")
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
