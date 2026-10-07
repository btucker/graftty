import Foundation
import Testing
import GrafttyProtocol
@testable import GrafttyCommandUI

@MainActor
struct SidebarAttentionWorktreeTests {
    private let project = SidebarProject(id: "p", repositoryID: "r", name: "Project")

    private func navigation() throws -> SidebarNavigationState {
        let defaults = try #require(UserDefaults(suiteName: UUID().uuidString))
        return SidebarNavigationState(prefix: "test", defaults: defaults)
    }

    private func item(_ id: String, time: Double, busy: Bool = false,
                      worktree: String = "/wt", projectID: String = "p") -> SidebarActivityItem {
        .init(id: id, projectID: projectID, worktreeID: worktree, paneID: id,
              projectName: "Project", worktreeName: "Task", title: id,
              occurrence: .init(timestamp: Date(timeIntervalSince1970: time), text: id, source: busy ? .commandFinished : .agentStop),
              isBusy: busy)
    }

    @Test("Retained request candidates collapse to one representative per worktree")
    func oneCardPerWorktreeInEveryFilter() throws {
        let navigation = try navigation()
        let older = item("old-question", time: 10)
        let latest = item("new-question", time: 20)
        let other = item("other", time: 30, worktree: "/other")
        navigation.updateAttentionItems([older, other])
        let opening = navigation.beginOpening(older)
        navigation.finishOpening(opening, succeeded: true)
        navigation.updateAttentionItems([latest])
        #expect(navigation.isSelectedAttention(latest))
        let running = item("running", time: 40, busy: true)
        let live = [older, latest, running, other]
        #expect(navigation.attentionItems(live: live, projects: [project]).map(\.id) == ["other", "new-question"])
        navigation.filter = .all
        #expect(navigation.attentionItems(live: live, projects: [project]).map(\.id) == ["other", "new-question"])
        navigation.filter = .running
        let secondRunning = item("running-two", time: 50, busy: true)
        #expect(navigation.attentionItems(live: live + [secondRunning], projects: [project]).map(\.id) == ["running-two"])
    }

    @Test("Retained request candidates rank by latest report time")
    func cardsAreOrderedNewestFirst() throws {
        let navigation = try navigation()
        let first = item("first", time: 10, worktree: "/first")
        let second = item("second", time: 20, worktree: "/second")
        let third = item("third", time: 30, worktree: "/third")
        navigation.updateAttentionItems([first])
        navigation.updateAttentionItems([first, third])
        navigation.updateAttentionItems([first, second, third])
        #expect(navigation.attentionItems(live: [first, second, third], projects: [project]).map(\.id) == ["third", "second", "first"])
        let opening = navigation.beginOpening(third)
        navigation.finishOpening(opening, succeeded: true)
        #expect(navigation.attentionItems(live: [first, second, third], projects: [project]).map(\.id) == ["third", "second", "first"])
        let updatedFirst = item("first-again", time: 40, worktree: "/first")
        #expect(navigation.attentionItems(live: [updatedFirst, second, third], projects: [project]).map(\.id) == ["first-again", "third", "second"])
        navigation.filter = .all
        var running = item("running", time: 5, busy: true, worktree: "/running")
        running.occurrence = nil
        running.runningSince = Date(timeIntervalSince1970: 25)
        #expect(navigation.attentionItems(live: [updatedFirst, second, third, running], projects: [project]).map(\.id)
                == ["first-again", "third", "running", "second"])
    }

    @Test("An unviewed pending request wins over a newer resumed card")
    func pendingWinsOverResumed() throws {
        let navigation = try navigation()
        let pending = item("question", time: 10)
        var resumed = item("stop", time: 20)
        navigation.updateAttentionItems([pending, resumed])
        resumed.occurrence = nil
        resumed.isBusy = true
        navigation.updateAttentionItems([resumed])
        #expect(navigation.attentionItems(live: [], projects: [project]).map(\.id) == [pending.id])
    }

    @Test("Search does not resurrect an older card, and same-named worktrees in different projects remain distinct")
    func searchAndProjectIdentity() throws {
        let navigation = try navigation()
        navigation.updateAttentionItems([item("obsolete", time: 10), item("current", time: 20),
                                         item("remote", time: 30, projectID: "remote")])
        let projects = [project, SidebarProject(id: "remote", repositoryID: "r", name: "Remote")]
        #expect(navigation.attentionItems(live: [], projects: projects).count == 2)
        navigation.query = "obsolete"
        #expect(navigation.attentionItems(live: [], projects: projects).isEmpty)
    }

    @Test("@spec LAYOUT-2.87: When an Attention worktree card is dismissed, the application shall hide all retained requests for that worktree until a later request arrives.")
    func dismissDoesNotRevealAnOlderCard() throws {
        let navigation = try navigation()
        let older = item("older", time: 10)
        let latest = item("latest", time: 20)
        navigation.updateAttentionItems([older, latest])
        navigation.forget(latest.id)
        #expect(navigation.attentionItems(live: [older, latest], projects: [project]).isEmpty)
        let fresh = item("latest", time: 30)
        #expect(navigation.attentionItems(live: [older, fresh], projects: [project]).map(\.id) == [fresh.id])
    }

    @Test("@spec LAYOUT-2.88: While an Attention card's agent is running, the application shall display elapsed running time in compact units from its resume time, preserve that time across snapshots and relaunches, and clear it when a new request arrives.")
    func runningDurationSurvivesSnapshots() throws {
        let navigation = try navigation()
        let stop = SidebarAgentStop(agentName: "Codex", stoppedAt: Date(timeIntervalSince1970: 100),
                                    providerSessionKey: "codex:one")
        let stopped = SidebarActivityItem(id: "stable:stop", projectID: "p", worktreeID: "/wt", paneID: nil,
            projectName: "Project", worktreeName: "Task", title: stop.title,
            occurrence: stop.occurrence, isBusy: false, agentStop: stop)
        navigation.updateAttentionItems([stopped])
        let running = WorktreePanes(path: "/wt", displayName: "wt", repoDisplayName: "Project",
            displayBranch: "wt", state: .running, isMainCheckout: false, prBadge: nil,
            stats: nil, attentionText: nil, layout: nil,
            sidebar: .init(id: "stable", projectID: "p",
                agentProgressTimes: ["codex:one": Date(timeIntervalSince1970: 200).timeIntervalSinceReferenceDate]))
        navigation.reconcile(worktrees: [running], projects: [project])
        navigation.reconcile(worktrees: [running], projects: [project])
        let card = try #require(navigation.attentionItems(live: [], projects: [project]).first)
        #expect(card.runningSince == Date(timeIntervalSince1970: 200))
        #expect(card.runningDuration(at: Date(timeIntervalSince1970: 500)) == "5m")
        #expect(card.runningDuration(at: Date(timeIntervalSince1970: 200)) == "0m")
        #expect(card.runningDuration(at: Date(timeIntervalSince1970: 7400)) == "2h")
        #expect(card.runningDuration(at: Date(timeIntervalSince1970: 173000)) == "2d")
        let restored = try JSONDecoder().decode(SidebarActivityItem.self, from: JSONEncoder().encode(card))
        #expect(restored.runningSince == card.runningSince)
        var fresh = stopped
        fresh.agentStop = SidebarAgentStop(agentName: "Codex", stoppedAt: Date(timeIntervalSince1970: 600),
                                          providerSessionKey: "codex:one")
        fresh.occurrence = fresh.agentStop?.occurrence
        navigation.updateAttentionItems([fresh])
        #expect(navigation.attentionItems(live: [], projects: [project]).first?.runningSince == nil)
    }

    @Test("@spec LAYOUT-2.92: When an available project's worktree is deleted, the application shall remove all of its retained Attention cards and queued banners while preserving cards for offline projects.")
    func deletedWorktreesDisappearButOfflineCardsRemain() throws {
        let defaults = try #require(UserDefaults(suiteName: UUID().uuidString))
        let navigation = SidebarNavigationState(prefix: "test", defaults: defaults)
        let remoteProject = SidebarProject(id: "remote", repositoryID: "r", name: "Remote", isAvailable: false)
        let remote = item("remote-card", time: 10, projectID: "remote")
        navigation.updateAttentionItems([remote])
        let deleted = item("deleted-pane", time: 20)
        let deletedStop = item("deleted-stop", time: 30)
        navigation.updateAttentionItems([remote, deleted, deletedStop])
        let opening = navigation.beginOpening(deletedStop)
        navigation.reconcile(worktrees: [], projects: [project, remoteProject], authoritativeProjectIDs: [])
        #expect(navigation.attentionItems(live: [], projects: [project, remoteProject]).count == 2)
        navigation.reconcile(worktrees: [], projects: [project, remoteProject])
        navigation.finishOpening(opening, succeeded: true)
        #expect(navigation.selectedAttentionID == nil)
        #expect(navigation.attentionItems(live: [], projects: [project, remoteProject]).map(\.id) == [remote.id])
        #expect(navigation.attentionBanner == nil)
        let restored = SidebarNavigationState(prefix: "test", defaults: defaults)
        #expect(restored.attentionItems(live: [], projects: [project, remoteProject]).map(\.id) == [remote.id])
    }
}
