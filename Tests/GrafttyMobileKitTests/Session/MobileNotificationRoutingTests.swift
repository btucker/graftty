import Foundation
import GrafttyProtocol
import Testing
@testable import GrafttyMobileKit

struct MobileNotificationRoutingTests {
    private func row(split: Bool) -> WorktreePanes {
        let first = PaneLayoutNode.leaf(sessionName: "first", title: "First", attentionText: nil,
            isBusy: false, attentionSource: nil)
        let second = PaneLayoutNode.leaf(sessionName: "second", title: "Second", attentionText: nil,
            isBusy: false, attentionSource: nil)
        return .init(path: "/task", displayName: "Task", repoDisplayName: "Project", displayBranch: "task",
            state: .running, isMainCheckout: false, prBadge: nil, stats: nil, attentionText: nil,
            layout: split ? .split(direction: .horizontal, ratio: 0.5, left: first, right: second) : first,
            sidebar: .init(id: "task", projectID: "project",
                paneIDs: ["first": "first-slot", "second": "second-slot"]))
    }

    private var untargetedRoute: MobileStopNotificationRoute {
        .init(hostID: UUID(), worktreePath: "/task", worktreeID: "task", originDeviceID: nil, paneID: nil)
    }

    @Test("@spec NOTIF-1.24: If a mobile notification lacks a pane identity and its worktree has multiple panes, then the application shall report that the pane cannot be identified instead of opening an unrelated pane.")
    @MainActor func ambiguousNotificationDoesNotChooseFirstPane() async {
        let route = untargetedRoute
        #expect(route.pane(in: row(split: true)) == nil)
        do {
            _ = try await MobileNotificationActivation.resolve(route, fetch: { [row(split: true)] },
                reopen: { _ in Issue.record("A running worktree must not be reopened") }, isCurrent: { true })
            Issue.record("An ambiguous notification must not select a pane")
        } catch MobileNotificationActivation.Failure.paneUnavailable {
            // Expected: choosing either split pane would invent a target.
        } catch {
            Issue.record("Unexpected activation failure: \(error)")
        }
    }

    @Test func untargetedNotificationCanOpenTheOnlyPane() throws {
        #expect(try #require(untargetedRoute.pane(in: row(split: false))).sessionName == "first")
    }

    @Test func missingExplicitPaneMustNotFallBackToTheOnlyPane() {
        var route = untargetedRoute
        route.paneSlotID = "deleted-slot"
        #expect(route.pane(in: row(split: false)) == nil)
    }

    @Test func explicitStablePaneWinsOverLeafOrder() throws {
        var route = untargetedRoute
        route.paneSlotID = "second-slot"
        #expect(try #require(route.pane(in: row(split: true))).sessionName == "second")
    }
}
