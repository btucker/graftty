#if canImport(UIKit)
import GhosttyTerminal
import GrafttyProtocol
import SwiftUI

public struct RootView: View {

    @State private var hostStore = HostStore()
    @State private var gate = BiometricGate()
    @State private var navigationPath: [HostStep] = []
    @State private var activeController: HostController?
    @State private var sessionClients: [UUID: SessionClient] = [:]
    @State private var activePaneID: UUID?
    @Environment(\.scenePhase) private var scenePhase

    public init() {}

    public var body: some View {
        ZStack {
            NavigationStack(path: $navigationPath) {
                HostPickerView(store: hostStore)
                    .navigationDestination(for: Host.self) { host in
                        hostDetail(for: host)
                    }
                    .navigationDestination(for: HostStep.self) { step in
                        switch step {
                        case let .paneGrid(host):
                            paneDetail(for: host)
                        }
                    }
            }
            if gate.state == .locked {
                lockOverlay
            }
        }
        .task { await gate.authenticate() }
        .onChange(of: scenePhase) { _, newPhase in
            switch newPhase {
            case .background:
                gate.applicationDidEnterBackground()
                activeController?.tearDownForBackground()
                for c in sessionClients.values { c.stop() }
                sessionClients.removeAll()
            case .active:
                gate.applicationWillEnterForeground()
                if gate.state == .locked {
                    Task { await gate.authenticate() }
                } else if let controller = activeController {
                    Task { await resumeSessions(on: controller) }
                }
            default:
                break
            }
        }
    }

    /// Second-level views on the stack. Host is the first destination;
    /// `.paneGrid` is the deeper destination after tapping a session.
    private enum HostStep: Hashable {
        case paneGrid(Host)
    }

    @ViewBuilder
    private func hostDetail(for host: Host) -> some View {
        let controller = ensureController(for: host)
        SessionPickerView(controller: controller) { info in
            openPane(sessionName: info.name, on: controller)
            navigationPath.append(HostStep.paneGrid(host))
        }
    }

    @ViewBuilder
    private func paneDetail(for host: Host) -> some View {
        if let controller = activeController, controller.host.id == host.id {
            VStack(spacing: 0) {
                SplitContainerView(panes: controller.panes) { id in
                    sessionClients[id]?.session
                }
                SessionSwitcherView(
                    controller: controller,
                    activePaneID: $activePaneID
                )
            }
            .navigationTitle(host.label)
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button("Close") {
                        closeAllPanes(on: controller)
                        if !navigationPath.isEmpty { navigationPath.removeLast() }
                    }
                }
            }
        } else {
            ContentUnavailableView("Session ended", systemImage: "xmark.circle")
        }
    }

    private var lockOverlay: some View {
        VStack(spacing: 16) {
            Image(systemName: "lock.shield").font(.system(size: 64))
            Text("Graftty is locked").font(.title2)
            Button("Unlock") { Task { await gate.authenticate() } }
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.regularMaterial)
    }

    @MainActor
    private func ensureController(for host: Host) -> HostController {
        if let existing = activeController, existing.host.id == host.id {
            return existing
        }
        let ctl = HostController(
            host: host,
            fetcher: { [host] in
                (try? await SessionsFetcher.fetch(baseURL: host.baseURL)) ?? []
            }
        )
        activeController = ctl
        return ctl
    }

    @MainActor
    private func openPane(sessionName: String, on ctl: HostController) {
        let wsURL = Self.makeWebSocketURL(base: ctl.host.baseURL, session: sessionName)
        let ws = URLSessionWebSocketClient(url: wsURL)
        let client = SessionClient(sessionName: sessionName, webSocket: ws)
        client.start()
        ctl.openPane(sessionName: sessionName)
        if let pane = ctl.panes.last {
            sessionClients[pane.id] = client
            activePaneID = pane.id
        }
    }

    @MainActor
    private func closeAllPanes(on ctl: HostController) {
        for client in sessionClients.values { client.stop() }
        sessionClients.removeAll()
        for pane in ctl.panes { ctl.closePane(pane.id) }
        activePaneID = nil
    }

    @MainActor
    private func resumeSessions(on ctl: HostController) async {
        let fresh = (try? await SessionsFetcher.fetch(baseURL: ctl.host.baseURL)) ?? []
        await ctl.resumeForForeground(currentSessions: fresh)
        sessionClients.removeAll()
        for pane in ctl.panes {
            let wsURL = Self.makeWebSocketURL(base: ctl.host.baseURL, session: pane.sessionName)
            let ws = URLSessionWebSocketClient(url: wsURL)
            let client = SessionClient(sessionName: pane.sessionName, webSocket: ws)
            client.start()
            sessionClients[pane.id] = client
        }
    }

    static func makeWebSocketURL(base: URL, session: String) -> URL {
        var components = URLComponents(url: base, resolvingAgainstBaseURL: false) ?? URLComponents()
        components.scheme = (base.scheme?.lowercased() == "https") ? "wss" : "ws"
        components.path = "/ws"
        components.queryItems = [URLQueryItem(name: "session", value: session)]
        return components.url ?? base
    }
}
#endif
