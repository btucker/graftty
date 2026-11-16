#if canImport(UIKit)
import Foundation
import Testing
import GrafttyProtocol
import GrafttyRemoteClient
import GrafttyWatchKit
@testable import GrafttyMobileKit

@MainActor
struct WatchAttentionProjectionTests {
    private let host = Host(label: "Desk", baseURL: URL(string: "https://desk.local")!)

    private func row(need: String? = "Ship?", permission: Bool = false, resumed: Bool = false) -> WorktreePanes {
        var recap = AttentionRecap(title: "Watch", completed: "Built it", next: "Ship", need: need)
        recap.catchUp = "All checks passed."
        recap.options = [.init(label: "Ship", cost: "Publish now", suggested: true), .init(label: "Wait")]
        let stop = SidebarAgentStop(agentName: "Codex", stoppedAt: Date(timeIntervalSinceReferenceDate: 100),
                                   recap: recap, paneSlotID: "slot", providerSessionKey: "agent")
        return .init(path: "/wt", displayName: "watch", repoDisplayName: "Graftty", displayBranch: "watch",
            state: .running, isMainCheckout: false, prBadge: nil, stats: nil, attentionText: nil,
            layout: .leaf(sessionName: "pane", title: "codex", attentionText: permission ? "Allow command?" : nil,
                          isBusy: false, attentionSource: permission ? .agentStop : nil),
            sidebar: .init(id: "/wt", projectID: "p", paneIDs: ["pane": "slot"],
                unseenAgentStop: permission ? nil : stop, lastAgentStop: permission ? nil : stop,
                agentProgressTimes: resumed ? ["agent": 101] : nil))
    }

    @Test("@spec WATCH-2.1: When a paired iPhone projects a worktree's stopped question for Apple Watch, the application shall include its context and choices and preserve the host-validated occurrence and asking pane for replies.")
    func projectsReplyableQuestion() throws {
        let card = try #require(WatchAttentionProjection.card(row(), host: host))
        #expect(card.question == "Ship?")
        #expect(card.context == "All checks passed.")
        #expect(card.options.map(\.label) == ["Ship", "Wait"])
        let request = try WatchAttentionProjection.answer(card, text: " Ship ", rows: [row()], host: host)
        guard case .answerRequest(let path, let pane, let occurrence, let text) = request else {
            Issue.record("Expected answer request"); return
        }
        #expect(path == "/wt")
        #expect(pane == "pane")
        #expect(text == "Ship")
        #expect(occurrence == row().sidebar?.unseenAgentStop?.occurrence)
    }

    @Test("@spec WATCH-2.2: If a watch reply's host, question, occurrence, or pane no longer matches a fresh authenticated snapshot, then the iPhone shall refuse the reply before delivering it.")
    func rejectsChangedTargets() throws {
        let card = try #require(WatchAttentionProjection.card(row(), host: host))
        #expect(throws: (any Error).self) { try WatchAttentionProjection.answer(card, text: "Ship", rows: [row(need: "Delete?")], host: host) }
        #expect(throws: (any Error).self) { try WatchAttentionProjection.answer(card, text: "Ship", rows: [], host: host) }
        let other = Host(label: "Other", baseURL: URL(string: "https://other.local")!)
        #expect(throws: (any Error).self) { try WatchAttentionProjection.answer(card, text: "Ship", rows: [row()], host: other) }
        var moved = card
        moved.target?.paneID = "other-pane"
        #expect(throws: (any Error).self) { try WatchAttentionProjection.answer(moved, text: "Ship", rows: [row()], host: host) }
        #expect(throws: (any Error).self) { try WatchAttentionProjection.answer(card, text: " \n", rows: [row()], host: host) }
    }

    @Test("@spec WATCH-2.3: While an attention request belongs to a harness permission prompt, the watch shall display the request without offering a text reply; resumed agents and routine recaps shall not appear as questions.")
    func permissionPromptsAreViewOnly() throws {
        let prompt = try #require(WatchAttentionProjection.card(row(permission: true), host: host))
        #expect(prompt.question == "Allow command?")
        #expect(prompt.target == nil)
        #expect(WatchAttentionProjection.card(row(need: nil), host: host) == nil)
        #expect(WatchAttentionProjection.card(row(resumed: true), host: host) == nil)
    }

    @Test("@spec WATCH-2.4: If a paired host becomes unavailable, then the iPhone shall retain its last watch questions with an unavailable label, remove forgotten hosts' questions, and avoid repeating a worktree delivered by a live route.")
    func offlineHostsRetainQuestionsUntilForgotten() throws {
        var state = MultiHostFeedState()
        state.setHosts([.init(id: host.id, label: host.label, deviceID: nil, isWakeable: false)])
        let previous = WatchAttentionSnapshot(cards: [try #require(WatchAttentionProjection.card(row(), host: host))], updatedAt: .now)
        let offline = WatchAttentionProjection.snapshot(from: state, hosts: [host], previous: previous)
        #expect(offline.cards == previous.cards)
        #expect(offline.unavailableHosts == ["Desk"])
        state.apply(rows: [row()], projects: [], from: host.id)
        let live = WatchAttentionProjection.snapshot(from: state, hosts: [host], previous: offline)
        #expect(live.cards.count == 1)
        #expect(live.unavailableHosts.isEmpty)
        #expect(WatchAttentionProjection.snapshot(from: state, hosts: [], previous: live).cards.isEmpty)
    }

    @Test("@spec WATCH-3.5: When the watch browses terminals, the iPhone shall include running panes even without a question, link attention cards to their asking pane, and refuse terminal reads whose host, worktree, or pane is no longer present.")
    func terminalRoutesAreIndependentOfQuestions() throws {
        let terminals = WatchAttentionProjection.terminalTargets(row(need: nil), host: host)
        let target = try #require(terminals.first)
        #expect(terminals.count == 1)
        #expect(target.paneID == "pane")
        #expect(WatchAttentionProjection.card(row(), host: host)?.terminal?.id == target.id)
        #expect(WatchAttentionProjection.card(row(permission: true), host: host)?.terminal?.id == target.id)
        #expect(try WatchAttentionProjection.terminalRequest(target, rows: [row(need: nil)], host: host)
            == .terminalText(worktreeID: "/wt", paneID: "pane", lines: 200))
        #expect(throws: (any Error).self) { try WatchAttentionProjection.terminalRequest(target, rows: [], host: host) }
        var wrong = target
        wrong.paneID = "another"
        #expect(throws: (any Error).self) { try WatchAttentionProjection.terminalRequest(wrong, rows: [row()], host: host) }
        wrong = target
        wrong.hostID = UUID()
        #expect(throws: (any Error).self) { try WatchAttentionProjection.terminalRequest(wrong, rows: [row()], host: host) }
        var state = MultiHostFeedState()
        state.setHosts([.init(id: host.id, label: host.label, deviceID: nil, isWakeable: false)])
        state.apply(rows: [row(need: nil)], projects: [], from: host.id)
        let snapshot = WatchAttentionProjection.snapshot(from: state, hosts: [host], previous: .init())
        #expect(snapshot.cards.isEmpty)
        #expect(snapshot.terminals?.count == 1)
    }
}
#endif
