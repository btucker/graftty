import Testing
import Foundation
@testable import GrafttyKit

@Suite("Team membership events")
struct TeamMembershipEventsTests {

    private func makeRepo(branches: [String]) -> RepoEntry {
        TeamTestFixtures.makeRepo(branches: branches)
    }

    @Test func joiningAddsRoutedEventForLead() {
        var dispatched: [(String, ChannelServerMessage)] = []
        let repo = makeRepo(branches: ["main", "feature/login"])
        TeamMembershipEvents.fireJoined(
            repo: repo,
            joinerWorktreePath: "/r/multi/.worktrees/feature-login",
            teamsEnabled: true,
            dispatch: { path, msg in dispatched.append((path, msg)) }
        )
        #expect(dispatched.count == 1)
        #expect(dispatched.first?.0 == "/r/multi")  // lead's worktree path
        if case let .event(type, _, _) = dispatched.first?.1 {
            #expect(type == TeamChannelEvents.EventType.memberJoined)
        } else {
            Issue.record("expected event")
        }
    }

    @Test func joinDoesNotFireWhenJoinerIsTheLead() {
        var dispatched: [(String, ChannelServerMessage)] = []
        let repo = makeRepo(branches: ["main"])  // single-worktree → lead would be alone
        TeamMembershipEvents.fireJoined(
            repo: repo,
            joinerWorktreePath: "/r/multi",  // the root worktree (lead)
            teamsEnabled: true,
            dispatch: { path, msg in dispatched.append((path, msg)) }
        )
        #expect(dispatched.isEmpty)
    }

    @Test func joinDoesNotFireWhenTeamModeOff() {
        var dispatched: [(String, ChannelServerMessage)] = []
        let repo = makeRepo(branches: ["main", "feature/login"])
        TeamMembershipEvents.fireJoined(
            repo: repo,
            joinerWorktreePath: "/r/multi/.worktrees/feature-login",
            teamsEnabled: false,
            dispatch: { path, msg in dispatched.append((path, msg)) }
        )
        #expect(dispatched.isEmpty)
    }

    @Test func leaveFiresEventForLead() {
        var dispatched: [(String, ChannelServerMessage)] = []
        // Repo state AFTER removal — lead remains, leaver is gone but we know its branch+path
        let repo = makeRepo(branches: ["main"])
        TeamMembershipEvents.fireLeft(
            repo: repo,
            leaverBranch: "feature/login",
            leaverPath: "/r/multi/.worktrees/feature-login",
            reason: .removed,
            teamsEnabled: true,
            dispatch: { path, msg in dispatched.append((path, msg)) }
        )
        #expect(dispatched.count == 1)
        #expect(dispatched.first?.0 == "/r/multi")
        if case let .event(type, attrs, _) = dispatched.first?.1 {
            #expect(type == TeamChannelEvents.EventType.memberLeft)
            #expect(attrs["reason"] == "removed")
        } else {
            Issue.record("expected event")
        }
    }

    @Test func leaveDoesNotFireWhenTeamModeOff() {
        var dispatched: [(String, ChannelServerMessage)] = []
        let repo = makeRepo(branches: ["main"])
        TeamMembershipEvents.fireLeft(
            repo: repo,
            leaverBranch: "feature/login",
            leaverPath: "/r/multi/.worktrees/feature-login",
            reason: .removed,
            teamsEnabled: false,
            dispatch: { path, msg in dispatched.append((path, msg)) }
        )
        #expect(dispatched.isEmpty)
    }

    @Test func leaveDoesNotFireIfLeadGone() {
        var dispatched: [(String, ChannelServerMessage)] = []
        // Lead-removal edge case: if the lead is gone too, nobody to notify.
        // Repo state after removal: empty worktrees array (lead was removed).
        let repo = RepoEntry(path: "/r/multi", displayName: "multi-repo")
        // No worktrees remaining
        TeamMembershipEvents.fireLeft(
            repo: repo,
            leaverBranch: "main",
            leaverPath: "/r/multi",
            reason: .removed,
            teamsEnabled: true,
            dispatch: { path, msg in dispatched.append((path, msg)) }
        )
        #expect(dispatched.isEmpty)
    }
}
