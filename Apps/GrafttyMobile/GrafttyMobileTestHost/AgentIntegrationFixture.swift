#if GRAFTTY_BROWSER_CONTROL_FIXTURE
import CryptoKit
import CoreImage
import Foundation
import IOSurface
import Observation
import QuickLook
import GhosttyTerminal
import GrafttyProtocol
import GrafttyRemoteClient
import SwiftUI
import UIKit
import WebRTC
@testable import GrafttyMobileKit

struct AgentIntegrationFixture: UIViewControllerRepresentable {
    let endpoint: URL
    func makeUIViewController(context: Context) -> AgentIntegrationMobileController { .init(endpoint: endpoint) }
    func updateUIViewController(_ controller: AgentIntegrationMobileController, context: Context) {}
}

/// Shared by the explicit terminal fixture and notification-selected routes.
/// Credentials are ephemeral harness data; SSH still verifies the pinned host.
enum AgentIntegrationConnection {
    static func fingerprint(_ registration: [String: String]) throws -> RemoteIdentityFingerprint {
        guard let encoded = registration["fingerprint"] else {
            throw AgentIntegrationError("missing ephemeral host fingerprint")
        }
        return try JSONDecoder().decode(RemoteIdentityFingerprint.self, from: Data(encoded.utf8))
    }

    static func open(endpoint: URL, registration: [String: String],
        expectedFingerprint: RemoteIdentityFingerprint) async throws -> RemoteHostConnection {
        guard try fingerprint(registration) == expectedFingerprint,
              let encodedKey = registration["clientKey"], let key = Data(base64Encoded: encodedKey) else {
            throw AgentIntegrationError("ephemeral pairing credentials missing or host fingerprint changed")
        }
        let next = RemoteHostConnection(clientKey: try Curve25519.Signing.PrivateKey(rawRepresentation: key),
            expectedHostFingerprint: expectedFingerprint)
        do {
            let offer = try await next.createOffer()
            let transport = AgentIntegrationTransport(endpoint: endpoint, client: "mobile")
            let data = try await transport.request("rtc/offer", body: JSONEncoder().encode(["sdp": offer.sdp]))
            let answer = try JSONDecoder().decode([String: String].self, from: data)
            guard let sdp = answer["sdp"] else { throw AgentIntegrationError("missing WebRTC answer") }
            try await next.applyAnswer(RTCSessionDescription(type: .answer, sdp: sdp))
            let deadline = ContinuousClock.now.advanced(by: .seconds(20))
            while await next.state != .connected {
                guard ContinuousClock.now < deadline else { throw AgentIntegrationError("SSH-over-WebRTC connection timed out") }
                try await Task.sleep(for: .milliseconds(20))
            }
            try Task.checkCancellation()
            return next
        } catch {
            await next.close()
            throw error
        }
    }
}

@MainActor
final class AgentIntegrationMobileController: UIViewController {
    struct Pane {
        let client: SessionClient
        let container: TerminalInputContainerView
        let usesRoute: Bool
    }
    let endpoint: URL
    let status = UILabel()
    let dismissKeyboard = UIButton(type: .system)
    var connection: RemoteHostConnection?
    var panes: [String: Pane] = [:]
    var focused: String?
    var task: Task<Void, Never>?
    var timer: Timer?
    var registration: [String: String] = [:]
    let fixtureHost = Host(label: "Integration Mac", baseURL: URL(string: "https://fixture.invalid")!)
    let retainedPanes = RetainedPaneClientPool<RetainedMobilePane>()
    var route: UIHostingController<AnyView>?
    var notificationFixture: NotificationActivationFixture?
    var previewFixture: AgentPreviewFixture?
    let focusKeyboardButton = UIButton(type: .system)

    init(endpoint: URL) { self.endpoint = endpoint; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        status.textColor = .white
        status.numberOfLines = 2
        status.font = .monospacedSystemFont(ofSize: 9, weight: .regular)
        status.accessibilityIdentifier = "Agent integration status"
        view.addSubview(status)
        focusKeyboardButton.setTitle("Show keyboard", for: .normal)
        focusKeyboardButton.accessibilityIdentifier = "Agent integration show keyboard"
        focusKeyboardButton.addTarget(self, action: #selector(showKeyboard), for: .touchUpInside)
        view.addSubview(focusKeyboardButton)
        dismissKeyboard.setTitle("Dismiss keyboard", for: .normal)
        dismissKeyboard.accessibilityIdentifier = "Agent integration dismiss keyboard"
        dismissKeyboard.addTarget(self, action: #selector(hideKeyboard), for: .touchUpInside)
        view.addSubview(dismissKeyboard)
        if let restored = NotificationActivationFixture.restored {
            mountNotificationFixture(restored)
        }
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.synchronize() }
        }
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            let transport = AgentIntegrationTransport(endpoint: endpoint, client: "mobile")
            do {
                registration = try JSONDecoder().decode([String: String].self, from: await transport.request("registration/mac"))
                guard let executable = Bundle.main.executableURL else { throw AgentIntegrationError("missing native host executable") }
                let executableHash = SHA256.hash(data: try Data(contentsOf: executable)).map { String(format: "%02x", $0) }.joined()
                try await transport.register(["native": "UIKit", "transport": "SSH-over-WebRTC",
                    "nativeExecutable": executable.path, "nativeExecutableSHA256": executableHash,
                    "systemVersion": UIDevice.current.systemVersion,
                    "simulator": ProcessInfo.processInfo.environment["SIMULATOR_UDID"] ?? ""])
                try await transport.run { [self] in try await handle($0) }
            } catch {
                status.text = String(describing: error)
                status.accessibilityValue = status.text
                _ = try? await transport.request("client-error/mobile", body: JSONEncoder().encode(["error": String(describing: error)]))
            }
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let frame = view.safeAreaLayoutGuide.layoutFrame
        if notificationFixture != nil || previewFixture != nil { route?.view.frame = view.bounds }
        status.frame = CGRect(x: frame.minX, y: frame.minY, width: max(1, frame.width - 260), height: 35)
        focusKeyboardButton.frame = CGRect(x: frame.maxX - 260, y: frame.minY, width: 130, height: 35)
        dismissKeyboard.frame = CGRect(x: frame.maxX - 130, y: frame.minY, width: 130, height: 35)
        if let focused, let pane = panes[focused] {
            if let route {
                route.view.frame = view.bounds
            } else {
                pane.container.frame = CGRect(x: frame.minX, y: status.frame.maxY, width: frame.width,
                    height: max(1, frame.height - 35))
            }
            pane.container.layoutIfNeeded()
        }
    }

    @objc func hideKeyboard() { view.endEditing(true) }
    @objc func showKeyboard() {
        guard let focused, let pane = panes[focused] else { return }
        _ = pane.container.focusKeyboardInput()
    }

    func connect() async throws -> RemoteHostConnection {
        if let connection, await connection.state == .connected { return connection }
        await connection?.close()
        let next = try await AgentIntegrationConnection.open(endpoint: endpoint, registration: registration,
            expectedFingerprint: AgentIntegrationConnection.fingerprint(registration))
        connection = next
        return next
    }

    func handle(_ command: AgentIntegrationCommand) async throws -> [String: String] {
        if command.operation == "previewPrepare" {
            // The preview scenario owns production chrome. Fixture buttons
            // must not remain discoverable beneath its hosting controller.
            for control in [status, focusKeyboardButton, dismissKeyboard] {
                control.isHidden = true
                control.accessibilityElementsHidden = true
            }
            previewFixture?.client.stop()
            unmount()
            focused = nil
            let fixture = try await AgentPreviewFixture.prepare(command, host: fixtureHost,
                connection: connect())
            previewFixture = fixture
            let host = UIHostingController(rootView: AnyView(AgentPreviewFixtureView(fixture: fixture)))
            addChild(host)
            view.addSubview(host.view)
            host.didMove(toParent: self)
            route = host
            host.view.frame = view.bounds
            view.setNeedsLayout()
            view.layoutIfNeeded()
            try await fixture.startMounted(in: host)
            return try await fixture.snapshot(controller: self)
        }
        if command.operation.hasPrefix("preview"), let previewFixture {
            return try await previewFixture.snapshot(controller: self)
        }
        if command.operation == "notificationsPrepare" {
            notificationFixture?.finish()
            let fixture = try await NotificationActivationFixture.prepare(command, endpoint: endpoint,
                fingerprint: AgentIntegrationConnection.fingerprint(registration))
            mountNotificationFixture(fixture)
            return try fixture.snapshot(controller: self)
        }
        if let notificationFixture,
           command.operation.hasPrefix("notifications") || ["snapshot", "scroll", "loadedHistory", "select", "reconnect", "takeControl", "input"].contains(command.operation) {
            return try await notificationFixture.handle(command, controller: self)
        }
        if command.operation == "finish" {
            notificationFixture?.finish()
            previewFixture?.client.stop()
            for pane in panes.values { pane.client.stop() }
            await connection?.close()
            connection = nil
            return [:]
        }
        if command.operation == "connect" {
            let connection = try await connect()
            guard let sessionName = command.parameters["session"] else { throw AgentIntegrationError("missing pane session") }
            let client = SessionClient(sessionName: sessionName, webSocketFactory: {
                try await connection.openTerminalSession(sessionName: sessionName, preferPaged: true)
            })
            let container = TerminalInputContainerView()
            client.additionalHistoryRowCapacity = { [weak container] in
                container?.snapshotScrollView.additionalHistoryRowCapacity ?? 0
            }
            container.onPhysicalViewportReady = { [weak client] in
                client?.physicalViewportDidBecomeReady($0)
            }
            container.terminalView.controller = MobileTerminalControllerFactory.make(configText: "font-size = 12\nscrollback-limit = 10000000")
            container.terminalView.configuration = .init(backend: .inMemory(client.session))
            container.accessibilityIdentifier = "Agent integration terminal"
            let usesRoute = command.parameters["presentation"] == "route"
            if usesRoute {
                let retained = retainedPanes.acquire(.init(hostID: fixtureHost.id, sessionName: sessionName)) {
                    RetainedMobilePane(client: client)
                }
                retained.container = container
            }
            panes[command.provider] = Pane(client: client, container: container, usesRoute: usesRoute)
            focus(command.provider)
            client.start()
            try await waitForOwnership(client)
        } else {
            guard let pane = panes[command.provider] else { throw AgentIntegrationError("mobile pane not connected") }
            if command.parameters["mount"] != "false" { focus(command.provider) }
            switch command.operation {
            case "visibility":
                if command.parameters["visible"] == "false" {
                    unmount()
                    focused = nil
                }
            case "keyboard":
                if command.parameters["visible"] == "true" {
                    guard pane.container.focusKeyboardInput() else { throw AgentIntegrationError("keyboard focus rejected") }
                } else {
                    view.endEditing(true)
                }
            case "takeControl":
                pane.client.takeControl()
                let deadline = ContinuousClock.now.advanced(by: .seconds(10))
                while !pane.client.isOwner {
                    guard ContinuousClock.now < deadline else { throw AgentIntegrationError("mobile takeover timed out") }
                    try await Task.sleep(for: .milliseconds(20))
                }
            case "reconnect":
                pane.client.forceReconnectNow()
                try await waitForOwnership(pane.client)
            case "scroll":
                var action = command.parameters["position"] == "bottom" ? "scroll_to_bottom" : "scroll_to_top"
                if command.parameters["position"] == "middle", let bar = pane.container.snapshotScrollView.scrollbar {
                    action = "scroll_to_row:\((bar.total - min(bar.total, bar.len)) / 2)"
                }
                guard pane.container.terminalView.surface?.performAction(action) == true else { throw AgentIntegrationError("mobile scroll rejected") }
            case "select":
                guard pane.container.terminalView.surface?.performAction("select_all") == true else { throw AgentIntegrationError("mobile selection rejected") }
            case "loadedHistory":
                guard let surface = pane.container.terminalView.surface,
                      surface.performAction("select_all") else { throw AgentIntegrationError("mobile history read rejected") }
                defer { _ = surface.performAction("clear_selection") }
                return ["loadedHistory": surface.readSelection() ?? ""]
            case "input":
                pane.client.sendSoftwareKeyboardText(command.parameters["text"] ?? "")
                pane.client.submitReturn()
            case "snapshot": break
            default: throw AgentIntegrationError("unsupported mobile action \(command.operation)")
            }
        }
        guard let pane = panes[command.provider] else { throw AgentIntegrationError("missing mounted pane") }
        synchronize()
        try await MobilePagedTerminalRenderer(session: pane.client.session, prepareGrid: { _, _ in }).flushOutput()
        var result = snapshot(pane)
        if command.parameters["colors"] == "true",
           let contents = ([pane.container.terminalView.layer] + (pane.container.terminalView.layer.sublayers ?? []))
            .compactMap({ $0.contents }).first(where: { CFGetTypeID($0 as CFTypeRef) == IOSurfaceGetTypeID() }),
           let metrics = pane.container.terminalGridMetrics {
            let surface = unsafeBitCast(contents as AnyObject, to: IOSurfaceRef.self)
            let image = CIImage(ioSurface: surface)
            if let cgImage = CIContext().createCGImage(image, from: image.extent) {
                let pixels = AgentIntegrationColorProbe.counts(image: cgImage,
                    physicalRows: pane.client.session.readViewportRowsText() ?? "",
                    cellHeight: Int(metrics.cellHeightPixels),
                    markerSuffix: command.parameters["colorSuffix"] ?? "")
                result["colorPixels"] = String(decoding: try JSONEncoder().encode(pixels), as: UTF8.self)
            }
        }
        return result
    }

    func mountNotificationFixture(_ fixture: NotificationActivationFixture) {
        unmount()
        notificationFixture = fixture
        let host = UIHostingController(rootView: AnyView(NotificationActivationFixtureView(fixture: fixture)))
        addChild(host)
        view.addSubview(host.view)
        host.didMove(toParent: self)
        route = host
        host.view.frame = view.bounds
    }

    private func parserGridMatches(_ session: InMemoryTerminalSession, columns: UInt16, rows: UInt16) -> String {
        #if GRAFTTY_PAGED_HISTORY
        String(session.gridMatches(columns: columns, rows: rows))
        #else
        // The pinned renderer cannot expose parser-grid diagnostics.
        ""
        #endif
    }

    func focus(_ provider: String) {
        if focused != provider {
            unmount()
            focused = provider
            if let pane = panes[provider] {
                if pane.usesRoute {
                    let terminal = SingleSessionView(step: SessionStep(host: fixtureHost,
                        sessionName: pane.client.sessionName, title: provider),
                        navigationPath: .constant(NavigationPath()), retainedPanes: retainedPanes,
                        initialClient: pane.client, initialController: pane.container.terminalView.controller)
                    let host = UIHostingController(rootView: AnyView(terminal.environment(\.scenePhase, .inactive)))
                    addChild(host)
                    view.addSubview(host.view)
                    host.didMove(toParent: self)
                    route = host
                    view.bringSubviewToFront(status)
                    view.bringSubviewToFront(focusKeyboardButton)
                    view.bringSubviewToFront(dismissKeyboard)
                } else {
                    view.addSubview(pane.container)
                }
            }
        }
        view.setNeedsLayout()
        view.layoutIfNeeded()
        synchronize()
    }

    func unmount() {
        if let route {
            route.willMove(toParent: nil)
            route.view.removeFromSuperview()
            route.removeFromParent()
            self.route = nil
        }
        for pane in panes.values { pane.container.removeFromSuperview() }
    }

    func synchronize() {
        for (provider, pane) in panes {
            if pane.usesRoute { continue }
            pane.container.committedSoftwareInput = SingleSessionView.isTerminalKeyboardEligible(
                clientIsOwner: pane.client.isOwner, isPaneFocused: provider == focused
            ) ? .init(insertText: { [weak client = pane.client] text in
                guard let client, client.isOwner, client.connectionState == .live else { return }
                client.sendSoftwareKeyboardText(text)
            }, insertControlByte: { [weak client = pane.client] in client?.sendControlByte($0) },
               deleteBackward: { [weak client = pane.client] in client?.deleteBackward() }) : nil
            pane.container.authoritativeGrid = pane.client.snapshotCanvasGrid.map { .init(cols: $0.cols, rows: $0.rows) }
            pane.container.snapshotScrollView.showsAdditionalHistory = pane.client.isFollower
            pane.container.setNeedsLayout()
            pane.container.layoutIfNeeded()
        }
        if let focused, let pane = panes[focused],
           let encoded = try? JSONEncoder().encode(snapshot(pane)), let text = String(data: encoded, encoding: .utf8) {
            status.text = text
            status.accessibilityValue = text
        }
    }

    func snapshot(_ pane: Pane) -> [String: String] {
        var text = ""
        let state = pane.client.ownershipSnapshot
        let bar = pane.container.snapshotScrollView.scrollbar
        let scroll = pane.container.snapshotScrollView
        if let metrics = pane.container.terminalGridMetrics {
            let rowHeight = CGFloat(metrics.cellHeightPixels) / pane.container.terminalView.contentScaleFactor
                * pane.container.terminalView.transform.a
            var visible: [String] = []
            if let frame = scroll.additionalHistoryFrameForTesting, let rows = scroll.additionalHistoryRowsForTesting {
                visible.append(AgentIntegrationViewport.visibleRows(rows, frame: frame,
                    viewport: scroll.bounds, rowHeight: rowHeight))
            }
            visible.append(AgentIntegrationViewport.visibleRows(pane.client.session.readViewportRowsText() ?? "",
                frame: pane.container.terminalView.frame, viewport: scroll.bounds, rowHeight: rowHeight))
            text = visible.filter { !$0.isEmpty }.joined(separator: "\n")
        }
        let metrics = pane.container.terminalGridMetrics
        let terminalFrame = pane.container.convert(pane.container.bounds, to: view.window)
        let keyboardFrame = view.convert(view.keyboardLayoutGuide.layoutFrame, to: view.window)
        var values: [String: String] = ["text": text, "anchor": AgentIntegrationAnchor.first(in: text),
            "pagedGridMismatches": pane.client.diagnosticPagedGridMismatches.joined(separator: "\n"),
            "ownerResizeRequests": String(pane.client.diagnosticOwnerResizeRequests),
            "parserGridMatches": metrics.map { parserGridMatches(pane.client.session, columns: $0.columns, rows: $0.rows) } ?? "",
            "parserGridAtScrollbarHeight": metrics.map { parserGridMatches(pane.client.session, columns: $0.columns, rows: UInt16(clamping: bar?.len ?? 0)) } ?? "",
            "physicalRows": pane.client.session.readViewportRowsText() ?? "",
            "surfaceFrame": NSCoder.string(for: pane.container.terminalView.frame),
            "surfaceBounds": NSCoder.string(for: pane.container.terminalView.bounds),
            "canvasGrid": pane.client.snapshotCanvasGrid.map { "\($0.cols)x\($0.rows)" } ?? "physical",
            "presentationGrid": pane.container.authoritativeGrid.map { "\($0.cols)x\($0.rows)" } ?? "physical",
            "keyboard": String(pane.container.terminalView.isFirstResponder),
            "keyboardEligible": String(pane.container.terminalView.isKeyboardInputEnabled),
            "terminalBottom": String(Double(terminalFrame.maxY)),
            "keyboardTop": String(Double(keyboardFrame.minY)),
            "windowHeight": String(Double(view.window?.bounds.height ?? 0)),
            "selected": pane.container.terminalView.surface?.readSelection() ?? "",
            "revision": String(state?.revision ?? 0), "epoch": String(state?.epoch ?? 0),
            "owner": state?.ownerClientID?.rawValue ?? "", "isOwner": String(pane.client.isOwner),
            "ownerIdentity": state?.ownerIdentity ?? "",
            "grid": state.map { "\($0.grid.cols)x\($0.grid.rows)" } ?? "",
            "nativeGrid": metrics.map { "\($0.columns)x\($0.rows)" } ?? "",
            "historyOffset": String(Double(scroll.contentOffset.y)),
            "offset": String(bar?.offset ?? 0), "total": String(bar?.total ?? 0), "len": String(bar?.len ?? 0),
            "width": String(Int(pane.container.bounds.width)), "height": String(Int(pane.container.bounds.height)),
            "session": pane.client.sessionName, "paging": pane.client.paging.map { String(describing: $0.status) } ?? "inactive"]
        #if DEBUG
        if let diagnostic = pane.client.paging?.historyDiagnosticsForTesting {
            values["historyGeneration"] = String(diagnostic.generation)
            values["issuedHistoryRequests"] = String(diagnostic.requests)
            values["importedHistoryPages"] = String(diagnostic.imports)
        }
        #endif
        return values
    }

    func waitForOwnership(_ client: SessionClient) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(15))
        while client.ownershipSnapshot == nil {
            guard ContinuousClock.now < deadline else { throw AgentIntegrationError("mobile ownership handshake timed out") }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    deinit { task?.cancel(); timer?.invalidate() }
}
// This fixture changes only host resource I/O and authentication. The route,
// terminal representable, resource button, download and Quick Look are production.
actor PreviewChannelProbe {
    private var opens = 0
    private var channelID = ""
    private var closes = 0
    func opened(_ identity: String) {
        opens += 1
        channelID = identity
    }
    func closed() { closes += 1 }
    func snapshot() -> [String: String] { ["channelOpens": String(opens), "channelID": channelID, "channelCloses": String(closes)] }
}

/// Forward every protocol operation to the actual SSH channel. This records
/// close invocations without substituting a mock transport or parser.
private final class PreviewObservedChannel: WebSocketClient {
    let channel: any WebSocketClient
    let probe: PreviewChannelProbe
    init(channel: any WebSocketClient, probe: PreviewChannelProbe) { self.channel = channel; self.probe = probe }
    var supportsWebControlTextFrames: Bool { channel.supportsWebControlTextFrames }
    var supportsPagedHistory: Bool { channel.supportsPagedHistory }
    func send(_ frame: WebSocketFrame) async throws { try await channel.send(frame) }
    func receive() async throws -> WebSocketFrame { try await channel.receive() }
    func close() { channel.close(); Task { await probe.closed() } }
    func resize(cols: Int, rows: Int) async { await channel.resize(cols: cols, rows: rows) }
    func sendHello(clientID: DisplayClientID, kind: DisplayClientKind, role: DisplayClientRole,
                   visible: Bool, cols: Int, rows: Int) async {
        await channel.sendHello(clientID: clientID, kind: kind, role: role, visible: visible, cols: cols, rows: rows)
    }
    func takeControl(clientID: DisplayClientID, kind: DisplayClientKind, cols: Int, rows: Int) async {
        await channel.takeControl(clientID: clientID, kind: kind, cols: cols, rows: rows)
    }
    func ownerResize(clientID: DisplayClientID, epoch: UInt64, cols: Int, rows: Int) async {
        await channel.ownerResize(clientID: clientID, epoch: epoch, cols: cols, rows: rows)
    }
    func ownerResize(clientID: DisplayClientID, epoch: UInt64, cols: Int, rows: Int, pixels: TerminalPixelSize) async {
        await channel.ownerResize(clientID: clientID, epoch: epoch, cols: cols, rows: rows, pixels: pixels)
    }
}

@MainActor @Observable
final class AgentPreviewFixture {
    let client: SessionClient
    let host: Host
    let worktree: String
    let embedded: Bool
    let pool: RetainedPaneClientPool<RetainedMobilePane>?
    let controller = MobileTerminalControllerFactory.make(configText: "font-size = 12\nscrollback-limit = 10000000")
    let gate = BiometricGate(authenticator: NotificationActivationFixture.FixtureAuthenticator())
    let coordinator: RemoteConnectionCoordinator
    let channel: PreviewChannelProbe
    let navigationID = UUID()
    var path: [UUID] = []
    var reads = 0
    var container: TerminalInputContainerView?
    let offer: RemoteOpenOffer
    let image: Data

    init(client: SessionClient, host: Host, worktree: String, retained: Bool, embedded: Bool,
         channel: PreviewChannelProbe) {
        self.client = client
        self.host = host
        self.worktree = worktree
        self.embedded = embedded
        self.channel = channel
        pool = retained ? RetainedPaneClientPool<RetainedMobilePane>() : nil
        let deviceID = RemoteDeviceID(value: "integration-phone")
        coordinator = RemoteConnectionCoordinator(authenticatedDeviceID: deviceID, directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("preview-coordinator-\(UUID())"))
        image = UIGraphicsImageRenderer(size: CGSize(width: 480, height: 360)).pngData { context in
            UIColor.systemBlue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 480, height: 360))
            ("Quick Look terminal continuity" as NSString).draw(at: CGPoint(x: 24, y: 140),
                withAttributes: [.font: UIFont.boldSystemFont(ofSize: 24), .foregroundColor: UIColor.white])
        }
        offer = RemoteOpenOffer(id: UUID(), filename: "terminal-continuity.png", byteCount: image.count,
            paneSessionName: client.sessionName, previewKind: "image", previewOwnerDeviceID: deviceID)
        path = [navigationID]
        coordinator.completePreviewAutoOpen(offer.id)
        if let pool {
            _ = pool.acquire(.init(hostID: host.id, sessionName: client.sessionName)) { RetainedMobilePane(client: client) }
        }
    }

    static func prepare(_ command: AgentIntegrationCommand, host: Host,
                        connection: RemoteHostConnection) async throws -> AgentPreviewFixture {
        guard let session = command.parameters["session"], let worktree = command.parameters["worktree"] else {
            throw AgentIntegrationError("missing preview session/worktree")
        }
        let probe = PreviewChannelProbe()
        let client = SessionClient(sessionName: session, webSocketFactory: {
            let channel = try await connection.openTerminalSession(sessionName: session, preferPaged: true)
            await probe.opened(String(describing: ObjectIdentifier(channel)))
            return PreviewObservedChannel(channel: channel, probe: probe)
        })
        let fixture = AgentPreviewFixture(client: client, host: host, worktree: worktree,
            retained: command.parameters["retained"] == "true", embedded: command.parameters["embedded"] == "true",
            channel: probe)
        fixture.gate.applicationWillEnterForeground()
        await fixture.gate.authenticate()
        return fixture
    }

    func startMounted(in host: UIViewController) async throws {
        let mountDeadline = ContinuousClock.now.advanced(by: .seconds(15))
        while terminal(in: host.view)?.terminalView.surface == nil || terminal(in: host.view)?.terminalGridMetrics == nil {
            guard ContinuousClock.now < mountDeadline else { throw AgentIntegrationError("preview source renderer did not mount") }
            try await Task.sleep(for: .milliseconds(20))
        }
        // The production TerminalPaneView supplies onPhysicalViewportReady.
        // Mount before starting the real SSH attachment so its first hello and
        // source grid use that viewport; never inject or bypass the callback.
        client.start()
        let deadline = ContinuousClock.now.advanced(by: .seconds(15))
        while client.ownershipSnapshot == nil {
            guard ContinuousClock.now < deadline else { throw AgentIntegrationError("preview pane handshake timed out") }
            try await Task.sleep(for: .milliseconds(20))
        }
        client.takeControl()
        while !client.isOwner {
            guard ContinuousClock.now < deadline else { throw AgentIntegrationError("preview pane ownership timed out") }
            try await Task.sleep(for: .milliseconds(20))
        }
        guard client.ownershipSnapshot?.ownerIdentity == "ssh-device:integration-phone" else {
            throw AgentIntegrationError("preview offer identity differs from authenticated SSH owner")
        }
        let controlsDeadline = ContinuousClock.now.advanced(by: .seconds(15))
        while true {
            if let container = terminal(in: host.view), container.window != nil,
               container.controlAttachmentID != nil, container.committedSoftwareInput != nil,
               container.terminalView.isKeyboardInputEnabled { break }
            guard ContinuousClock.now < controlsDeadline else {
                throw AgentIntegrationError("preview production input controls did not become ready")
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        // The runner checks source/native/parser convergence after genuine
        // provider input and keyboard dismissal, before opening Quick Look.
        // Ownership alone can precede the zmx leader applying its stored size.
    }

    func management(_ request: WorktreeManagementRequest, host: Host) async throws -> WorktreeManagementResponse {
        if case .openResource(_, .read(let id, let offset)) = request {
            guard id == offer.id, offset >= 0, offset <= image.count else {
                throw AgentIntegrationError("preview request has wrong resource identity or offset")
            }
            reads += 1
            return .openResource(.chunk(image.subdata(in: offset..<image.count)))
        }
        return .openResource(.offers([offer]))
    }

    private func terminal(in view: UIView) -> TerminalInputContainerView? {
        if let terminal = view as? TerminalInputContainerView { return terminal }
        return view.subviews.lazy.compactMap { self.terminal(in: $0) }.first
    }

    private func quickLook(in controller: UIViewController) -> QLPreviewController? {
        if let preview = controller as? QLPreviewController { return preview }
        if let presented = controller.presentedViewController, let preview = quickLook(in: presented) { return preview }
        return controller.children.lazy.compactMap { self.quickLook(in: $0) }.first
    }

    func snapshot(controller host: AgentIntegrationMobileController) async throws -> [String: String] {
        // Snapshot commands may arrive before SwiftUI finishes the route push.
        let deadline = ContinuousClock.now.advanced(by: .seconds(15))
        while !path.isEmpty, terminal(in: host.view) == nil {
            guard ContinuousClock.now < deadline else { throw AgentIntegrationError("production preview terminal did not mount") }
            try await Task.sleep(for: .milliseconds(20))
        }
        if let current = terminal(in: host.view) { container = current }
        guard let container else { throw AgentIntegrationError("preview terminal container unavailable") }
        container.accessibilityIdentifier = "Agent integration terminal"
        if !path.isEmpty {
            try await MobilePagedTerminalRenderer(session: client.session, prepareGrid: { _, _ in }).flushOutput()
        } else {
            // The production attachment observer defers teardown one actor turn.
            try await Task.sleep(for: .milliseconds(250))
        }
        var values = host.snapshot(.init(client: client, container: container, usesRoute: true))
        values.merge(await channel.snapshot()) { _, new in new }
        values["clientID"] = String(describing: ObjectIdentifier(client))
        values["containerID"] = String(describing: ObjectIdentifier(container))
        values["surfaceID"] = container.terminalView.surface.map { String(describing: ObjectIdentifier($0)) } ?? ""
        values["attachmentID"] = container.controlAttachmentID?.uuidString ?? ""
        values["navigationID"] = path.last?.uuidString ?? ""
        values["navigationRemoved"] = String(path.isEmpty)
        values["terminalMounted"] = String(container.window != nil)
        values["terminalContained"] = String(host.route.map { container.isDescendant(of: $0.view) } ?? false)
        values["sourceControllerAttached"] = String(host.route?.parent === host)
        values["connection"] = String(describing: client.connectionState)
        values["quickLook"] = String(quickLook(in: host) != nil)
        values["previewReads"] = String(reads)
        values["previewOwnerIdentity"] = offer.previewOwnerDeviceID.map { "ssh-device:\($0.value)" } ?? ""
        values["controlsDetached"] = String(container.controlAttachmentID == nil && container.committedSoftwareInput == nil)
        values["pendingOutputBytes"] = String(client.session.pendingOutputByteCount)
        values["browserDetached"] = String(container.linkContext == nil && container.onBackRequested == nil)
        values["ownershipCleared"] = String(client.ownershipSnapshot == nil)
        if let surface = container.terminalView.surface, surface.performAction("select_all") {
            values["loadedHistory"] = surface.readSelection() ?? ""
            _ = surface.performAction("clear_selection")
        }
        return values
    }
}

private struct AgentPreviewFixtureView: View {
    @Bindable var fixture: AgentPreviewFixture
    var body: some View {
        NavigationStack(path: $fixture.path) {
            Text("Preview worktrees").accessibilityIdentifier("Preview worktrees")
                .navigationTitle("Preview worktrees")
                .navigationDestination(for: UUID.self) { _ in
                    SingleSessionView(step: SessionStep(host: fixture.host, worktreePath: fixture.worktree,
                        sessionName: fixture.client.sessionName, title: "Preview terminal"), navigationPath: .constant(NavigationPath()),
                        isFullScreen: !fixture.embedded, showsProjectRail: false, coordinator: fixture.coordinator,
                        isEmbeddedPane: fixture.embedded, onBackToWorktrees: { fixture.path.removeAll() },
                        retainedPanes: fixture.pool, initialClient: fixture.client, initialController: fixture.controller,
                        previewManagementTransport: fixture.management)
                }
        }
        .environment(\.biometricGate, fixture.gate)
        .environment(\.scenePhase, .active)
    }
}
#endif
