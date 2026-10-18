import Foundation
import GrafttyProtocol
import Testing
@testable import GrafttyMobileKit

struct MobileNotificationDeduplicationTests {
    private func row(_ time: Double, owner: String = "origin-mac", relayed: Bool = false,
                     body: String = "Tests passed.") -> WorktreePanes {
        let stop = SidebarAgentStop(agentName: "Codex",
            stoppedAt: Date(timeIntervalSinceReferenceDate: time),
            recap: .init(title: "Notification routing", completed: body, next: "Review."),
            paneSlotID: "agent-slot", providerSessionKey: "codex:session:fixture")
        let session = relayed ? "relay-pane-alias" : "local-pane"
        return .init(path: relayed ? "relay-worktree-alias" : "/repo/task", displayName: "Task",
            repoDisplayName: "Project", displayBranch: "task", state: .running,
            isMainCheckout: false, prBadge: nil, stats: nil, attentionText: nil,
            layout: .leaf(sessionName: session, title: "Agent", attentionText: nil, isBusy: false, attentionSource: nil),
            origin: .init(deviceID: .init(value: owner), deviceLabel: "Origin Mac", relayDepth: relayed ? 1 : 0),
            sidebar: .init(id: "stable-worktree", projectID: "stable-project", paneIDs: [session: "agent-slot"],
                unseenAgentStop: stop, lastAgentStop: stop))
    }

    @Test("@spec NOTIF-1.23: When mobile receives the same originating stop through direct and relayed connections, the application shall notify once across reconnects and relaunches while preserving distinct origins and later occurrences.", arguments: [false, true])
    func directAndRelayedOccurrencesNotifyOnce(relayFirst: Bool) throws {
        var ledger = MobileStopNotificationLedger()
        let direct = UUID(), relay = UUID()
        #expect(ledger.receive([row(10, relayed: relayFirst)], hostID: relayFirst ? relay : direct).count == 1)
        #expect(ledger.receive([row(10, relayed: !relayFirst)], hostID: relayFirst ? direct : relay).isEmpty)
        #expect(ledger.receive([row(10)], hostID: direct).isEmpty)
        var restored = try JSONDecoder().decode(MobileStopNotificationLedger.self, from: JSONEncoder().encode(ledger))
        // A re-added connection can have another local UUID for the same owner.
        #expect(restored.receive([row(10)], hostID: UUID()).isEmpty)
        #expect(restored.receive([row(20)], hostID: direct).count == 1)
        #expect(restored.receive([row(20, relayed: true)], hostID: relay).isEmpty)
        #expect(restored.receive([row(20, owner: "another-mac")], hostID: UUID()).count == 1)
        #expect(restored.receive([row(21, body: "A different result.")], hostID: UUID()).count == 1)
    }

    @Test func legacyLedgerStillDecodes() throws {
        var ledger = try JSONDecoder().decode(MobileStopNotificationLedger.self,
            from: Data(#"{"timestamps":{}}"#.utf8))
        #expect(ledger.receive([row(10)], hostID: UUID()).count == 1)
    }
}
