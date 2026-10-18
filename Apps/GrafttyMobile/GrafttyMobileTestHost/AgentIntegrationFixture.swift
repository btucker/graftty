#if GRAFTTY_BROWSER_CONTROL_FIXTURE
import CryptoKit
import CoreImage
import Foundation
import IOSurface
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
                try await transport.register(["native": "UIKit", "transport": "SSH-over-WebRTC"])
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
        if notificationFixture != nil { route?.view.frame = view.bounds }
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
        if let connection { return connection }
        guard let encoded = registration["fingerprint"], let encodedKey = registration["clientKey"],
              let key = Data(base64Encoded: encodedKey) else { throw AgentIntegrationError("missing ephemeral pairing credentials") }
        let fingerprint = try JSONDecoder().decode(RemoteIdentityFingerprint.self, from: Data(encoded.utf8))
        let next = RemoteHostConnection(clientKey: try Curve25519.Signing.PrivateKey(rawRepresentation: key),
            expectedHostFingerprint: fingerprint)
        let offer = try await next.createOffer()
        let transport = AgentIntegrationTransport(endpoint: endpoint, client: "mobile")
        let data = try await transport.request("rtc/offer", body: JSONEncoder().encode(["sdp": offer.sdp]))
        let answer = try JSONDecoder().decode([String: String].self, from: data)
        guard let sdp = answer["sdp"] else { throw AgentIntegrationError("missing WebRTC answer") }
        try await next.applyAnswer(RTCSessionDescription(type: .answer, sdp: sdp))
        let deadline = ContinuousClock.now.advanced(by: .seconds(20))
        while await next.state != .connected {
            guard ContinuousClock.now < deadline else { await next.close(); throw AgentIntegrationError("SSH-over-WebRTC connection timed out") }
            try await Task.sleep(for: .milliseconds(20))
        }
        connection = next
        return next
    }

    func handle(_ command: AgentIntegrationCommand) async throws -> [String: String] {
        if command.operation == "notificationsPrepare" {
            notificationFixture?.finish()
            let fixture = try await NotificationActivationFixture.prepare(command, endpoint: endpoint)
            mountNotificationFixture(fixture)
            return try fixture.snapshot()
        }
        if command.operation.hasPrefix("notifications"), let notificationFixture {
            return try await notificationFixture.handle(command)
        }
        if command.operation == "finish" {
            notificationFixture?.finish()
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
        return ["text": text, "anchor": AgentIntegrationAnchor.first(in: text),
            "pagedGridMismatches": pane.client.diagnosticPagedGridMismatches.joined(separator: "\n"),
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
#endif
