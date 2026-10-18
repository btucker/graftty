import Foundation
import GrafttyProtocol
import Testing
@testable import GrafttyMobileKit

struct MobileStopNotificationTests {
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
