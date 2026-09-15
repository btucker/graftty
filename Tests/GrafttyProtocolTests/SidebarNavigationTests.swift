import Foundation
import Testing
@testable import GrafttyProtocol

struct SidebarNavigationTests {
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
