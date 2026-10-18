#if GRAFTTY_BROWSER_CONTROL_FIXTURE
import Foundation
import GrafttyProtocol
import SwiftUI
import UserNotifications
@testable import GrafttyMobileKit

/// The fixture substitutes host I/O, not notification decoding or RootView activation.
/// It runs only in the isolated interaction host. Captured provider stop fields
/// retain their original timestamp, worktree and session identity.
@MainActor
final class NotificationActivationFixture {
    struct Stop: Codable {
        let worktree: String
        let runtime: String
        let sessionID: String?
        let paneSessionName: String?
        let recap: AttentionRecap?
        let stoppedAt: Date
    }

    struct Configuration: Codable {
        let id: UUID
        let endpoint: URL
        let host: Host
        let relayHostID: UUID
        let stops: [Stop]
        let mode: String
        let holdFetch: Bool
    }

    private static let configurationKey = "notification-activation-fixture"
    static var restored: NotificationActivationFixture?
    let configuration: Configuration
    let notifications: MobileAgentNotifications
    let state: IPadAppState
    let store: HostStore
    let defaults: UserDefaults
    let gate = BiometricGate(authenticator: FixtureAuthenticator())
    var fetchCount = 0
    var fetchHeld: Bool
    var disconnected: Bool
    var waiters: [CheckedContinuation<Void, Never>] = []
    var submitted: [String]
    var eventIndex = 0

    struct FixtureAuthenticator: BiometricAuthenticator {
        func authenticate() async -> Result<Void, Error> { .success(()) }
    }

    init(configuration: Configuration, restoring: Bool) throws {
        self.configuration = configuration
        let defaults = UserDefaults(suiteName: "notification-fixture-\(configuration.id)")!
        self.defaults = defaults
        state = IPadAppState(defaults: defaults)
        let store = HostStore(storeURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("notification-fixture-\(configuration.id).json"))
        try store.add(configuration.host)
        self.store = store
        notifications = MobileAgentNotifications(defaults: defaults, prepareRequest: { request in
            guard ["background", "cold"].contains(configuration.mode) else { return request }
            // Give XCUITest time to leave or terminate the app before the OS
            // delivers the original production content. This controls timing
            // only; decoding, delegate receipt and RootView remain production.
            return UNNotificationRequest(identifier: request.identifier, content: request.content,
                trigger: UNTimeIntervalNotificationTrigger(timeInterval: 5, repeats: false))
        })
        fetchHeld = !restoring && configuration.holdFetch
        disconnected = !restoring && configuration.mode == "disconnected"
        submitted = defaults.stringArray(forKey: "submittedRequests") ?? []
        eventIndex = defaults.integer(forKey: "eventIndex")
        notifications.didSubmitRequest = { [weak self] request in
            guard let self else { return }
            submitted.append(request.identifier)
            defaults.set(submitted, forKey: "submittedRequests")
        }
        notifications.install()
    }

    /// Called from the test application's initializer, before launch completes.
    static func installRestoredIfNeeded() {
        guard let data = UserDefaults.standard.data(forKey: configurationKey),
              let configuration = try? JSONDecoder().decode(Configuration.self, from: data) else { return }
        restored = try? .init(configuration: configuration, restoring: true)
    }

    static var restoredEndpoint: URL? {
        guard let data = UserDefaults.standard.data(forKey: configurationKey) else { return nil }
        return (try? JSONDecoder().decode(Configuration.self, from: data))?.endpoint
    }

    static func prepare(_ command: AgentIntegrationCommand, endpoint: URL) async throws -> NotificationActivationFixture {
        guard let encoded = command.parameters["events"] else { throw AgentIntegrationError("missing provider stop events") }
        let stops = try JSONDecoder().decode([Stop].self, from: Data(encoded.utf8))
        guard !stops.isEmpty else { throw AgentIntegrationError("provider produced no stopped turns") }
        let mode = command.parameters["mode"] ?? "warm"
        guard mode == "ambiguous" || stops.allSatisfy({ $0.paneSessionName?.isEmpty == false }) else {
            throw AgentIntegrationError("provider stop is missing its actual pane session")
        }
        let id = UUID()
        let configuration = Configuration(id: id, endpoint: endpoint,
            host: Host(label: "Notification fixture Mac", baseURL: URL(string: "https://notification-fixture.invalid")!,
                remoteDeviceID: .init(value: "notification-fixture-owner-\(id)")), relayHostID: UUID(),
            stops: stops, mode: mode, holdFetch: command.parameters["holdFetch"] == "true")
        let fixture = try NotificationActivationFixture(configuration: configuration, restoring: false)
        UserDefaults.standard.set(try JSONEncoder().encode(configuration), forKey: configurationKey)
        restored = fixture
        UNUserNotificationCenter.current().removeAllDeliveredNotifications()
        UNUserNotificationCenter.current().removeAllPendingNotificationRequests()
        Task { await fixture.notifications.requestAuthorization() }
        return fixture
    }

    var root: some View {
        RootView(hostStore: store, gate: gate, notifications: notifications, appState: state,
            notificationIO: .init(fetch: { [self] _ in
                fetchCount += 1
                if fetchHeld { await withCheckedContinuation { waiters.append($0) } }
                if disconnected { throw AgentIntegrationError("fixture host disconnected") }
                return [try row(eventIndex)]
            }, reopen: { _, _ in throw AgentIntegrationError("running fixture worktree must not reopen") }))
            .overlay(alignment: .top) {
                VStack {
                    Text("Host=\(state.selectedHostId?.uuidString ?? "") Worktree=\(state.selectedWorktreePath ?? "") Pane=\(state.focusedPaneId ?? "")")
                        .font(.caption2)
                        .accessibilityIdentifier("Notification activation selection")
                    Button("Choose unrelated pane") { [self] in
                        RootView.applyCompactSession(.init(host: configuration.host,
                            worktreePath: configuration.stops[eventIndex].worktree,
                            sessionName: "notification-unrelated-pane", title: "Unrelated"), to: state)
                    }.accessibilityIdentifier("Notification choose unrelated pane")
                }.background(.regularMaterial)
            }
    }

    func row(_ index: Int, relayed: Bool = false) throws -> WorktreePanes {
        guard configuration.stops.indices.contains(index) else { throw AgentIntegrationError("invalid stop index") }
        let event = configuration.stops[index]
        let originalSession = event.paneSessionName ?? "notification-target-pane"
        let session = relayed ? "relay:\(originalSession)" : originalSession
        let inputRequest = configuration.mode == "input"
        let stop = SidebarAgentStop(agentName: event.runtime, stoppedAt: event.stoppedAt,
            recap: event.recap, paneSlotID: configuration.mode == "ambiguous" ? nil : "target-slot",
            providerSessionKey: event.sessionID)
        return .init(path: relayed ? "relay:\(event.worktree)" : event.worktree, displayName: "Notification task", repoDisplayName: "Provider integration",
            displayBranch: "notification-task", state: .running, isMainCheckout: false, prBadge: nil,
            stats: nil, attentionText: nil, layout: .split(direction: .horizontal, ratio: 0.5,
                left: .leaf(sessionName: "notification-unrelated-pane", title: "Unrelated", attentionText: nil,
                    isBusy: false, attentionSource: nil),
                right: .leaf(sessionName: session, title: "Provider",
                    attentionText: inputRequest ? "\(event.runtime) needs input" : nil,
                    isBusy: false, attentionSource: inputRequest ? .agentStop : nil,
                    attentionTimestamp: inputRequest ? event.stoppedAt : nil)),
            origin: .init(deviceID: configuration.host.remoteDeviceID!, deviceLabel: configuration.host.label,
                relayDepth: relayed ? 1 : 0),
            sidebar: .init(id: "fixture:\(event.worktree)", projectID: "notification-project",
                paneIDs: ["notification-unrelated-pane": "unrelated-slot", session: "target-slot"],
                unseenAgentStop: inputRequest ? nil : stop, lastAgentStop: inputRequest ? nil : stop))
    }

    func handle(_ command: AgentIntegrationCommand) async throws -> [String: String] {
        switch command.operation {
        case "notificationsDeliver":
            guard let index = Int(command.parameters["eventIndex"] ?? "0"),
                  configuration.stops.indices.contains(index),
                  let copies = Int(command.parameters["copies"] ?? "1"), (1...10).contains(copies)
            else { throw AgentIntegrationError("invalid stop index or notification copy count") }
            eventIndex = index
            defaults.set(eventIndex, forKey: "eventIndex")
            for copy in 0..<copies {
                let relayed = command.parameters["source"] == "alternating" && !copy.isMultiple(of: 2)
                await notifications.receive([try row(eventIndex, relayed: relayed)],
                    hostID: relayed ? configuration.relayHostID : configuration.host.id)
            }
        case "notificationsRelease":
            disconnected = false
            fetchHeld = false
            let pending = waiters
            waiters.removeAll()
            for waiter in pending { waiter.resume() }
        case "notificationsState": break
        default: throw AgentIntegrationError("unsupported notification fixture command \(command.operation)")
        }
        var result = try snapshot()
        result["authorization"] = String(describing: await UNUserNotificationCenter.current().notificationSettings().authorizationStatus)
        return result
    }

    func snapshot() throws -> [String: String] {
        guard configuration.stops.indices.contains(eventIndex) else { throw AgentIntegrationError("invalid saved stop index") }
        let event = configuration.stops[eventIndex]
        var ledger = MobileStopNotificationLedger()
        let title = ledger.receive([try row(eventIndex)], hostID: configuration.host.id).first?.title ?? ""
        return ["expectedHost": configuration.host.id.uuidString, "expectedWorktree": event.worktree,
            "expectedPane": event.paneSessionName ?? "", "title": title,
            "selectedHost": state.selectedHostId?.uuidString ?? "", "worktree": state.selectedWorktreePath ?? "",
            "pane": state.focusedPaneId ?? "", "pending": String(notifications.pendingRoute != nil),
            "fetchCount": String(fetchCount), "requestCount": String(submitted.count),
            "requestIDs": String(decoding: try JSONEncoder().encode(submitted), as: UTF8.self)]
    }

    func finish() {
        if let route = notifications.pendingRoute { notifications.consume(route) }
        fetchHeld = false
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume() }
        UserDefaults.standard.removeObject(forKey: Self.configurationKey)
        Self.restored = nil
        UNUserNotificationCenter.current().removeAllDeliveredNotifications()
        UNUserNotificationCenter.current().removeAllPendingNotificationRequests()
    }
}

/// Construct the fixture content inside View.body so Observation subscribes to
/// selection changes and the native accessibility overlay stays current.
struct NotificationActivationFixtureView: View {
    let fixture: NotificationActivationFixture
    var body: some View { fixture.root }
}
#endif
