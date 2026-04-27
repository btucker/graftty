import Testing
import Foundation
@testable import GrafttyKit

@Suite("ChannelEventRouter")
struct ChannelEventRouterTests {

    private func makeRepo(branches: [String]) -> RepoEntry {
        TeamTestFixtures.makeRepo(branches: branches)
    }

    @Test func defaultPrStateChangedGoesToWorktreeOnly() {
        let repo = makeRepo(branches: ["main", "feature/login"])
        let prefs = ChannelRoutingPreferences()
        let r = ChannelEventRouter.recipients(
            event: .prStateChanged,
            subjectWorktreePath: "/r/multi/.worktrees/feature-login",
            repos: [repo],
            preferences: prefs
        )
        #expect(r == ["/r/multi/.worktrees/feature-login"])
    }

    @Test func defaultPrMergedGoesToRootOnly() {
        let repo = makeRepo(branches: ["main", "feature/login"])
        let prefs = ChannelRoutingPreferences()
        let r = ChannelEventRouter.recipients(
            event: .prMerged,
            subjectWorktreePath: "/r/multi/.worktrees/feature-login",
            repos: [repo],
            preferences: prefs
        )
        #expect(r == ["/r/multi"])
    }

    @Test func unionRoutesToBothRootAndWorktree() {
        let repo = makeRepo(branches: ["main", "feature/login"])
        var prefs = ChannelRoutingPreferences()
        prefs.prStateChanged = [.root, .worktree]
        let r = ChannelEventRouter.recipients(
            event: .prStateChanged,
            subjectWorktreePath: "/r/multi/.worktrees/feature-login",
            repos: [repo],
            preferences: prefs
        )
        #expect(Set(r) == Set(["/r/multi", "/r/multi/.worktrees/feature-login"]))
    }

    @Test func otherWorktreesIncludesAllNonSubjectNonRoot() {
        let repo = makeRepo(branches: ["main", "a", "b", "c"])
        var prefs = ChannelRoutingPreferences()
        prefs.prStateChanged = [.otherWorktrees]
        let r = ChannelEventRouter.recipients(
            event: .prStateChanged,
            subjectWorktreePath: "/r/multi/.worktrees/a",
            repos: [repo],
            preferences: prefs
        )
        #expect(Set(r) == Set(["/r/multi/.worktrees/b", "/r/multi/.worktrees/c"]))
    }

    @Test func dedupsWhenSubjectIsAlsoRoot() {
        let repo = makeRepo(branches: ["main", "feature/login"])
        var prefs = ChannelRoutingPreferences()
        prefs.prStateChanged = [.root, .worktree]
        let r = ChannelEventRouter.recipients(
            event: .prStateChanged,
            subjectWorktreePath: "/r/multi",   // root is also subject
            repos: [repo],
            preferences: prefs
        )
        #expect(r.count == 1)
        #expect(r == ["/r/multi"])
    }

    @Test func emptyMatrixRowMeansNoRecipients() {
        let repo = makeRepo(branches: ["main", "feature/login"])
        var prefs = ChannelRoutingPreferences()
        prefs.prStateChanged = []
        let r = ChannelEventRouter.recipients(
            event: .prStateChanged,
            subjectWorktreePath: "/r/multi/.worktrees/feature-login",
            repos: [repo],
            preferences: prefs
        )
        #expect(r.isEmpty)
    }

    @Test func unknownSubjectReturnsEmpty() {
        let repo = makeRepo(branches: ["main", "feature/login"])
        let prefs = ChannelRoutingPreferences()
        let r = ChannelEventRouter.recipients(
            event: .prStateChanged,
            subjectWorktreePath: "/some/random/path",
            repos: [repo],
            preferences: prefs
        )
        #expect(r.isEmpty)
    }

    @Test func singleWorktreeRepoOnlyDispatchesToWorktreeIfSet() {
        let repo = makeRepo(branches: ["main"])
        var prefs = ChannelRoutingPreferences()
        prefs.prStateChanged = [.worktree, .root, .otherWorktrees]
        let r = ChannelEventRouter.recipients(
            event: .prStateChanged,
            subjectWorktreePath: "/r/multi",
            repos: [repo],
            preferences: prefs
        )
        // Single-worktree repo: only the worktree cell matters; it's the subject.
        #expect(r == ["/r/multi"])
    }

    @Test func singleWorktreeRepoEmptyWhenWorktreeCellOff() {
        let repo = makeRepo(branches: ["main"])
        var prefs = ChannelRoutingPreferences()
        prefs.prStateChanged = [.root, .otherWorktrees]   // worktree NOT set
        let r = ChannelEventRouter.recipients(
            event: .prStateChanged,
            subjectWorktreePath: "/r/multi",
            repos: [repo],
            preferences: prefs
        )
        #expect(r.isEmpty)
    }
}
