import Testing
import Foundation
@testable import GrafttyKit

@Suite("Team PR-merged dispatch")
struct TeamPRMergedDispatchTests {

    private func makeRepo() -> RepoEntry {
        var repo = RepoEntry(path: "/r/multi", displayName: "multi-repo")
        repo.worktrees.append(WorktreeEntry(path: "/r/multi", branch: "main"))
        repo.worktrees.append(WorktreeEntry(path: "/r/multi/.worktrees/feature-login", branch: "feature/login"))
        return repo
    }

    @Test func mergeFiresEventToLead() {
        var dispatched: [(String, ChannelServerMessage)] = []
        TeamMembershipEvents.firePRMerged(
            repo: makeRepo(),
            mergerWorktreePath: "/r/multi/.worktrees/feature-login",
            prNumber: 42,
            mergeSha: "abcd1234",
            teamsEnabled: true,
            dispatch: { path, msg in dispatched.append((path, msg)) }
        )
        #expect(dispatched.count == 1)
        #expect(dispatched.first?.0 == "/r/multi")  // routed to lead
        if case let .event(type, attrs, _) = dispatched.first?.1 {
            #expect(type == "team_pr_merged")
            #expect(attrs["pr_number"] == "42")
            #expect(attrs["merge_sha"] == "abcd1234")
            #expect(attrs["branch"] == "feature/login")
        } else {
            Issue.record("expected event")
        }
    }

    @Test func mergeDoesNotFireIfTeamModeOff() {
        var dispatched: [(String, ChannelServerMessage)] = []
        TeamMembershipEvents.firePRMerged(
            repo: makeRepo(),
            mergerWorktreePath: "/r/multi/.worktrees/feature-login",
            prNumber: 42,
            mergeSha: "abcd1234",
            teamsEnabled: false,
            dispatch: { path, msg in dispatched.append((path, msg)) }
        )
        #expect(dispatched.isEmpty)
    }

    @Test func mergeDoesNotFireForSingleWorktreeRepo() {
        var dispatched: [(String, ChannelServerMessage)] = []
        var single = RepoEntry(path: "/r/solo", displayName: "solo")
        single.worktrees.append(WorktreeEntry(path: "/r/solo", branch: "main"))
        TeamMembershipEvents.firePRMerged(
            repo: single,
            mergerWorktreePath: "/r/solo",
            prNumber: 1,
            mergeSha: "deadbeef",
            teamsEnabled: true,
            dispatch: { path, msg in dispatched.append((path, msg)) }
        )
        #expect(dispatched.isEmpty)
    }
}
