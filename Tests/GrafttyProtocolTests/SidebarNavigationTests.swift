import Foundation
import Testing
@testable import GrafttyProtocol

struct SidebarNavigationTests {
    @Test("@spec LAYOUT-2.84: When an agent resumes after its stopped card was viewed, the application shall remove that card from Attention while preserving stopped cards from other sessions and newer stops.")
    func resumedAgentRemovesViewedStop() throws {
        let stop = SidebarAgentStop(agentName: "Codex", stoppedAt: Date(timeIntervalSince1970: 100),
                                    providerSessionKey: "codex:session:one")
        let resumedAt = Date(timeIntervalSince1970: 200).timeIntervalSinceReferenceDate
        let metadata = SidebarWorktreeMetadata(id: "stable", projectID: "project",
            unseenAgentStop: nil, agentProgressTimes: ["codex:session:one": resumedAt])
        func row(_ metadata: SidebarWorktreeMetadata) -> WorktreePanes {
            WorktreePanes(path: "/wt", displayName: "wt", repoDisplayName: "Project",
                displayBranch: "wt", state: .running, isMainCheckout: false, prBadge: nil,
                stats: nil, attentionText: nil, layout: nil, sidebar: metadata)
        }
        var history = SidebarRecentHistory()
        let item = SidebarActivityItem(id: "stable:stop", projectID: "project", worktreeID: "/wt",
            paneID: nil, projectName: "Project", worktreeName: "wt", title: stop.title,
            occurrence: stop.occurrence, isBusy: false, agentStop: stop)
        history.open(item)
        history.reconcile(worktrees: [row(metadata)], availableProjectIDs: ["project"])
        #expect(history.entries.isEmpty)

        let other = SidebarWorktreeMetadata(id: "stable", projectID: "project",
            unseenAgentStop: nil, agentProgressTimes: ["codex:session:two": resumedAt])
        history.open(item)
        history.reconcile(worktrees: [row(other)], availableProjectIDs: ["project"])
        #expect(history.entries.count == 1)

        let newerStop = SidebarAgentStop(agentName: "Codex", stoppedAt: Date(timeIntervalSince1970: 300),
                                         providerSessionKey: "codex:session:one")
        var newerItem = item
        newerItem.agentStop = newerStop
        newerItem.occurrence = newerStop.occurrence
        history.open(newerItem)
        history.reconcile(worktrees: [row(metadata)], availableProjectIDs: ["project"])
        #expect(history.entries.first?.item.agentStop == newerStop)
    }

    @Test("@spec AGENT-3.18: When an agent reports an emoji for its worktree, the application shall accept one emoji and up to three distinct alternatives while decoding older recaps without emoji fields.")
    func recapEmojiValidationAndCompatibility() throws {
        let recap = AttentionRecap(title: "Push notifications", completed: "Client wired.", next: "Test devices.",
                                   emoji: "🔔", emojiAlternatives: ["📱", "📨"])
        #expect(recap.isValid)
        #expect(try JSONDecoder().decode(AttentionRecap.self, from: JSONEncoder().encode(recap)) == recap)
        #expect(!AttentionRecap(title: "Task", completed: "Done", next: "Next", emoji: "1").isValid)
        #expect(!AttentionRecap(title: "Task", completed: "Done", next: "Next", emoji: "🔔🔔").isValid)
        #expect(!AttentionRecap(title: "Task", completed: "Done", next: "Next", emoji: "🔔", emojiAlternatives: ["🔔"]).isValid)
        let old = Data(#"{"title":"Push notifications","completed":"Client wired.","next":"Test devices."}"#.utf8)
        #expect(try JSONDecoder().decode(AttentionRecap.self, from: old).emoji == nil)
    }
    @Test("@spec LAYOUT-2.72: When a stopped agent belongs to a named pane, the application shall retain that pane name in its Attention card and make it searchable.")
    func stoppedTurnRetainsPaneName() throws {
        let stop = SidebarAgentStop(agentName: "Codex", stoppedAt: .now,
                                    paneTitle: "Terminal wrap cleanup")
        let row = WorktreePanes(path: "/r/w", displayName: "feature", repoDisplayName: "Repo",
            displayBranch: "feature", state: .running, isMainCheckout: false, prBadge: nil,
            stats: nil, attentionText: nil, layout: nil,
            sidebar: .init(id: "w", projectID: "r", unseenAgentStop: stop))
        let item = try #require(SidebarProjection.activity([row]).first)
        #expect(item.agentStop?.paneTitle == "Terminal wrap cleanup")
        #expect(SidebarActivityFilter.needsYou.apply(to: [item], query: "wrap cleanup").count == 1)
        #expect(try JSONDecoder().decode(SidebarActivityItem.self, from: JSONEncoder().encode(item)) == item)
    }

    @Test("@spec LAYOUT-2.70: While an agent's stopped turn has a recap, the application shall retain its recognizable title, task context, completed work, next step, and user need in the Attention item across snapshot encoding.")
    func stoppedTurnRetainsRecap() throws {
        let recap = AttentionRecap(
            title: "Posting detail model evals",
            context: "Comparing a smaller extraction model against a700.",
            completed: "v3 scored 0.910 against a700's 0.935.",
            next: "Run four holdout evals.",
            need: "Choose the target score."
        )
        #expect(recap.isValid)
        let stop = SidebarAgentStop(agentName: "Codex", stoppedAt: .now, recap: recap)
        let row = WorktreePanes(path: "/r/w", displayName: "feature", repoDisplayName: "Repo",
            displayBranch: "feature", state: .running, isMainCheckout: false, prBadge: nil,
            stats: nil, attentionText: nil, layout: nil,
            sidebar: .init(id: "w", projectID: "r", unseenAgentStop: stop))
        let item = try #require(SidebarProjection.activity([row]).first)
        #expect(item.agentStop?.recap == recap)
        #expect(try JSONDecoder().decode(SidebarActivityItem.self, from: JSONEncoder().encode(item)) == item)
    }

    @Test("@spec LAYOUT-2.71: When the user searches Attention, the application shall match the stopped turn's recap title, task context, completed work, next step, and user need.")
    func attentionSearchIncludesRecap() {
        let recap = AttentionRecap(title: "Posting detail model evals", context: "Extracting job posting details.", completed: "v3 scored 0.910.",
                                   next: "Run holdout evals.", need: "Choose a target score.")
        let stop = SidebarAgentStop(agentName: "Codex", stoppedAt: .now, recap: recap)
        let item = SidebarActivityItem(id: "stop", projectID: "p", worktreeID: "w", paneID: nil,
            projectName: "Repo", worktreeName: "branch", title: stop.title,
            occurrence: stop.occurrence, isBusy: false, agentStop: stop)
        for query in ["posting detail", "extracting job", "0.910", "holdout", "target score"] {
            #expect(SidebarActivityFilter.needsYou.apply(to: [item], query: query).count == 1)
        }
    }

    @Test("@spec AGENT-3.17: When an agent reports task context, the application shall validate and retain it while decoding older recaps without a context field.")
    func recapContextValidatesAndKeepsOldCards() throws {
        let recap = AttentionRecap(title: "Push notifications", context: "Paired devices should notify a locked phone.",
                                   completed: "Client committed.", next: "Verify on a device.")
        #expect(recap.isValid)
        #expect(try JSONDecoder().decode(AttentionRecap.self, from: JSONEncoder().encode(recap)) == recap)
        #expect(!AttentionRecap(title: "Push notifications", context: "   ",
                                completed: "Client committed.", next: "Verify on a device.").isValid)
        let old = Data(#"{"title":"Push notifications","completed":"Client committed.","next":"Verify on a device."}"#.utf8)
        #expect(try JSONDecoder().decode(AttentionRecap.self, from: old).context == nil)
    }

    @Test("@spec LAYOUT-2.74: When Attention opens in a wide enough window, the application shall widen its content column for reading and restore the previous sidebar width when leaving, while preserving project-rail size changes.")
    func attentionReadingWidthRestoresPreviousWidth() {
        var state = SidebarAttentionWidthState()
        #expect(state.enter(currentWidth: 256, railWidth: 0, windowWidth: 1200) == 410)
        #expect(state.leave(currentRailWidth: 0) == 256)
        #expect(state.enter(currentWidth: 256, railWidth: 0, windowWidth: 900) == nil)
        #expect(state.leave(currentRailWidth: 0) == nil)
        #expect(state.enter(currentWidth: 460, railWidth: 197, windowWidth: 1400) == 607)
        #expect(state.adjustedWidth(forRailWidth: 65) == 475)
        #expect(state.leave(currentRailWidth: 65) == 328)
    }

    @Test("@spec LAYOUT-2.68: While a worktree has a PR or MR, the application shall include its current reference, status, and browser link on its Attention items, including retained history on Mac and mobile.")
    func attentionIncludesForgeBadge() throws {
        let badge = PRBadge(number: 342, state: .open, checks: .pending,
                            url: URL(string: "https://gitlab.example/team/project/-/merge_requests/342")!)
        func worktree(_ badge: PRBadge?) -> WorktreePanes {
            .init(path: "worktree", displayName: "feature", repoDisplayName: "Project", displayBranch: "feature",
                  state: .running, isMainCheckout: false, prBadge: badge, stats: nil,
                  attentionText: "Review", layout: .leaf(sessionName: "pane", title: "Agent", attentionText: "Question", isBusy: false, attentionSource: .agentStop),
                  sidebar: .init(id: "stable", projectID: "project", unseenAgentStop: .init(agentName: "Codex", stoppedAt: Date())))
        }
        let items = SidebarProjection.activity([worktree(badge)])
        #expect(items.count == 3)
        #expect(items.allSatisfy { $0.prBadge == badge })
        #expect(items.first?.prBadge?.referenceText == "!342")
        let item = try #require(items.first)
        #expect(try JSONDecoder().decode(SidebarActivityItem.self, from: JSONEncoder().encode(item)) == item)
        var legacy = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(item)) as? [String: Any])
        legacy.removeValue(forKey: "prBadge")
        #expect(try JSONDecoder().decode(SidebarActivityItem.self, from: JSONSerialization.data(withJSONObject: legacy)).prBadge == nil)
        var history = SidebarRecentHistory()
        history.open(item)
        let merged = PRBadge(number: 342, state: .merged, checks: .success, url: badge.url)
        history.reconcile(worktrees: [worktree(merged)], availableProjectIDs: ["project"])
        #expect(history.entries.first?.item.prBadge == merged)
        #expect(history.entries.first?.item.occurrence == item.occurrence)
        history.reconcile(worktrees: [worktree(nil)], availableProjectIDs: ["project"])
        #expect(history.entries.first?.item.prBadge == nil)
    }

    @Test("@spec LAYOUT-2.58: While projects and worktrees are displayed, the application shall show working-agent counts in green for each project and matching pending-attention counts in orange for each project and worktree, excluding viewed history and command-finished markers.")
    func activityCountsAgreeAcrossProjectsAndWorktrees() {
        let working = SidebarActivityItem(id: "busy", projectID: "p", worktreeID: "w1", paneID: "agent",
            projectName: "Project", worktreeName: "worktree", title: "Codex", occurrence: nil, isBusy: true)
        var request = working
        request.id = "request"
        request.occurrence = .init(timestamp: Date(), text: "Needs input", source: .agentStop)
        request.isBusy = false
        var stopped = request
        stopped.id = "stop"
        stopped.worktreeID = "w2"
        stopped.paneID = nil
        var command = request
        command.id = "command"
        command.occurrence?.source = .commandFinished
        let counts = SidebarActivityCounts(items: [working, working, request, stopped, command])
        #expect(counts.workingByProject == ["p": 1])
        #expect(counts.attentionByProject == ["p": 2])
        #expect(counts.attentionByWorktree == ["w1": 1, "w2": 1])
        #expect(counts.attentionByPane == ["agent": 1])
        #expect(counts.unassignedAttentionByWorktree == ["w2": 1])
        #expect(SidebarActivityCounts(items: []).attentionByProject.isEmpty)
    }

    @Test("@spec LAYOUT-2.53: While the project column is enabled, the application shall identify remote projects by their owning Mac in that column and omit the Remote Macs grouping from the worktree column.")
    func projectOwnerContext() {
        let local = RemoteDeviceID(value: "local")
        let remote = RemoteDeviceID(value: "remote")
        let project = SidebarProject(id: "p", repositoryID: "r", name: "graftty",
            owner: .init(deviceID: remote, deviceLabel: "Studio Mac", relayDepth: 0))
        #expect(project.ownerSubtitle(localDeviceID: local) == "Studio Mac")
        #expect(project.ownerSubtitle(localDeviceID: remote) == nil)
        #expect(project.ownerSubtitle(localDeviceID: nil) == "Studio Mac")
        var offline = project
        offline.isAvailable = false
        #expect(offline.ownerSubtitle(localDeviceID: local) == "Studio Mac · Offline")
        #expect(offline.ownerSubtitle(localDeviceID: remote) == "Offline")
    }

    @Test("@spec LAYOUT-2.52: While an unseen stopped turn appears in Attention, the application shall show elapsed time from its recorded stop timestamp and refresh that age as time passes.")
    func stoppedTurnAge() throws {
        let date = Date(timeIntervalSince1970: 100)
        let stop = SidebarAgentStop(agentName: "Codex", stoppedAt: date)
        #expect(stop.elapsedDescription(at: date.addingTimeInterval(59)) == "just now")
        #expect(stop.elapsedDescription(at: date.addingTimeInterval(60)) == "1 minute ago")
        #expect(stop.elapsedDescription(at: date.addingTimeInterval(120)) == "2 minutes ago")
        #expect(stop.elapsedDescription(at: date.addingTimeInterval(3600)) == "1 hour ago")
        #expect(stop.elapsedDescription(at: date.addingTimeInterval(172800)) == "2 days ago")
        #expect(stop.elapsedDescription(at: date.addingTimeInterval(-90)) == "just now")
        let restored = try JSONDecoder().decode(SidebarAgentStop.self, from: JSONEncoder().encode(stop))
        #expect(restored == stop)
        let row = WorktreePanes(path: "remote-route", displayName: "feature", repoDisplayName: "Repo", displayBranch: "feature", state: .running, isMainCheckout: false, prBadge: nil, stats: nil, attentionText: nil, layout: nil,
            sidebar: .init(id: "w", projectID: "p", unseenAgentStop: stop))
        #expect(SidebarInteractionPolicy.stoppedTurnAcknowledgement(for: row) == .acknowledgeOccurrence(worktreeID: row.path, paneID: nil, occurrence: stop.occurrence))
        let item = try #require(SidebarProjection.activity([row]).first)
        var history = SidebarRecentHistory()
        history.open(item)
        history.reconcile(worktrees: [row], availableProjectIDs: ["p"])
        #expect(history.entries.first?.item.agentStop == stop)
    }

    @Test("""
@spec LAYOUT-2.50: While the project rail setting is disabled, the application shall show all projects together in the worktree sidebar without applying the previously selected project's filter.
""")
    func singleSidebarShowsAllProjects() {
        #expect(SidebarLayoutPolicy.projectFilter(selectedID: "one", showsProjectRail: false) == nil)
        #expect(SidebarLayoutPolicy.projectFilter(selectedID: "one", showsProjectRail: true) == "one")
    }

    @Test("@spec LAYOUT-2.38: When projects are reordered, the application shall preserve their manual order across refreshes, retain unavailable projects, and append newly discovered projects.")
    func projectOrder() {
        var order = SidebarProjectOrder(ids: ["local-a", "remote-b", "local-c"])
        let moved = order.move("local-c", relativeTo: "local-a", after: false)
        #expect(moved)
        #expect(order.ids == ["local-c", "local-a", "remote-b"])
        order.discover(["local-a", "local-c", "new-d"])
        #expect(order.ids == ["local-c", "local-a", "remote-b", "new-d"])
        let missing = order.move("missing", relativeTo: "local-a", after: false)
        #expect(!missing)
        let selfMove = order.move("local-a", relativeTo: "local-a", after: true)
        #expect(!selfMove)
    }

    @Test("@spec LAYOUT-2.39: When an attention target is opened, the application shall retain the last 20 distinct recently viewed targets locally across relaunches, newest first, without counting them as pending requests.")
    func recentTargets() throws {
        var history = SidebarRecentHistory()
        for index in 0..<25 {
            history.open(item("target-\(index)"), at: Date(timeIntervalSince1970: Double(index)))
        }
        #expect(history.entries.count == 20)
        #expect(history.entries.first?.item.id == "target-24")
        history.open(item("target-7"), at: Date(timeIntervalSince1970: 30))
        #expect(history.entries.count == 20)
        #expect(history.entries.first?.item.id == "target-7")
        let data = try JSONEncoder().encode(history)
        #expect(try JSONDecoder().decode(SidebarRecentHistory.self, from: data) == history)
    }

    @Test("@spec LAYOUT-2.40: While the attention queue displays Needs you, the application shall include explicit agent and user requests, exclude command-finished markers, and order requests by occurrence time with newest first.")
    func attentionSources() {
        let input = [item("command", source: .commandFinished, time: 1),
                     item("agent", source: .agentStop, time: 3),
                     item("user", source: .userNotify, time: 2)]
        #expect(SidebarActivityFilter.needsYou.apply(to: input).map(\.id) == ["agent", "user"])
        #expect(SidebarActivityFilter.all.apply(to: input).count == 3)
        #expect(SidebarActivityFilter.running.apply(to: input).isEmpty)
    }

    @Test("@spec LAYOUT-2.41: When an attention occurrence is acknowledged, the application shall clear only the matching occurrence and preserve a newer notification at the same target.")
    func occurrenceMatch() {
        let occurrence = SidebarAttentionOccurrence(timestamp: Date(timeIntervalSince1970: 2), text: "Review", source: .agentStop)
        #expect(occurrence.matches(timestamp: Date(timeIntervalSince1970: 2), text: "Review", source: .agentStop))
        #expect(!occurrence.matches(timestamp: Date(timeIntervalSince1970: 3), text: "Review", source: .agentStop))
        #expect(!occurrence.matches(timestamp: occurrence.timestamp, text: "Review", source: .userNotify))
    }

    @Test("@spec REMOTE-14.1: When a host publishes sidebar metadata, the application shall preserve the original worktree snapshot fields and decode older snapshots without navigation metadata.")
    func compatibleSnapshot() throws {
        let message = PanesStateMessage.snapshot([], sidebar: .init(projects: [
            .init(id: "stable", repositoryID: "route", name: "Empty project")
        ]))
        let data = try JSONEncoder().encode(message)
        #expect(try JSONDecoder().decode(PanesStateMessage.self, from: data) == message)
        let old = Data(#"{"type":"snapshot","worktrees":[]}"#.utf8)
        #expect(try JSONDecoder().decode(PanesStateMessage.self, from: old) == .snapshot([]))
    }

    @Test("@spec REMOTE-14.2: When a client requests a project move, worktree move, icon, or occurrence acknowledgement, the application shall round-trip stable ordering identities separately from opaque resource routes.")
    func managementRequests() throws {
        let requests: [WorktreeManagementRequest] = [
            .moveProject(id: "stable", relativeTo: "other", after: true),
            .moveWorktree(repositoryID: "repo-route", worktreeID: "route", relativeTo: "target", after: false),
            .projectIcon(repositoryID: "repo-route", revision: "hash"),
            .acknowledgeOccurrence(worktreeID: "route", paneID: "pane", occurrence: .init(timestamp: nil, text: "Review", source: .agentStop))
        ]
        for request in requests {
            let data = try JSONEncoder().encode(request)
            #expect(try JSONDecoder().decode(WorktreeManagementRequest.self, from: data) == request)
        }
    }

    @Test("@spec IPAD-1.21: While iPad navigation has less than 1100 points of available window width, the application shall use the icon rail without overwriting the user's expanded-rail preference.")
    func adaptiveRail() {
        #expect(SidebarLayoutPolicy.railCollapsed(preference: false, isMobile: true, windowWidth: 900))
        #expect(!SidebarLayoutPolicy.railCollapsed(preference: false, isMobile: true, windowWidth: 1200))
        #expect(!SidebarLayoutPolicy.railCollapsed(preference: false, isMobile: false, windowWidth: 900))
    }

    @Test("@spec LAYOUT-2.43: When a recent target's live route changes, the application shall resolve its stable identity to the current worktree and pane routes without replacing its viewed occurrence.")
    func recentRoutes() {
        let old = SidebarActivityItem(id: "stable-worktree:stable-pane", projectID: "project", worktreeID: "old-route", paneID: "old-pane", projectName: "Project", worktreeName: "branch", title: "Old request", occurrence: nil, isBusy: false)
        let row = WorktreePanes(path: "new-route", displayName: "branch", repoDisplayName: "Project", displayBranch: "branch", state: .running, isMainCheckout: false, prBadge: nil, stats: nil, attentionText: nil, layout: .leaf(sessionName: "new-pane", title: "Shell", attentionText: nil, isBusy: false, attentionSource: nil), sidebar: .init(id: "stable-worktree", projectID: "project", paneIDs: ["new-pane": "stable-pane"]))
        var history = SidebarRecentHistory()
        history.open(old)
        history.reconcile(worktrees: [row], availableProjectIDs: ["project"])
        #expect(history.entries.first?.item.worktreeID == "new-route")
        #expect(history.entries.first?.item.paneID == "new-pane")
        #expect(history.entries.first?.item.title == "Old request")
        let closed = WorktreePanes(path: "closed-route", displayName: "branch", repoDisplayName: "Project", displayBranch: "branch", state: .closed, isMainCheckout: false, prBadge: nil, stats: nil, attentionText: nil, layout: nil, sidebar: .init(id: "stable-worktree", projectID: "project", paneIDs: ["closed-pane": "stable-pane"]))
        history.reconcile(worktrees: [closed], availableProjectIDs: ["project"])
        #expect(history.entries.first?.item.paneID == "closed-pane")
        history.reconcile(worktrees: [], availableProjectIDs: [])
        #expect(history.entries.count == 1)
        history.reconcile(worktrees: [], availableProjectIDs: ["project"])
        #expect(history.entries.isEmpty)
    }

    @Test("@spec REMOTE-14.3: When a snapshot supplies folder ancestry, the client shall preserve nested folders and sibling order without interpreting opaque worktree routes as filesystem paths.")
    func remoteFolders() {
        func row(_ id: String, _ folders: [String]) -> WorktreePanes {
            WorktreePanes(path: id, displayName: id, repoDisplayName: "Project", displayBranch: id, state: .closed, isMainCheckout: false, prBadge: nil, stats: nil, attentionText: nil, layout: nil, sidebar: .init(id: id, projectID: "p", folders: folders))
        }
        let a = row("opaque-a", ["research", "mobile"])
        let b = row("opaque-b", ["research", "mobile"])
        let main = row("opaque-main", [])
        let tree = SidebarWorktreeTree.nodes([main, b, a])
        #expect(tree.count == 2)
        #expect(tree[0].worktree?.path == main.path)
        #expect(tree[1].name == "research")
        #expect(tree[1].children?.first?.name == "mobile")
        #expect(tree[1].children?.first?.children?.compactMap { $0.worktree?.path } == [b.path, a.path])
    }

    @Test("@spec REMOTE-14.4: When attention crosses the authenticated wire, the application shall preserve subsecond occurrence identity so identical requests within one second cannot acknowledge each other.")
    func preciseOccurrenceWire() throws {
        let timestamp = Date(timeIntervalSinceReferenceDate: 810000000.123456)
        let original = SidebarAttentionOccurrence(timestamp: timestamp, text: "Review", source: .agentStop)
        let request = WorktreeManagementRequest.acknowledgeOccurrence(worktreeID: "route", paneID: nil, occurrence: original)
        let data = try JSONEncoder.iso8601().encode(request)
        #expect(try JSONDecoder.iso8601().decode(WorktreeManagementRequest.self, from: data) == request)
        let row = WorktreePanes(path: "route", displayName: "branch", repoDisplayName: "Project", displayBranch: "branch", state: .closed, isMainCheckout: false, prBadge: nil, stats: nil, attentionText: "Review", attentionSource: .agentStop, attentionTimestamp: timestamp, layout: nil,
                               sidebar: .init(id: "worktree", projectID: "project", attentionTimestamps: ["worktree": timestamp.timeIntervalSinceReferenceDate]))
        let decoded = try JSONDecoder.iso8601().decode(WorktreePanes.self, from: JSONEncoder.iso8601().encode(row))
        #expect(SidebarProjection.activity([decoded]).first?.occurrence == original)
    }

    private func item(_ id: String, source: AttentionSource = .agentStop, time: TimeInterval = 0) -> SidebarActivityItem {
        SidebarActivityItem(id: id, projectID: "project", worktreeID: id, paneID: nil,
                            projectName: "Project", worktreeName: id, title: "Review",
                            occurrence: .init(timestamp: Date(timeIntervalSince1970: time), text: "Review", source: source), isBusy: false)
    }
}
