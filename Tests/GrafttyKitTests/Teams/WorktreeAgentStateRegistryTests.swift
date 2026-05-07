import Foundation
import Testing
@testable import GrafttyKit

/// Mutable clock box — captured by reference so the `@Sendable` closure
/// never captures a `var` directly (Swift 6 strict concurrency).
private final class Clock: @unchecked Sendable {
    var date: Date
    init(_ date: Date) { self.date = date }
}

@Suite("WorktreeAgentStateRegistry — hook-event-driven state machine")
struct WorktreeAgentStateRegistryTests {
    @Test("Unknown is the initial state.")
    func unknownInitial() {
        let r = WorktreeAgentStateRegistry()
        #expect(r.state(worktree: "/w", runtime: "codex") == .unknown)
    }

    @Test("SessionStart drives unknown → active.")
    func unknownToActive() {
        let r = WorktreeAgentStateRegistry()
        r.handleSessionStart(worktree: "/w", runtime: "codex")
        #expect(r.state(worktree: "/w", runtime: "codex") == .active)
    }

    @Test("Stop with no recent typing drives active → idle.")
    func activeToIdleNoTyping() {
        let clock = Clock(Date(timeIntervalSince1970: 1_000))
        let r = WorktreeAgentStateRegistry(now: { clock.date })
        r.handleSessionStart(worktree: "/w", runtime: "codex")
        r.handleStop(worktree: "/w", runtime: "codex", lastInputAt: nil)
        #expect(r.state(worktree: "/w", runtime: "codex") == .idle)

        clock.date = Date(timeIntervalSince1970: 1_100)
        r.handleSessionStart(worktree: "/w", runtime: "codex")
        r.handleStop(worktree: "/w", runtime: "codex", lastInputAt: Date(timeIntervalSince1970: 1_000))
        #expect(r.state(worktree: "/w", runtime: "codex") == .idle)
    }

    @Test("Stop with recent typing drives active → user_engaged.")
    func activeToUserEngaged() {
        let clock = Clock(Date(timeIntervalSince1970: 1_000))
        let r = WorktreeAgentStateRegistry(now: { clock.date })
        r.handleSessionStart(worktree: "/w", runtime: "codex")
        r.handleStop(worktree: "/w", runtime: "codex", lastInputAt: Date(timeIntervalSince1970: 970))
        #expect(r.state(worktree: "/w", runtime: "codex") == .user_engaged)
    }

    @Test("Keystroke drives idle → user_engaged.")
    func idleToUserEngaged() {
        let clock = Clock(Date(timeIntervalSince1970: 1_000))
        let r = WorktreeAgentStateRegistry(now: { clock.date })
        r.handleSessionStart(worktree: "/w", runtime: "codex")
        r.handleStop(worktree: "/w", runtime: "codex", lastInputAt: nil)
        clock.date = Date(timeIntervalSince1970: 2_000)
        r.handleKeystroke(worktree: "/w", runtime: "codex")
        #expect(r.state(worktree: "/w", runtime: "codex") == .user_engaged)
    }

    @Test("PostToolUse drives idle/user_engaged → active.")
    func toolUseToActive() {
        let r = WorktreeAgentStateRegistry()
        r.handleSessionStart(worktree: "/w", runtime: "codex")
        r.handleStop(worktree: "/w", runtime: "codex", lastInputAt: nil)
        #expect(r.state(worktree: "/w", runtime: "codex") == .idle)
        r.handlePostToolUse(worktree: "/w", runtime: "codex")
        #expect(r.state(worktree: "/w", runtime: "codex") == .active)
    }

    @Test("Engaged-grace-elapsed drives user_engaged → idle.")
    func userEngagedTimerToIdle() {
        let r = WorktreeAgentStateRegistry()
        r.handleSessionStart(worktree: "/w", runtime: "codex")
        let now = Date()
        r.handleStop(worktree: "/w", runtime: "codex", lastInputAt: now.addingTimeInterval(-10))
        #expect(r.state(worktree: "/w", runtime: "codex") == .user_engaged)
        r.handleEngagedGraceElapsed(worktree: "/w", runtime: "codex")
        #expect(r.state(worktree: "/w", runtime: "codex") == .idle)
    }

    @Test("Engaged-grace fires while active is ignored (state stays active).")
    func userEngagedTimerWhileActiveIsNoop() {
        let r = WorktreeAgentStateRegistry()
        r.handleSessionStart(worktree: "/w", runtime: "codex")
        r.handleEngagedGraceElapsed(worktree: "/w", runtime: "codex")
        #expect(r.state(worktree: "/w", runtime: "codex") == .active)
    }

    @Test("removeState drops the entry, returning state to unknown.")
    func removeStateDropsEntry() {
        let r = WorktreeAgentStateRegistry()
        r.handleSessionStart(worktree: "/w", runtime: "codex")
        #expect(r.state(worktree: "/w", runtime: "codex") == .active)
        r.removeState(worktree: "/w", runtime: "codex")
        #expect(r.state(worktree: "/w", runtime: "codex") == .unknown)
    }
}
