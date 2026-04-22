#if canImport(UIKit)
import GhosttyTerminal
import GrafttyProtocol
import SwiftUI

public struct RootView: View {

    @State private var hostStore = HostStore()
    @State private var gate = BiometricGate()
    @State private var navigationPath = NavigationPath()
    @Environment(\.scenePhase) private var scenePhase

    public init() {}

    public var body: some View {
        ZStack {
            NavigationStack(path: $navigationPath) {
                HostPickerView(store: hostStore)
                    .navigationDestination(for: Host.self) { host in
                        HostDetailView(host: host, navigationPath: $navigationPath)
                    }
                    .navigationDestination(for: PaneStep.self) { step in
                        PaneGridView(step: step, navigationPath: $navigationPath)
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
            case .active:
                gate.applicationWillEnterForeground()
                if gate.state == .locked {
                    Task { await gate.authenticate() }
                }
            default:
                break
            }
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
}

/// Identifies the "you opened one of these sessions as a pane" navigation
/// level. Carries both the host and the initial session so `PaneGridView`
/// can open it without re-asking the picker.
struct PaneStep: Hashable {
    let host: Host
    let initialSession: String
}

/// Owns a HostController + session clients scoped to a single host. When
/// SwiftUI pushes this destination, it is created fresh; when the user
/// pops it (or navigates to a different host), it is deallocated and its
/// clients stop. That lifecycle replaces the old "single activeController
/// at the RootView level" which caused render-time state mutation and an
/// infinite re-render loop when tapping a host.
struct HostDetailView: View {
    let host: Host
    @Binding var navigationPath: NavigationPath
    @State private var controller: HostController

    init(host: Host, navigationPath: Binding<NavigationPath>) {
        self.host = host
        self._navigationPath = navigationPath
        self._controller = State(initialValue: HostController(
            host: host,
            fetcher: { [host] in
                (try? await SessionsFetcher.fetch(baseURL: host.baseURL)) ?? []
            }
        ))
    }

    var body: some View {
        SessionPickerView(controller: controller) { info in
            navigationPath.append(PaneStep(host: host, initialSession: info.name))
        }
    }
}

/// Owns the pane grid for one (host, initialSession). Pane clients are
/// created as panes open and torn down when this view goes away.
struct PaneGridView: View {
    let step: PaneStep
    @Binding var navigationPath: NavigationPath

    @State private var controller: HostController
    @State private var sessionClients: [UUID: SessionClient] = [:]
    @State private var activePaneID: UUID?

    init(step: PaneStep, navigationPath: Binding<NavigationPath>) {
        self.step = step
        self._navigationPath = navigationPath
        self._controller = State(initialValue: HostController(
            host: step.host,
            fetcher: { [host = step.host] in
                (try? await SessionsFetcher.fetch(baseURL: host.baseURL)) ?? []
            }
        ))
    }

    var body: some View {
        VStack(spacing: 0) {
            SplitContainerView(panes: controller.panes) { id in
                sessionClients[id]?.session
            }
            SessionSwitcherView(controller: controller, activePaneID: $activePaneID)
        }
        .navigationTitle(step.host.label)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button("Close") { navigationPath.removeLast() }
            }
        }
        .task {
            // Opening the initial pane on `.task` rather than `init` so the
            // SessionClient's start() and its spawned Task run after the
            // view is actually on screen.
            guard controller.panes.isEmpty else { return }
            openPane(sessionName: step.initialSession)
        }
        .onDisappear {
            for c in sessionClients.values { c.stop() }
            sessionClients.removeAll()
        }
    }

    @MainActor
    private func openPane(sessionName: String) {
        let wsURL = RootView.makeWebSocketURL(base: step.host.baseURL, session: sessionName)
        let ws = URLSessionWebSocketClient(url: wsURL)
        let client = SessionClient(sessionName: sessionName, webSocket: ws)
        client.start()
        let pane = controller.openPane(sessionName: sessionName)
        sessionClients[pane.id] = client
        activePaneID = pane.id
    }
}

extension RootView {
    static func makeWebSocketURL(base: URL, session: String) -> URL {
        var components = URLComponents(url: base, resolvingAgainstBaseURL: false) ?? URLComponents()
        components.scheme = (base.scheme?.lowercased() == "https") ? "wss" : "ws"
        components.path = "/ws"
        components.queryItems = [URLQueryItem(name: "session", value: session)]
        return components.url ?? base
    }
}
#endif
