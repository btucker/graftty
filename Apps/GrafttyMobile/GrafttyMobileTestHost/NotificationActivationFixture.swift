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
    private var presentationCallbacks: [[String: String]] = []
    private var observedScenePhases: [String] = []
    private var observedSystemScenePhases: [String] = []
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
            guard ["warm", "background", "cold"].contains(configuration.mode) else { return request }
            // Let XCUITest wait for the real foreground banner, or leave the
            // app for a background/cold tap, before the original request fires.
            // Warm entry keeps the retained transport live. Only delivery
            // timing changes; content, delegate receipt and RootView stay real.
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
        notifications.didReceivePresentationRequest = { [weak self] identifier, options in
            self?.presentationCallbacks.append(["identifier": identifier, "options": String(options),
                "observedAt": String(Date().timeIntervalSince1970)])
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
        let value = Self.name(for: phase)
        if observedScenePhases.last != value { observedScenePhases.append(value) }
    }

    func observeSystemScenePhase(_ phase: ScenePhase) {
        let value = Self.name(for: phase)
        if observedSystemScenePhases.last != value { observedSystemScenePhases.append(value) }
    }

    private static func name(for phase: ScenePhase) -> String {
        switch phase {
        case .active: return "active"
        case .inactive: return "inactive"
        case .background: return "background"
        @unknown default: return "unknown"
        }
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

    func handle(_ command: AgentIntegrationCommand, controller: AgentIntegrationMobileController) async throws -> [String: String] {
        let aliases = ["snapshot": "notificationsState", "scroll": "notificationsScroll",
            "loadedHistory": "notificationsLoadedHistory", "select": "notificationsLoadedHistory",
            "reconnect": "notificationsReconnect", "takeControl": "notificationsTakeControl", "input": "notificationsInput"]
        let operation = aliases[command.operation] ?? command.operation
        switch operation {
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
        case "notificationsScroll", "notificationsLoadedHistory", "notificationsReconnect", "notificationsTakeControl", "notificationsInput":
            guard let hostID = state.selectedHostId, let session = state.focusedPaneId,
                  let pane = retainedPanes.cached(.init(hostID: hostID, sessionName: session)),
                  let container = pane.container, let surface = container.terminalView.surface else {
                throw AgentIntegrationError("selected notification terminal missing")
            }
            if operation == "notificationsReconnect" { pane.client.forceReconnectNow() }
            else if operation == "notificationsTakeControl" { pane.client.takeControl() }
            else if operation == "notificationsInput" {
                pane.client.sendSoftwareKeyboardText(command.parameters["text"] ?? "")
                pane.client.submitReturn()
            } else if operation == "notificationsScroll" {
                if let encoded = command.parameters["wheelY"], let delta = Double(encoded) {
                    surface.sendMousePos(x: container.terminalView.bounds.midX, y: container.terminalView.bounds.midY)
                    surface.sendMouseScroll(x: 0, y: delta)
                } else {
                    let action = command.parameters["position"] == "bottom" ? "scroll_to_bottom" : "scroll_to_top"
                    guard surface.performAction(action) else { throw AgentIntegrationError("notification scroll rejected") }
                }
            } else {
                guard surface.performAction("select_all") else { throw AgentIntegrationError("notification history read rejected") }
                defer { _ = surface.performAction("clear_selection") }
                return ["loadedHistory": surface.readSelection() ?? "", "selected": surface.readSelection() ?? ""]
            }
        case "notificationsState": break
        default: throw AgentIntegrationError("unsupported notification fixture command \(command.operation)")
        }
        var result = try snapshot(controller: controller)
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        result["authorization"] = String(describing: settings.authorizationStatus)
        result["alertSetting"] = String(settings.alertSetting.rawValue)
        result["notificationCenterSetting"] = String(settings.notificationCenterSetting.rawValue)
        result["alertStyle"] = String(settings.alertStyle.rawValue)
        result["delegateMatchesFixture"] = String(center.delegate === notifications)
        let pending = await center.pendingNotificationRequests().map { request in
            ["identifier": request.identifier, "title": request.content.title]
        }
        let delivered = await center.deliveredNotifications().map { notification in
            ["identifier": notification.request.identifier, "title": notification.request.content.title,
             "deliveredAt": String(notification.date.timeIntervalSince1970)]
        }
        result["pendingRequests"] = String(decoding: try JSONEncoder().encode(pending), as: UTF8.self)
        result["deliveredRequests"] = String(decoding: try JSONEncoder().encode(delivered), as: UTF8.self)
        result["presentationCallbacks"] = String(decoding: try JSONEncoder().encode(presentationCallbacks), as: UTF8.self)
        result["notificationStateObservedAt"] = String(Date().timeIntervalSince1970)
        return result
    }

    func snapshot(controller: AgentIntegrationMobileController) throws -> [String: String] {
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
        container?.accessibilityIdentifier = "Agent integration terminal"
        let bar = container?.snapshotScrollView.scrollbar
        var diagnostics = selectedPane.flatMap { pane in
            container.map { controller.snapshot(.init(client: pane.client, container: $0, usesRoute: true)) }
        } ?? [:]
        let pagingDiagnostics: [String: String] = [
            "paging": selectedPane?.client.paging.map { String(describing: $0.status) } ?? "inactive",
            "offset": String(bar?.offset ?? 0), "total": String(bar?.total ?? 0), "len": String(bar?.len ?? 0),
            "isOwner": String(selectedPane?.client.isOwner ?? false),
            "isMouseCaptured": String(container?.terminalView.surface?.isMouseCaptured ?? false),
            "clientID": selectedPane.map { String(describing: ObjectIdentifier($0.client)) } ?? "",
            "canvasGrid": selectedPane?.client.snapshotCanvasGrid.map { "\($0.cols)x\($0.rows)" } ?? "physical"]
        diagnostics.merge(pagingDiagnostics) { _, new in new }
        #if DEBUG
        if let value = selectedPane?.client.paging?.historyDiagnosticsForTesting {
            diagnostics["historyGeneration"] = String(value.generation)
            diagnostics["issuedHistoryRequests"] = String(value.requests)
            diagnostics["importedHistoryPages"] = String(value.imports)
        }
        #endif
        let routeDiagnostics: [String: String] = ["expectedHost": configuration.host.id.uuidString, "expectedWorktree": event.worktree,
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
            "systemScenePhase": observedSystemScenePhases.last ?? "unobserved",
            "systemScenePhases": String(decoding: try JSONEncoder().encode(observedSystemScenePhases), as: UTF8.self),
            "sceneProbeIDs": String(decoding: try JSONEncoder().encode(sceneProbeIDs), as: UTF8.self),
            "session": selectedPane?.sessionName ?? "",
            "live": String(selectedPane?.client.connectionState == .live),
            "mounted": String(visibleFrame != nil && matchesSelectedClient),
            "matchesSelectedClient": String(matchesSelectedClient),
            "visibleFrame": visibleFrame.map { NSCoder.string(for: $0) } ?? "",
            "surfaceReady": String(container?.terminalView.surface != nil),
            "physicalRows": selectedPane?.client.session.readViewportRowsText() ?? "",
            "nativeGrid": metrics.map { "\($0.columns)x\($0.rows)" } ?? "",
            "transportError": transportError,
            "observationSequence": String(observationSequence),
            "observedAt": String(Date().timeIntervalSince1970),
            "requestIDs": String(decoding: try JSONEncoder().encode(submitted), as: UTF8.self)]
        diagnostics.merge(routeDiagnostics) { _, new in new }
        return diagnostics
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
    @Environment(\.scenePhase) private var systemScenePhase
    var body: some View {
        Group {
            if fixture.configuration.mode == "active-retry" {
                // Control only RootView's effective phase. The outer probe
                // records the independent OS lifecycle during physical taps.
                fixture.root.environment(\.scenePhase, .active)
            } else {
                fixture.root
            }
        }
        .onAppear { fixture.observeSystemScenePhase(systemScenePhase) }
        .onChange(of: systemScenePhase) { _, phase in fixture.observeSystemScenePhase(phase) }
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
