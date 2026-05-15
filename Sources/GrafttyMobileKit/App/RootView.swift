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
                        WorktreePickerView(
                            host: host,
                            onSelect: { wt in
                                switch MobileNavigationDecision.decide(layout: wt.layout) {
                                case let .session(sessionName, title):
                                    navigationPath.append(SessionStep(
                                        host: host,
                                        sessionName: sessionName,
                                        title: title
                                    ))
                                case .worktreeDetail:
                                    navigationPath.append(WorktreeStep(host: host, worktree: wt))
                                }
                            },
                            onSelectPane: { leaf in
                                if case let .session(sessionName, title) =
                                    MobileNavigationDecision.decide(paneRow: leaf) {
                                    navigationPath.append(SessionStep(
                                        host: host,
                                        sessionName: sessionName,
                                        title: title
                                    ))
                                }
                            }
                        )
                    }
                    .navigationDestination(for: WorktreeStep.self) { step in
                        WorktreeDetailView(
                            host: step.host,
                            worktree: step.worktree
                        ) { sessionName in
                            navigationPath.append(SessionStep(
                                host: step.host,
                                sessionName: sessionName,
                                title: step.worktree.layout?.title(for: sessionName) ?? sessionName
                            ))
                        }
                    }
                    .navigationDestination(for: SessionStep.self) { step in
                        SingleSessionView(step: step, navigationPath: $navigationPath)
                    }
            }
            if gate.state == .locked {
                lockOverlay
            }
        }
        .environment(\.biometricGate, gate)
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

    nonisolated static func makeWebSocketURL(base: URL, session: String) -> URL {
        var components = URLComponents(url: base, resolvingAgainstBaseURL: false) ?? URLComponents()
        components.scheme = (base.scheme?.lowercased() == "https") ? "wss" : "ws"
        components.path = "/ws"
        components.queryItems = [URLQueryItem(name: "session", value: session)]
        return components.url ?? base
    }
}

/// Second-level nav: picked a worktree, now show its pane tree.
struct WorktreeStep: Hashable {
    let host: Host
    let worktree: WorktreePanes
}

/// Third-level nav: picked a pane, now show its terminal fullscreen.
struct SessionStep: Hashable {
    let host: Host
    let sessionName: String
    let title: String
}

/// Holds a weak reference to the live `TerminalInputContainerView` so
/// SwiftUI-side code (e.g., terminal control-bar buttons) can reach into
/// the UIKit container to cancel an active selection per IOS-11.7. The
/// container is owned by the `TerminalPaneView` representable; this box
/// is updated from `makeUIView` / `updateUIView` via `captureContainer`.
@MainActor
final class TerminalContainerBox {
    weak var view: TerminalInputContainerView?
    func cancelActiveSelectionIfAny() { view?.cancelActiveSelectionIfAny() }
}

/// Fullscreen terminal view for one session. Owns the WebSocket and
/// InMemoryTerminalSession; both are torn down on `.background` and
/// re-dialed on `.active` once the gate is unlocked.
struct SingleSessionView: View {
    let step: SessionStep
    @Binding var navigationPath: NavigationPath
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.biometricGate) private var gate

    @State private var client: SessionClient?
    @State private var connection: ConnectionState = .connecting
    /// Per-host TerminalController constructed with the Mac's ghostty
    /// config as its `configSource` — so `baseConfigTemplate` holds
    /// the Mac config, and libghostty-spm's on-trait-change
    /// `setColorScheme()` reconfigures on top of it instead of
    /// replacing it with the library default. Nil while we're still
    /// fetching the Mac config; replaced with a real controller
    /// once the fetch lands.
    @State private var controller: TerminalController?
    @State private var preferredStyle: UIUserInterfaceStyle = .unspecified
    /// User-controlled: false after the user taps "Hide keyboard". A
    /// stray tap that tries to re-summon the keyboard is immediately
    /// dismissed; the only way back on is the "Show keyboard" button.
    @State private var keyboardAllowed: Bool = true
    /// Monotonic counter: bumping it makes TerminalPaneView call
    /// becomeFirstResponder() on next update. Used to summon the
    /// keyboard programmatically from the show-keyboard button.
    @State private var focusRequestCount: Int = 0
    /// Height (pts) of the keyboard's overlap with the screen, used
    /// as an explicit bottom padding on the fullscreen layout
    /// (`IOS-6.9`). Populated from `keyboardWillChangeFrame`.
    @State private var keyboardBottomInset: CGFloat = 0
    /// Box that holds a weak reference to the live terminal-input
    /// container so the SwiftUI control-bar buttons can cancel an
    /// active selection per IOS-11.7.
    @State private var paneContainerBox = TerminalContainerBox()

    private var isKeyboardVisible: Bool { keyboardBottomInset > 0 }

    enum ConnectionState: Equatable {
        case connecting
        case live
        case suspended
        case ended
    }

    init(step: SessionStep, navigationPath: Binding<NavigationPath>) {
        self.step = step
        self._navigationPath = navigationPath
    }

    var body: some View {
        Group {
            switch connection {
            case .connecting, .suspended:
                loadingPlaceholder
            case .live:
                GeometryReader { geo in
                    terminalContent(containerSize: geo.size)
                }
            case .ended:
                endedBanner
            }
        }
        // IOS-6.9: explicit bottom padding lifts the terminal above
        // the keyboard. SwiftUI's automatic `.keyboard` safe-area
        // avoidance is unreliable when the focused responder is the
        // UIKeyInput proxy from IOS-6.6, so we drive it ourselves.
        .padding(.bottom, keyboardBottomInset)
        // IOS-4.8: fill every edge — top (under the notch), bottom
        // (under the home indicator), and the landscape side-bands.
        // libghostty paints its background color behind its view; the
        // unsafe regions inherit that color.
        .ignoresSafeArea()
        .toolbar(.hidden, for: .navigationBar)
            .overlay(alignment: .topLeading) {
                backButton
                    .padding(.leading, 12)
                    .padding(.top, 12)
            }
            .overlay(alignment: .top) {
                if let client, client.connectionState != .live {
                    reconnectBanner(client: client)
                        .padding(.top, 64)
                        .padding(.horizontal, 16)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .overlay(alignment: .bottom) {
                if connection == .live { terminalChrome }
            }
            .animation(.easeInOut(duration: 0.25), value: keyboardBottomInset)
            .animation(.easeInOut(duration: 0.15), value: keyboardAllowed)
            .onReceive(NotificationCenter.default.publisher(
                for: UIResponder.keyboardWillChangeFrameNotification
            )) { notification in
                guard let value = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue else { return }
                let newInset = KeyboardFrameInset.bottomInset(
                    keyboardEndFrame: value.cgRectValue,
                    screenBounds: UIScreen.main.bounds
                )
                if newInset != keyboardBottomInset {
                    keyboardBottomInset = newInset
                }
                // If the user had explicitly hidden the keyboard, a stray
                // tap on the terminal can make UITerminalView ask for
                // first-responder again. Immediately dismiss — brief
                // flicker (one frame) but honours the user's intent.
                if isKeyboardVisible && !keyboardAllowed {
                    UIApplication.shared.sendAction(
                        #selector(UIResponder.resignFirstResponder),
                        to: nil, from: nil, for: nil
                    )
                }
            }
            // Reads gate?.state inside `dialKey` so the @Observable
            // gate's unlock triggers re-evaluation. `connection` is
            // deliberately *not* in the key — it's the state-machine's
            // output, and including it would re-fire the task on every
            // transition (each re-fire only to hit a no-op early return).
            .task(id: dialKey) {
                await driveConnection()
            }
            .task(id: step.host.id) {
                // Fetch Mac config, then construct the per-host
                // TerminalController with it baked into the init source.
                // Doing it this way (vs. TerminalController.shared +
                // updateConfigSource) means `baseConfigTemplate` captures
                // the Mac config, so scene-phase / trait-collection
                // color-scheme recomputes preserve the Mac theme.
                let text = await GhosttyConfigFetcher.fetch(baseURL: step.host.baseURL)
                if controller == nil {
                    preferredStyle = GhosttyConfigFetcher.preferredInterfaceStyle(for: text)
                    controller = MobileTerminalControllerFactory.make(configText: text)
                }
            }
            .onDisappear {
                client?.stop()
                client = nil
            }
    }

    private var dialKey: DialKey {
        DialKey(scene: scenePhase, gateUnlocked: gate.isUnlocked)
    }

    private struct DialKey: Hashable {
        let scene: ScenePhase
        let gateUnlocked: Bool
    }

    private func driveConnection() async {
        if LiveSessionReadiness.shouldTearDown(scene: scenePhase) {
            client?.stop()
            client = nil
            if connection != .ended { connection = .suspended }
            return
        }
        guard LiveSessionReadiness.isActive(scene: scenePhase, gateUnlocked: gate.isUnlocked) else { return }
        switch connection {
        case .live, .ended:
            return
        case .connecting:
            // First dial — trust the /sessions response that put the user
            // here. Skip verification to keep the cold-open fast.
            await openWebSocket()
        case .suspended:
            // IOS-7.2 / IOS-7.3: verify the session still exists before
            // re-opening a WS that the server can't satisfy.
            await verifyThenOpen()
        }
    }

    private func verifyThenOpen() async {
        let result: Result<[SessionInfo], Error>
        do {
            result = .success(try await SessionsFetcher.fetch(baseURL: step.host.baseURL))
        } catch {
            result = .failure(error)
        }
        if Task.isCancelled { return }
        switch SessionRehydration.decide(sessionName: step.sessionName, sessionsResult: result) {
        case .ended:
            connection = .ended
        case .dial:
            await openWebSocket()
        }
    }

    private func openWebSocket() async {
        // URLSessionWebSocketTask.resume() fires synchronously inside
        // SessionClient.live(), so guard before the dial — otherwise we
        // burn a TCP/TLS handshake on a connection we'd immediately abort.
        if Task.isCancelled || connection == .ended { return }
        let new = SessionClient.live(baseURL: step.host.baseURL, sessionName: step.sessionName)
        if Task.isCancelled || connection == .ended {
            // Re-backgrounded (or ended) between WS construction and
            // assignment. Stop the orphan so the WS task doesn't leak.
            new.stop()
            return
        }
        new.start()
        client = new
        connection = .live
    }

    private var loadingPlaceholder: some View {
        Color.black.overlay(ProgressView().tint(.white))
    }

    private var endedBanner: some View {
        ContentUnavailableView {
            Label("Session no longer running", systemImage: "xmark.circle")
        } description: {
            Text("This pane was stopped while the app was in the background.")
        } actions: {
            Button("Back to sessions", action: popToParent)
                .buttonStyle(.borderedProminent)
        }
        .background(.regularMaterial)
    }

    /// Partially-transparent back button in the top-left. The nav bar is
    /// hidden while the terminal is full-screen, so this is the only
    /// in-app affordance for going back (edge-swipe is still available
    /// but undiscoverable).
    private var backButton: some View {
        Button(action: popToParent) {
            keyboardGlyph("chevron.left")
        }
        .accessibilityLabel("Back")
    }

    private func popToParent() {
        if !navigationPath.isEmpty {
            navigationPath.removeLast()
        }
    }

    @ViewBuilder
    private func reconnectBanner(client: SessionClient) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "wifi.exclamationmark")
            VStack(alignment: .leading, spacing: 2) {
                Text("Reconnecting…")
                    .font(.subheadline.weight(.semibold))
                if case .reconnecting(let attempt) = client.connectionState {
                    Text("Attempt \(attempt)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button("Reconnect") { client.forceReconnectNow() }
                .buttonStyle(.bordered)
                .controlSize(.small)
            Button("Back") { popToParent() }
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(.separator.opacity(0.35), lineWidth: 0.5)
        )
    }

    @ViewBuilder
    private var terminalChrome: some View {
        if isKeyboardVisible {
            terminalControlBar
                .transition(.move(edge: .bottom).combined(with: .opacity))
        } else if !keyboardAllowed {
            HStack {
                Spacer()
                keyboardButton
                    .transition(.opacity.combined(with: .scale))
            }
            .padding(.trailing, 12)
            .padding(.bottom, 12)
        }
    }

    /// When the keyboard is hidden by user intent, the only visible
    /// terminal chrome is a compact show-keyboard affordance.
    @ViewBuilder
    private var keyboardButton: some View {
        if !keyboardAllowed {
            Button {
                keyboardAllowed = true
                focusRequestCount += 1
            } label: {
                keyboardGlyph("keyboard")
            }
            .accessibilityLabel("Show keyboard")
        }
    }

    private var terminalControlBar: some View {
        // Bar is only mounted when `connection == .live`, where
        // `client != nil` — the optional-chaining is purely to satisfy
        // the compiler.
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                terminalTextControl("Esc", accessibilityLabel: "Escape") {
                    paneContainerBox.cancelActiveSelectionIfAny()
                    client?.sendEscape()
                }
                terminalTextControl("Tab", accessibilityLabel: "Tab") {
                    paneContainerBox.cancelActiveSelectionIfAny()
                    client?.sendTab()
                }
                terminalTextControl("^C", accessibilityLabel: "Control C") {
                    paneContainerBox.cancelActiveSelectionIfAny()
                    client?.sendControl(.c)
                }
                terminalTextControl("^D", accessibilityLabel: "Control D") {
                    paneContainerBox.cancelActiveSelectionIfAny()
                    client?.sendControl(.d)
                }
                Divider()
                    .frame(height: 28)
                terminalIconControl("arrow.left", accessibilityLabel: "Left arrow") {
                    paneContainerBox.cancelActiveSelectionIfAny()
                    client?.sendArrow(.left)
                }
                terminalIconControl("arrow.down", accessibilityLabel: "Down arrow") {
                    paneContainerBox.cancelActiveSelectionIfAny()
                    client?.sendArrow(.down)
                }
                terminalIconControl("arrow.up", accessibilityLabel: "Up arrow") {
                    paneContainerBox.cancelActiveSelectionIfAny()
                    client?.sendArrow(.up)
                }
                terminalIconControl("arrow.right", accessibilityLabel: "Right arrow") {
                    paneContainerBox.cancelActiveSelectionIfAny()
                    client?.sendArrow(.right)
                }
                Divider()
                    .frame(height: 28)
                terminalIconControl("return", accessibilityLabel: "Submit return") {
                    paneContainerBox.cancelActiveSelectionIfAny()
                    client?.submitReturn()
                }
                terminalTextControl("LF", accessibilityLabel: "Insert newline") {
                    paneContainerBox.cancelActiveSelectionIfAny()
                    client?.insertNewline()
                }
                terminalIconControl(
                    "keyboard.chevron.compact.down",
                    accessibilityLabel: "Hide keyboard"
                ) {
                    paneContainerBox.cancelActiveSelectionIfAny()
                    keyboardAllowed = false
                    UIApplication.shared.sendAction(
                        #selector(UIResponder.resignFirstResponder),
                        to: nil, from: nil, for: nil
                    )
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
        }
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(.separator.opacity(0.35), lineWidth: 0.5)
        )
        .padding(.horizontal, 8)
        .padding(.bottom, 8)
    }

    /// The terminal body, wrapped in a horizontal ScrollView only when
    /// the server's grid is wider than the container can render at
    /// libghostty's actual cell width. The inner TerminalPaneView takes
    /// the full server-grid width so libghostty's VT parser renders
    /// every column faithfully — a narrower frame would make its VT
    /// parser wrap lines at `frame.width / realCellWidth < serverCols`.
    @ViewBuilder
    private func terminalContent(containerSize: CGSize) -> some View {
        if let controller, let client {
            switch client.renderActivity {
            case .active:
                activeTerminal(client: client, controller: controller, containerSize: containerSize)
            case .idle:
                IdleSnapshotView(snapshot: client.idleSnapshot) {
                    client.wakeRenderer()
                }
            }
        } else {
            // Mac-config fetch in flight, or client not yet assigned.
            loadingPlaceholder
        }
    }

    @ViewBuilder
    private func activeTerminal(
        client: SessionClient,
        controller: TerminalController,
        containerSize: CGSize
    ) -> some View {
        let pane = TerminalPaneView(
            session: client.session,
            controller: controller,
            focusRequestCount: focusRequestCount,
            softwareKeyboardInput: .init(
                insertText: { text in client.sendSoftwareKeyboardText(text) },
                deleteBackward: { client.deleteBackward() }
            ),
            preferredInterfaceStyle: preferredStyle,
            onWillUnmount: { snapshot in client.setIdleSnapshot(snapshot) },
            onPasteRequested: { [weak client] in
                guard let client, let text = UIPasteboard.general.string, !text.isEmpty else {
                    return
                }
                client.sendPaste(text)
            },
            captureContainer: { [paneContainerBox] view in paneContainerBox.view = view }
        )
        let cellWidth = client.cellWidthPoints ?? TerminalWidthLayout.fallbackCellWidth
        let decision = TerminalWidthLayout.decide(
            containerWidth: containerSize.width,
            serverCols: client.serverGrid?.cols,
            cellWidth: cellWidth,
            isLeader: client.isSizeLeader
        )
        switch decision {
        case .fits:
            pane
        case let .scrollable(frameWidth):
            ScrollView(.horizontal, showsIndicators: true) {
                pane.frame(width: frameWidth, height: containerSize.height)
            }
        }
    }

    private func keyboardGlyph(_ systemName: String) -> some View {
        Image(systemName: systemName)
            .font(.title2)
            .foregroundStyle(.primary)
            .padding(10)
            .background(.ultraThinMaterial, in: Circle())
            .shadow(radius: 1)
    }

    private func terminalTextControl(
        _ title: String,
        accessibilityLabel: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
                .font(.footnote.monospaced().weight(.semibold))
                .foregroundStyle(.primary)
                .frame(minWidth: 44, minHeight: 34)
                .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .accessibilityLabel(accessibilityLabel)
    }

    private func terminalIconControl(
        _ systemName: String,
        accessibilityLabel: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.body.weight(.semibold))
                .foregroundStyle(.primary)
                .frame(width: 38, height: 34)
                .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .accessibilityLabel(accessibilityLabel)
    }
}

extension PaneLayoutNode {
    func title(for sessionName: String) -> String? {
        leaves.first { $0.sessionName == sessionName }?.title
    }
}
#endif
