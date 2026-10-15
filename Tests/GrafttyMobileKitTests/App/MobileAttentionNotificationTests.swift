import Foundation
import GrafttyCommandUI
import GrafttyProtocol
import Testing
import UserNotifications
@testable import GrafttyMobileKit
#if canImport(UIKit)
import SwiftUI
#endif

@MainActor
struct MobileAttentionNotificationTests {
    private func item(time: Double = 10) -> SidebarActivityItem {
        .init(id: "request", projectID: "project", worktreeID: "/work/task", paneID: "pane",
              projectName: "Project", worktreeName: "Task", title: "Approve the change?",
              occurrence: .init(timestamp: Date(timeIntervalSince1970: time), text: "Approve the change?", source: .userNotify),
              isBusy: false)
    }

    @Test("@spec IOS-13.2: When mobile delivers an Attention notification, the application shall request notification authorization, present an authorized request with its project, worktree, and request text, and preserve a host-scoped activation payload without marking it viewed.")
    func deliversNativeRequest() async throws {
        var requests: [UNNotificationRequest] = []
        var authorizationCount = 0
        let delivery = MobileAttentionNotifications(authorize: { authorizationCount += 1; return true },
                                                    deliver: { requests.append($0) })
        let hostID = UUID()
        let pending = item()
        await delivery.enqueue(pending, hostID: hostID).value
        let request = try #require(requests.first)
        #expect(authorizationCount == 1)
        #expect(request.trigger == nil)
        #expect(request.content.title == pending.title)
        #expect(request.content.subtitle == "Project · Task")
        #expect(request.content.body == pending.occurrence?.text)
        let payload = try #require(MobileAttentionNotifications.Payload.decode(request.content.userInfo))
        #expect(payload.hostID == hostID)
        #expect(payload.item == pending)
        #expect(request.content.threadIdentifier == request.identifier)
    }

    @Test("@spec IOS-13.3: If mobile notification authorization is denied or delivery fails, then the application shall leave the Attention request pending without displaying a custom notification toast or marking it viewed.")
    func deniedPermissionRetainsAttention() async {
        let navigation = SidebarNavigationState(prefix: UUID().uuidString)
        let delivery = MobileAttentionNotifications(authorize: { false }, deliver: { _ in Issue.record("Unauthorized delivery") })
        let pending = item()
        navigation.updateAttentionItems([])
        var tasks: [Task<Void, Never>] = []
        navigation.attentionRequestHandler = { tasks.append(delivery.enqueue($0, hostID: UUID())) }
        navigation.updateAttentionItems([pending])
        for task in tasks { await task.value }
        #expect(!navigation.hasViewed(pending))
        #expect(navigation.attentionBanner == nil)
        #expect(navigation.attentionItems(live: [], projects: [.init(id: "project", repositoryID: "repo", name: "Project")]) == [pending])
    }

    @Test("Newer occurrences replace slower pending delivery and permission is requested once")
    func delayedAuthorizationCannotPostOldRequest() async throws {
        var continuation: CheckedContinuation<Bool, Never>?
        var authorizationCount = 0
        var requests: [UNNotificationRequest] = []
        let delivery = MobileAttentionNotifications(authorize: {
            authorizationCount += 1
            return await withCheckedContinuation { continuation = $0 }
        }, deliver: { requests.append($0) })
        let hostID = UUID()
        let first = delivery.enqueue(item(), hostID: hostID)
        while continuation == nil { await Task.yield() }
        let latest = item(time: 20)
        let second = delivery.enqueue(latest, hostID: hostID)
        continuation?.resume(returning: true)
        await first.value
        await second.value
        #expect(authorizationCount == 1)
        #expect(requests.count == 1)
        #expect(MobileAttentionNotifications.Payload.decode(try #require(requests.first).content.userInfo)?.item == latest)
    }

    @Test("Viewed or disconnected requests are suppressed after authorization finishes")
    func rechecksEligibilityBeforeDelivery() async {
        var current = true
        let delivery = MobileAttentionNotifications(authorize: { current = false; return true },
            deliver: { _ in Issue.record("Stale delivery") })
        await delivery.enqueue(item(), hostID: UUID(), isCurrent: { current }).value
    }

    @Test("Request identifiers separate hosts and group one worktree")
    func identifiersRespectHostAndWorktree() throws {
        let hostID = UUID()
        let first = try MobileAttentionNotifications.Payload(hostID: hostID, item: item()).request()
        var nextPane = item(time: 20)
        nextPane.id = "other-pane"
        nextPane.paneID = "other-pane"
        let second = try MobileAttentionNotifications.Payload(hostID: hostID, item: nextPane).request()
        let otherHost = try MobileAttentionNotifications.Payload(hostID: UUID(), item: item()).request()
        #expect(first.identifier == second.identifier)
        #expect(first.identifier != otherHost.identifier)
        #expect(MobileAttentionNotifications.Payload.decode([:]) == nil)
    }

    @Test("Agent notifications include the recap's question")
    func usesRecapText() throws {
        var pending = item()
        pending.agentStop = .init(agentName: "Codex", stoppedAt: .now,
            recap: .init(title: "Mobile notifications", completed: "Implementation ready.", next: "Review it.", need: "Ship this?"))
        let request = try MobileAttentionNotifications.Payload(hostID: UUID(), item: pending).request()
        #expect(request.content.title == "Mobile notifications")
        #expect(request.content.body == "Ship this?")
    }

    @Test func deliveryFailurePreservesRequest() async {
        enum DeliveryError: Error { case unavailable }
        let navigation = SidebarNavigationState(prefix: UUID().uuidString)
        let pending = item()
        navigation.updateAttentionItems([pending])
        let delivery = MobileAttentionNotifications(authorize: { true }, deliver: { _ in throw DeliveryError.unavailable })
        await delivery.enqueue(pending, hostID: UUID()).value
        #expect(navigation.isPendingAttentionRequest(pending))
    }

    #if canImport(UIKit)
    @Test("@spec IOS-13.4: When the user taps a mobile Attention notification, the application shall wait for unlock, route through its saved host to the request's project and worktree on iPhone or iPad, and acknowledge only the opened occurrence after a successful visit.", arguments: [false, true], [false, true])
    func activationRoutesWithoutAcknowledging(isCompact: Bool, showsProjectRail: Bool) throws {
        let host = Host(label: "Mac", baseURL: URL(string: "https://mac.local")!)
        let state = IPadAppState(defaults: try #require(UserDefaults(suiteName: UUID().uuidString)))
        state.sidebarNavigation = SidebarNavigationState(prefix: UUID().uuidString)
        state.selectedHostId = UUID()
        state.columnVisibility = .detailOnly
        let navigation = state.sidebarNavigation
        defer { MobilePaneAttention.consumePendingRoute(for: navigation) }
        let pending = item()
        var path = NavigationPath()
        let payload = MobileAttentionNotifications.Payload(hostID: host.id, item: pending)
        #expect(RootView.applyNotificationActivation(payload, hosts: [host], appState: state,
            navigationPath: &path, isCompact: isCompact, showsProjectRail: showsProjectRail))
        #expect(state.selectedHostId == host.id)
        #expect(state.selectedWorktreePath == nil)
        #expect(state.columnVisibility == .all)
        #expect(navigation.selectedProjectID == pending.projectID)
        #expect(MobilePaneAttention.pendingRoute(for: navigation) == pending)
        #expect(!navigation.hasViewed(pending))
        #expect(path.count == (isCompact ? (showsProjectRail ? 2 : 1) : 0))
        let opening = navigation.beginOpening(pending)
        navigation.finishOpening(opening, succeeded: false)
        #expect(!navigation.hasViewed(pending))
        let successful = navigation.beginOpening(pending)
        navigation.finishOpening(successful, succeeded: true)
        #expect(navigation.hasViewed(pending))
    }

    @Test func removedHostCannotBeActivated() throws {
        let state = IPadAppState(defaults: try #require(UserDefaults(suiteName: UUID().uuidString)))
        var path = NavigationPath()
        #expect(!RootView.applyNotificationActivation(.init(hostID: UUID(), item: item()), hosts: [],
            appState: state, navigationPath: &path, isCompact: true, showsProjectRail: true))
        #expect(path.isEmpty)
        #expect(MobilePaneAttention.pendingRoute(for: state.sidebarNavigation) == nil)
    }
    #endif

    @Test("A stored notification resolves fresh worktree routes without consuming a later occurrence")
    func resolvesCurrentWorktreeRoute() throws {
        let current = WorktreePanes(path: "new-route", displayName: "Task", repoDisplayName: "Project",
            displayBranch: "task", state: .running, isMainCheckout: false, prBadge: nil, stats: nil,
            attentionText: nil, layout: nil, sidebar: .init(id: "stable", projectID: "project"))
        var pending = item()
        pending.id = "stable:stop"
        let resolved = try #require(MobilePaneAttention.resolvedRoute(pending, worktrees: [current]))
        #expect(resolved.worktreeID == current.path)
        #expect(resolved.occurrence == pending.occurrence)
        pending.id = "deleted:stop"
        pending.worktreeID = current.path
        #expect(MobilePaneAttention.resolvedRoute(pending, worktrees: [current]) == nil)
    }
}
