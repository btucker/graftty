#if canImport(UIKit)
import GhosttyTerminal
import GrafttyProtocol
import SwiftUI

public struct RootView: View {

    @State private var hostStore = HostStore()
    @State private var gate = BiometricGate()
    @State private var activeController: HostController?
    @State private var sessionClients: [UUID: SessionClient] = [:]
    @State private var activePaneID: UUID?
    @Environment(\.scenePhase) private var scenePhase

    public init() {}

    public var body: some View {
        ZStack {
            NavigationSplitView {
                HostPickerView(store: hostStore) { host in
                    Task { await openHost(host) }
                }
            } detail: {
                detail
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

    @ViewBuilder
    private var detail: some View {
        if let controller = activeController {
            if controller.panes.isEmpty {
                SessionPickerView(controller: controller) { info in
                    openPane(sessionName: info.name, on: controller)
                }
            } else {
                VStack(spacing: 0) {
                    SplitContainerView(panes: controller.panes) { id in
                        sessionClients[id]?.session
                    }
                    SessionSwitcherView(
                        controller: controller,
                        activePaneID: $activePaneID
                    )
                }
                .toolbar {
                    ToolbarItemGroup(placement: .topBarTrailing) {
                        Button("Back to sessions") {
                            closeAllPanes(on: controller)
                        }
                    }
                }
            }
        } else {
            ContentUnavailableView("Pick a host", systemImage: "terminal")
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
    private func openHost(_ host: Host) async {
        let ctl = HostController(
            host: host,
            fetcher: { [host] in
                (try? await SessionsFetcher.fetch(baseURL: host.baseURL)) ?? []
            },
            makeClient: { [host] name in
                let wsURL = Self.makeWebSocketURL(base: host.baseURL, session: name)
                let ws = URLSessionWebSocketClient(url: wsURL)
                return SessionClient(sessionName: name, webSocket: ws)
            }
        )
        activeController = ctl
        await ctl.refreshSessions()
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
        // Rebuild SessionClients for surviving panes.
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
