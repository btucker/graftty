import Foundation
import GrafttyProtocol
import Testing
@testable import GrafttyMobileKit

struct MobileStopNotificationTests {
    private func splitRow(_ time: Double, state: WorktreeWireState = .running, suffix: String = "", unseen: Bool = false) -> WorktreePanes {
        let stop = SidebarAgentStop(agentName: "Codex", stoppedAt: Date(timeIntervalSinceReferenceDate: time), paneSlotID: "second-slot")
        return .init(path: "/task", displayName: "Task", repoDisplayName: "Project", displayBranch: "task",
            state: state, isMainCheckout: false, prBadge: nil, stats: nil, attentionText: nil,
            layout: state == .closed ? nil : .split(direction: .horizontal, ratio: 0.5,
                left: .leaf(sessionName: "first" + suffix, title: "First", attentionText: nil, isBusy: false, attentionSource: nil),
                right: .leaf(sessionName: "second" + suffix, title: "Second", attentionText: nil, isBusy: false, attentionSource: nil)),
            sidebar: .init(id: "task", projectID: "project", paneIDs: ["first" + suffix: "first-slot", "second" + suffix: "second-slot"],
                unseenAgentStop: unseen ? stop : nil, lastAgentStop: stop))
    }

    @Test func acknowledgedStopsRetainTheirPaneAcrossReopening() throws {
        let host = UUID()
        var ledger = MobileStopNotificationLedger()
        _ = ledger.receive([splitRow(10)], hostID: host)
        let notification = try #require(ledger.receive([splitRow(20)], hostID: host).first)
        #expect(notification.route.paneID == "second")
        let restored = try JSONDecoder().decode(MobileStopNotificationRoute.self, from: JSONEncoder().encode(notification.route))
        #expect(restored.pane(in: splitRow(20, suffix: "-new"))?.sessionName == "second-new")
    }

    @Test("@spec NOTIF-1.20: When a mobile notification opens a closed worktree, the application shall reopen it and wait for a running pane, restore the stable pane target, and cancel activation if newer navigation supersedes it.")
    @MainActor func activationWaitsForReadinessAndHonorsNewerNavigation() async throws {
        let route = MobileStopNotificationRoute(hostID: UUID(), worktreePath: "/task", worktreeID: "task",
            originDeviceID: nil, paneID: "second", paneSlotID: "second-slot")
        var reads = 0, opens = 0
        let result = try await MobileNotificationActivation.resolve(route, fetch: {
            reads += 1
            return [splitRow(20, state: reads < 3 ? .closed : .running, suffix: "-new")]
        }, reopen: { path in
            #expect(path == "/task")
            opens += 1
        }, isCurrent: { true }, pause: {})
        #expect(opens == 1)
        #expect(result.pane.sessionName == "second-new")
        var current = true
        await #expect(throws: CancellationError.self) {
            try await MobileNotificationActivation.resolve(route, fetch: {
                current = false
                return [splitRow(20, state: .closed)]
            }, reopen: { _ in opens += 1 }, isCurrent: { current }, pause: {})
        }
        #expect(opens == 1)
    }

    private func row(_ time: Double, recap: AttentionRecap? = nil, unseen: Bool = true) -> WorktreePanes {
        let stop = SidebarAgentStop(agentName: "Codex", stoppedAt: Date(timeIntervalSinceReferenceDate: time), recap: recap)
        return .init(path: "/task", displayName: "Task", repoDisplayName: "Project", displayBranch: "task",
                     state: .running, isMainCheckout: false, prBadge: nil, stats: nil, attentionText: nil, layout: nil,
                     sidebar: .init(id: "task", projectID: "project", unseenAgentStop: unseen ? stop : nil, lastAgentStop: stop))
    }

    @Test("@spec NOTIF-1.12: When a mobile client receives a new stopped turn, the application shall create a native notification for stops with or without reports, deduplicate repeated and older snapshots across reconnects and relaunches, and keep hosts distinct.")
    func everyStopIsDeduplicatedAndHostsAreDistinct() throws {
        var ledger = MobileStopNotificationLedger()
        let host = UUID(), other = UUID()
        let first = ledger.receive([row(10)], hostID: host)
        #expect(first.count == 1)
        #expect(first.first?.body == "Codex stopped.")
        #expect(first.first?.route.worktreePath == "/task")
        #expect(ledger.receive([row(10)], hostID: host).isEmpty)
        #expect(ledger.receive([row(9)], hostID: host).isEmpty)
        #expect(ledger.receive([row(10)], hostID: other).count == 1)
        var restored = try JSONDecoder().decode(MobileStopNotificationLedger.self, from: JSONEncoder().encode(ledger))
        #expect(restored.receive([row(10)], hostID: host).isEmpty)
        let next = restored.receive([row(20, recap: .init(title: "Context", completed: "Built the drawer.", next: "Review."))], hostID: host)
        #expect(next.first?.title == "Context")
        #expect(next.first?.body == "Built the drawer.")
        #expect(next.first?.identifier == first.first?.identifier)
    }

    @Test("@spec NOTIF-1.14: When an agent requests permission or input on mobile, the application shall deliver a native notification once per new request, suppress command-finished markers, and suppress an older prompt superseded by a stop at the same pane.")
    func waitingRequestsNotifyWithoutACompletedTurn() {
        let host = UUID()
        var ledger = MobileStopNotificationLedger()
        func prompt(_ time: Double, source: AttentionSource = .agentStop, stoppedAt: Double? = nil) -> WorktreePanes {
            .init(path: "/task", displayName: "Task", repoDisplayName: "Project", displayBranch: "task",
                state: .running, isMainCheckout: false, prBadge: nil, stats: nil, attentionText: nil,
                layout: .leaf(sessionName: "pane", title: "Agent", attentionText: "Codex needs permission", isBusy: false,
                    attentionSource: source, attentionTimestamp: Date(timeIntervalSinceReferenceDate: time)),
                sidebar: .init(id: "task", projectID: "project", unseenAgentStop: stoppedAt.map {
                    SidebarAgentStop(agentName: "Codex", stoppedAt: Date(timeIntervalSinceReferenceDate: $0))
                }))
        }
        let first = ledger.receive([prompt(10)], hostID: host)
        #expect(first.count == 1)
        #expect(first.first?.body == "Codex needs permission")
        #expect(first.first?.route.paneID == "pane")
        #expect(ledger.receive([prompt(10)], hostID: host).isEmpty)
        #expect(ledger.receive([prompt(20)], hostID: host).count == 1)
        #expect(ledger.receive([prompt(30, source: .commandFinished)], hostID: host).isEmpty)
        #expect(ledger.receive([prompt(20, stoppedAt: 40)], hostID: host).count == 1)
    }

    @Test func previouslyReadHistoryDoesNotNotifyOnFirstConnection() {
        var ledger = MobileStopNotificationLedger()
        let host = UUID()
        #expect(ledger.receive([row(10, unseen: false)], hostID: host).isEmpty)
        #expect(ledger.receive([row(20, unseen: false)], hostID: host).count == 1)
    }
}
