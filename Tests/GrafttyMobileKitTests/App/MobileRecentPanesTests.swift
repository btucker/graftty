import Foundation
import GrafttyProtocol
import Testing
@testable import GrafttyMobileKit

@MainActor
struct MobileRecentPanesTests {
    @Test("@spec IOS-4.50: While a mobile terminal is displayed, long-pressing Back shall offer the most recently opened distinct panes with host, project, worktree, and pane labels, retain visits across relaunches, and open the selected stable pane identity without changing ordinary Back taps or allowing stale targets or superseded navigation to redirect the user.")
    func recentVisitsAreDistinctPersistentAndHostScoped() throws {
        let defaults = try #require(UserDefaults(suiteName: "recent-panes.\(UUID())"))
        let history = MobileRecentPanes(defaults: defaults)
        let host = (id: UUID(), label: "Studio")
        let other = (id: UUID(), label: "Laptop")
        let row = worktree("one", route: "s1")
        history.record(hostID: host.id, hostLabel: host.label, worktree: row, sessionName: "s1", at: Date(timeIntervalSince1970: 1))
        history.record(hostID: other.id, hostLabel: other.label, worktree: row, sessionName: "s1", at: Date(timeIntervalSince1970: 2))
        history.record(hostID: host.id, hostLabel: host.label, worktree: row, sessionName: "s1", at: Date(timeIntervalSince1970: 3))
        #expect(history.entries.count == 2)
        #expect(history.entries.map(\.hostID) == [host.id, other.id])
        #expect(try #require(history.entries.first).label == "Shell · Project · one · Studio")
        let restored = MobileRecentPanes(defaults: defaults)
        #expect(restored.entries == history.entries)
        history.reconcile(hostID: host.id, worktrees: [], projects: SidebarProjection.projects([row]))
        #expect(history.entries.map(\.hostID) == [other.id])
    }

    @Test func resolvesStableSlotsAcrossReopenAndRejectsReusedRoutes() async throws {
        let defaults = try #require(UserDefaults(suiteName: "recent-panes.\(UUID())"))
        let history = MobileRecentPanes(defaults: defaults)
        let host = (id: UUID(), label: "Mac")
        let original = worktree("one", route: "old-route")
        history.record(hostID: host.id, hostLabel: host.label, worktree: original, sessionName: "old-route")
        let entry = try #require(history.entries.first)
        let reopened = worktree("one", route: "new-route")
        let target = try await MobileRecentPanes.resolve(entry, fetch: { [reopened] }, reopen: { _ in
            Issue.record("Running worktrees must not be reopened")
        }, isCurrent: { true })
        #expect(target.worktree.path == original.path)
        #expect(target.pane.sessionName == "new-route")
        let reused = worktree("replacement", route: "old-route")
        await #expect(throws: MobileNotificationActivation.Failure.self) {
            try await MobileRecentPanes.resolve(entry, fetch: { [reused] }, reopen: { _ in }, isCurrent: { true })
        }
        let removedSlot = worktree("one", route: "old-route", slot: "replacement-slot")
        await #expect(throws: MobileNotificationActivation.Failure.self) {
            try await MobileRecentPanes.resolve(entry, fetch: { [removedSlot] }, reopen: { _ in }, isCurrent: { true })
        }
        var current = true
        await #expect(throws: CancellationError.self) {
            try await MobileRecentPanes.resolve(entry, fetch: { current = false; return [reopened] },
                reopen: { _ in }, isCurrent: { current })
        }
    }

    @Test func closedWorktreeReopensTheSavedSlotAndBoundsHistory() async throws {
        let defaults = try #require(UserDefaults(suiteName: "recent-panes.\(UUID())"))
        let history = MobileRecentPanes(defaults: defaults)
        let host = (id: UUID(), label: "Mac")
        for index in 0..<25 {
            history.record(hostID: host.id, hostLabel: host.label, worktree: worktree("\(index)", route: "s\(index)"), sessionName: "s\(index)",
                at: Date(timeIntervalSince1970: Double(index)))
        }
        #expect(history.entries.count == 20)
        let entry = try #require(history.entries.first)
        let opened = worktree("24", route: "new")
        var didReopen = false
        let closed = WorktreePanes(path: opened.path, displayName: opened.displayName, repoDisplayName: "Project",
            displayBranch: "24", state: .closed, isMainCheckout: false, prBadge: nil, stats: nil, attentionText: nil,
            layout: nil, sidebar: opened.sidebar)
        let target = try await MobileRecentPanes.resolve(entry, fetch: { didReopen ? [opened] : [closed] },
            reopen: { path in #expect(path == closed.path); didReopen = true }, isCurrent: { true })
        #expect(didReopen)
        #expect(target.pane.sessionName == "new")
    }

    @Test func legacySnapshotsWithoutSlotMapsResolveTheirOriginalRoute() async throws {
        for metadata in [SidebarWorktreeMetadata?.none, .init(id: "stable", projectID: "project")] {
            let defaults = try #require(UserDefaults(suiteName: "legacy-recent.\(UUID())"))
            let history = MobileRecentPanes(defaults: defaults)
            let row = WorktreePanes(path: "/legacy", displayName: "Legacy", repoDisplayName: "Project", displayBranch: "legacy",
                state: .running, isMainCheckout: false, prBadge: nil, stats: nil, attentionText: nil,
                layout: .leaf(sessionName: "original", title: "Shell", attentionText: nil, isBusy: false, attentionSource: nil),
                sidebar: metadata)
            history.record(hostID: UUID(), hostLabel: "Mac", worktree: row, sessionName: "original")
            let entry = try #require(history.entries.first)
            let target = try await MobileRecentPanes.resolve(entry, fetch: { [row] }, reopen: { _ in }, isCurrent: { true })
            #expect(target.pane.sessionName == "original")
        }
    }

    @Test(arguments: [false, true])
    func recentChoiceSupersedesAnOlderNotificationRegardlessOfFetchOrder(olderFinishesFirst: Bool) async throws {
        let defaults = try #require(UserDefaults(suiteName: "recent-intent.\(UUID())"))
        let history = MobileRecentPanes(defaults: defaults)
        let hostID = UUID()
        let notificationRow = worktree("notification", route: "notification-route")
        let recentRow = worktree("recent", route: "recent-route")
        history.record(hostID: hostID, hostLabel: "Mac", worktree: recentRow, sessionName: "recent-route")
        let entry = try #require(history.entries.first)
        let intent = MobileNavigationIntent()
        let oldIntent = intent.begin()
        var releaseNotification: CheckedContinuation<[WorktreePanes], Never>?
        var releaseRecent: CheckedContinuation<[WorktreePanes], Never>?
        let notification = Task { @MainActor in
            try await MobileNotificationActivation.resolve(.init(hostID: hostID, worktreePath: notificationRow.path,
                worktreeID: notificationRow.sidebar?.id, originDeviceID: nil, paneID: "notification-route", paneSlotID: "slot"),
                fetch: { await withCheckedContinuation { releaseNotification = $0 } }, reopen: { _ in },
                isCurrent: { intent.isCurrent(oldIntent) }).pane.sessionName
        }
        while releaseNotification == nil { await Task.yield() }
        let newIntent = intent.begin()
        let recent = Task { @MainActor in
            try await MobileRecentPanes.resolve(entry,
                fetch: { await withCheckedContinuation { releaseRecent = $0 } }, reopen: { _ in },
                isCurrent: { intent.isCurrent(newIntent) }).pane.sessionName
        }
        while releaseRecent == nil { await Task.yield() }
        if olderFinishesFirst {
            releaseNotification?.resume(returning: [notificationRow])
            releaseRecent?.resume(returning: [recentRow])
        } else {
            releaseRecent?.resume(returning: [recentRow])
            releaseNotification?.resume(returning: [notificationRow])
        }
        await #expect(throws: CancellationError.self) { try await notification.value }
        #expect(try await recent.value == "recent-route")
    }

    private func worktree(_ name: String, route: String, slot: String = "slot") -> WorktreePanes {
        .init(path: "/repo/\(name)", displayName: name, repoDisplayName: "Project", displayBranch: name,
            state: .running, isMainCheckout: false, prBadge: nil, stats: nil, attentionText: nil,
            layout: .leaf(sessionName: route, title: "Shell", attentionText: nil, isBusy: false, attentionSource: nil),
            sidebar: .init(id: name, projectID: "project", paneIDs: [route: slot], paneSlotIDs: [slot]))
    }
}
