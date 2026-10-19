#if GRAFTTY_BROWSER_CONTROL_FIXTURE
import Foundation
import GhosttyTerminal
import GrafttyProtocol
import GrafttyRemoteClient
import SwiftUI
import UIKit
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
        let fingerprint: RemoteIdentityFingerprint
        let relayHostID: UUID
        let unrelatedPane: String
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
    let retainedPanes = RetainedPaneClientPool<RetainedMobilePane>()
    private var connection: RemoteHostConnection?
    private var connectionTask: Task<RemoteHostConnection, Error>?
    private var finished = false
    private var transportError = ""
    private var observationSequence = 0
    private var responseIDs: [String] = []
    private var responseRoutes: [MobileStopNotificationRoute] = []
    private var observedScenePhases: [String] = []
    private var sceneProbeIDs: [UUID] = []

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
        disconnected = !restoring && ["disconnected", "active-retry"].contains(configuration.mode)
        submitted = defaults.stringArray(forKey: "submittedRequests") ?? []
        eventIndex = defaults.integer(forKey: "eventIndex")
        notifications.didSubmitRequest = { [weak self] request in
            guard let self else { return }
            submitted.append(request.identifier)
            defaults.set(submitted, forKey: "submittedRequests")
        }
        notifications.didReceiveResponse = { [weak self] identifier, route in
            self?.responseIDs.append(identifier)
            self?.responseRoutes.append(route)
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

    static func prepare(_ command: AgentIntegrationCommand, endpoint: URL,
        fingerprint: RemoteIdentityFingerprint) async throws -> NotificationActivationFixture {
        guard let encoded = command.parameters["events"] else { throw AgentIntegrationError("missing provider stop events") }
        let stops = try JSONDecoder().decode([Stop].self, from: Data(encoded.utf8))
        guard !stops.isEmpty else { throw AgentIntegrationError("provider produced no stopped turns") }
        let mode = command.parameters["mode"] ?? "warm"
        guard mode == "ambiguous" || stops.allSatisfy({ $0.paneSessionName?.isEmpty == false }) else {
            throw AgentIntegrationError("provider stop is missing its actual pane session")
        }
        guard let unrelatedPane = command.parameters["unrelatedPane"], !unrelatedPane.isEmpty,
              stops.allSatisfy({ $0.paneSessionName != unrelatedPane }) else {
            throw AgentIntegrationError("missing distinct real sibling pane session")
        }
        let id = UUID()
        let configuration = Configuration(id: id, endpoint: endpoint,
            host: Host(label: "Notification fixture Mac", baseURL: URL(string: "https://notification-fixture.invalid")!,
                remoteDeviceID: .init(value: "notification-fixture-owner-\(id)")), fingerprint: fingerprint, relayHostID: UUID(),
            unrelatedPane: unrelatedPane, stops: stops, mode: mode, holdFetch: command.parameters["holdFetch"] == "true")
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
            }, reopen: { _, _ in throw AgentIntegrationError("running fixture worktree must not reopen") }),
            connectionProvider: { [weak self] in await self?.remoteConnection() }, retainedPanes: retainedPanes)
            .overlay(alignment: .top) {
                VStack {
                    Text("Host=\(state.selectedHostId?.uuidString ?? "") Worktree=\(state.selectedWorktreePath ?? "") Pane=\(state.focusedPaneId ?? "")")
                        .font(.caption2)
                        .accessibilityIdentifier("Notification activation selection")
                    Button("Choose unrelated pane") { [self] in
                        RootView.applyCompactSession(.init(host: configuration.host,
                            worktreePath: configuration.stops[eventIndex].worktree,
                            sessionName: configuration.unrelatedPane, title: "Other provider"), to: state)
                    }.accessibilityIdentifier("Notification choose unrelated pane")
                }.background(.regularMaterial)
            }
            .background(NotificationFixtureScenePhaseProbe(fixture: self))
    }

    func observeScenePhase(_ phase: ScenePhase) {
        let value: String
        switch phase {
        case .active: value = "active"
        case .inactive: value = "inactive"
        case .background: value = "background"
        @unknown default: value = "unknown"
        }
        if observedScenePhases.last != value { observedScenePhases.append(value) }
    }

    func sceneProbeAppeared(_ id: UUID, phase: ScenePhase) {
        if !sceneProbeIDs.contains(id) { sceneProbeIDs.append(id) }
        observeScenePhase(phase)
    }

    private func remoteConnection() async -> RemoteHostConnection? {
        guard !finished else { return nil }
        if let connection, await connection.state == .connected { return finished ? nil : connection }
        if let connectionTask {
            let next = try? await connectionTask.value
            return finished ? nil : next
        }
        guard !finished else { return nil }
        let endpoint = configuration.endpoint
        let fingerprint = configuration.fingerprint
        let previous = connection
        connection = nil
        let task = Task {
            await previous?.close()
            let transport = AgentIntegrationTransport(endpoint: endpoint, client: "mobile")
            let registration = try JSONDecoder().decode([String: String].self,
                from: await transport.request("registration/mac"))
            try Task.checkCancellation()
            return try await AgentIntegrationConnection.open(endpoint: endpoint, registration: registration,
                expectedFingerprint: fingerprint)
        }
        connectionTask = task
        defer { connectionTask = nil }
        do {
            let next = try await task.value
            guard !finished else { await next.close(); return nil }
            connection = next
            transportError = ""
            return next
        } catch {
            transportError = String(describing: error)
            return nil
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
                left: .leaf(sessionName: configuration.unrelatedPane, title: "Other provider", attentionText: nil,
                    isBusy: false, attentionSource: nil),
                right: .leaf(sessionName: session, title: "Provider",
                    attentionText: inputRequest ? "\(event.runtime) needs input" : nil,
                    isBusy: false, attentionSource: inputRequest ? .agentStop : nil,
                    attentionTimestamp: inputRequest ? event.stoppedAt : nil)),
            origin: .init(deviceID: configuration.host.remoteDeviceID!, deviceLabel: configuration.host.label,
                relayDepth: relayed ? 1 : 0),
            sidebar: .init(id: "fixture:\(event.worktree)", projectID: "notification-project",
                paneIDs: [configuration.unrelatedPane: "unrelated-slot", session: "target-slot"],
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
        let selectedPane = state.selectedHostId.flatMap { hostID in
            state.focusedPaneId.flatMap { retainedPanes.cached(.init(hostID: hostID, sessionName: $0)) }
        }
        let container = selectedPane?.container
        let metrics = container?.terminalGridMetrics
        let visibleFrame = container.flatMap { Self.visibleFrame(of: $0.terminalView) }
        let matchesSelectedClient: Bool
        if let selectedPane, let container,
           case .inMemory(let renderedSession) = container.terminalView.configuration.backend {
            matchesSelectedClient = renderedSession === selectedPane.client.session
        } else {
            matchesSelectedClient = false
        }
        observationSequence += 1
        return ["expectedHost": configuration.host.id.uuidString, "expectedWorktree": event.worktree,
            "expectedPane": event.paneSessionName ?? "", "title": title,
            "unrelatedPane": configuration.unrelatedPane,
            "selectedHost": state.selectedHostId?.uuidString ?? "", "worktree": state.selectedWorktreePath ?? "",
            "pane": state.focusedPaneId ?? "", "pending": String(notifications.pendingRoute != nil),
            "fetchCount": String(fetchCount), "requestCount": String(submitted.count),
            "mode": configuration.mode,
            "responseCount": String(responseIDs.count),
            "responseIDs": String(decoding: try JSONEncoder().encode(responseIDs), as: UTF8.self),
            "responseRoutes": String(decoding: try JSONEncoder().encode(responseRoutes), as: UTF8.self),
            "observedScenePhase": observedScenePhases.last ?? "unobserved",
            "sceneTransitions": String(max(0, observedScenePhases.count - 1)),
            "scenePhases": String(decoding: try JSONEncoder().encode(observedScenePhases), as: UTF8.self),
            "sceneProbeIDs": String(decoding: try JSONEncoder().encode(sceneProbeIDs), as: UTF8.self),
            "session": selectedPane?.sessionName ?? "",
            "live": String(selectedPane?.client.connectionState == .live),
            "mounted": String(visibleFrame != nil && matchesSelectedClient),
            "matchesSelectedClient": String(matchesSelectedClient),
            "visibleFrame": visibleFrame.map(NSStringFromCGRect) ?? "",
            "surfaceReady": String(container?.terminalView.surface != nil),
            "physicalRows": selectedPane?.client.session.readViewportRowsText() ?? "",
            "nativeGrid": metrics.map { "\($0.columns)x\($0.rows)" } ?? "",
            "transportError": transportError,
            "observationSequence": String(observationSequence),
            "observedAt": String(Date().timeIntervalSince1970),
            "requestIDs": String(decoding: try JSONEncoder().encode(submitted), as: UTF8.self)]
    }

    /// A cached renderer can still receive output after navigation detaches it.
    /// Count only the selected backend's visible, unclipped native viewport.
    private static func visibleFrame(of view: UIView) -> CGRect? {
        guard let window = view.window, !window.isHidden, window.alpha > 0.01,
              view.bounds.width > 0, view.bounds.height > 0 else { return nil }
        var frame = view.convert(view.bounds, to: window).intersection(window.bounds)
        var ancestor: UIView? = view
        while let current = ancestor {
            guard !current.isHidden, current.alpha > 0.01 else { return nil }
            if current.clipsToBounds {
                frame = frame.intersection(current.convert(current.bounds, to: window))
            }
            ancestor = current.superview
        }
        guard !frame.isNull, !frame.isInfinite, frame.width > 0, frame.height > 0 else { return nil }
        return frame
    }

    func finish() {
        finished = true
        connectionTask?.cancel()
        retainedPanes.stopAll()
        let previous = connection
        connection = nil
        Task { await previous?.close() }
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
    var body: some View {
        if fixture.configuration.mode == "active-retry" {
            // Keep RootView and its probe continuously active so an OS scene
            // transition cannot retry the failed route on the second tap.
            fixture.root.environment(\.scenePhase, .active)
        } else {
            fixture.root
        }
    }
}

private struct NotificationFixtureScenePhaseProbe: View {
    let fixture: NotificationActivationFixture
    @Environment(\.scenePhase) private var phase
    @State private var instanceID = UUID()
    var body: some View {
        Color.clear
            .allowsHitTesting(false)
            .onAppear { fixture.sceneProbeAppeared(instanceID, phase: phase) }
            .onChange(of: phase) { _, value in fixture.observeScenePhase(value) }
    }
}
#endif
