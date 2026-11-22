#if canImport(UIKit)
import CryptoKit
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

    @Test("@spec WATCH-2.8: When a worktree has an unread notice, the watch shall show the notice text without offering a reply.")
    func unreadNoticeDisplaysItsMessage() throws {
        var sidebar = try #require(row().sidebar)
        var notice = try #require(sidebar.unseenAgentStop)
        notice.recap?.need = nil
        notice.recap?.notice = "The build is ready to install."
        sidebar.unseenAgentStop = notice
        sidebar.lastAgentStop = notice
        sidebar.unreadAgentNotices = [notice]
        let card = try #require(WatchAttentionProjection.card(row().with(sidebar: sidebar), host: host))
        #expect(card.question == notice.notice)
        #expect(card.isNotice == true)
        #expect(card.target == nil)
    }

    @Test func refreshedTerminalMustStillIdentifyTheSamePane() throws {
        let target = try #require(WatchAttentionProjection.terminalTargets(row(), host: host).first)
        var sidebar = try #require(row().sidebar)
        sidebar.paneIDs = ["pane": "replacement-slot"]
        #expect(throws: (any Error).self) {
            try WatchAttentionProjection.terminalRequest(target, rows: [row().with(sidebar: sidebar)], host: host)
        }
    }

    @Test func liveRelaySupersedesOfflineQuestionsAndRemovedPanes() throws {
        let relay = Host(label: "Relay", baseURL: URL(string: "https://relay.local")!)
        let owner = RemoteDeviceID(value: host.id.uuidString)
        var state = MultiHostFeedState()
        state.setHosts([.init(id: host.id, label: host.label, deviceID: owner, isWakeable: false),
                        .init(id: relay.id, label: relay.label, deviceID: nil, isWakeable: false)])
        state.apply(rows: [row()], projects: [], from: host.id)
        let previous = WatchAttentionProjection.snapshot(from: state, hosts: [host, relay], previous: .init())
        let relayed = row(need: nil).with(path: "/relay/alias",
            layout: .leaf(sessionName: "new-pane", title: "shell", attentionText: nil, isBusy: false, attentionSource: nil),
            origin: .init(deviceID: owner, deviceLabel: host.label, relayDepth: 1))
        state.markUnavailable(host.id)
        state.apply(rows: [relayed], projects: [], from: relay.id)
        let current = WatchAttentionProjection.snapshot(from: state, hosts: [host, relay], previous: previous)
        #expect(current.cards.isEmpty)
        #expect(current.terminals?.map(\.paneID) == ["new-pane"])
    }

    @Test func oversizedQuestionLeavesRoomForSmallerQuestionsAndTerminals() throws {
        var huge = try #require(WatchAttentionProjection.card(row(), host: host))
        let small = huge
        huge.question = String(repeating: "x", count: 64_000)
        let terminals = WatchAttentionProjection.terminalTargets(row(), host: host)
        let snapshot = WatchAttentionSnapshot(cards: [huge, small], terminals: terminals)
        let data = try snapshot.encodedForTransfer()
        let bounded = try JSONDecoder().decode(WatchAttentionSnapshot.self, from: data)
        #expect(bounded.cards == [small])
        #expect(bounded.omittedCount == 1)
        #expect(bounded.terminals == terminals)
    }

}

@MainActor
struct MobileWatchCompanionTests {
    @Test("@spec WATCH-2.7: When a phone window reports a host whose pairing was removed, the phone shall exclude that host's cached questions and terminals from watch updates.")
    func forgottenHostCannotReturnThroughAStaleWindow() async throws {
        let directory = try RemoteConnectionTestSupport.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let suite = "MobileWatchCompanionTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let key = Curve25519.Signing.PrivateKey()
        let host = try RemoteConnectionTestSupport.makePairedHost(directory: directory, serverKey: key)
        let device = try #require(host.remoteDeviceID)
        let pins = PinnedHostStore(directory: directory)
        var pin = try #require(try pins.get(id: device))
        pin.wakeOnLAN = try .init(hostDeviceID: device,
            targets: [.init(macAddress: "02:00:00:00:00:01", ipv4Address: "192.168.1.2")], signingKey: key)
        try pins.update(pin)
        let coordinator = RemoteConnectionCoordinator(directory: directory, connectionsAllowedInitially: false)
        let companion = MobileWatchCompanion(coordinator: coordinator, defaults: defaults)
        let staleWindow = MultiHostFeed(coordinator: coordinator)
        staleWindow.setHosts([host])
        var recap = AttentionRecap(title: "Watch", completed: "Built it", next: "Ship", need: "Ship?")
        recap.catchUp = "All checks passed."
        let stop = SidebarAgentStop(agentName: "Codex", stoppedAt: .now, recap: recap, paneSlotID: "slot")
        let row = WorktreePanes(path: "/wt", displayName: "watch", repoDisplayName: "Graftty", displayBranch: "watch",
            state: .running, isMainCheckout: false, prBadge: nil, stats: nil, attentionText: nil,
            layout: .leaf(sessionName: "pane", title: "Codex", attentionText: nil, isBusy: false, attentionSource: nil),
            sidebar: .init(id: "/wt", projectID: "p", paneIDs: ["pane": "slot"], unseenAgentStop: stop, lastAgentStop: stop))
        staleWindow.receive(.frame(.snapshot([row])), from: host)
        companion.setEnabled(true)
        companion.update(from: staleWindow)
        #expect(try snapshot(in: defaults).cards.count == 1)
        #expect(try snapshot(in: defaults).terminals?.count == 1)

        // Another window forgets the Mac. This window still owns its prior
        // host inventory and the wakeable host's retained worktree rows.
        try await coordinator.forget(host)
        companion.update(from: MultiHostFeed(coordinator: coordinator))
        staleWindow.receive(.unavailable, from: host)
        #expect(staleWindow.hosts == [host])
        #expect(staleWindow.state.rows.count == 1)
        companion.update(from: staleWindow)
        let snapshot = try snapshot(in: defaults)
        #expect(snapshot.cards.isEmpty)
        #expect(snapshot.terminals?.isEmpty == true)
        #expect(snapshot.unavailableHosts.isEmpty)
    }

    private func snapshot(in defaults: UserDefaults) throws -> WatchAttentionSnapshot {
        let bytes = try #require(defaults.data(forKey: WatchCompanionSettings.snapshotKey))
        return try JSONDecoder().decode(WatchAttentionSnapshot.self, from: bytes)
    }
}
#endif
