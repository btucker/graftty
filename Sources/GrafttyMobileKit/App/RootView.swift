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
                        WorktreePickerView(host: host) { wt in
                            navigationPath.append(WorktreeStep(host: host, worktree: wt))
                        }
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

    static func makeWebSocketURL(base: URL, session: String) -> URL {
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
    /// Actual system state (driven by keyboardWillShow/Hide).
    @State private var isKeyboardVisible: Bool = false
    /// User-controlled: false after the user taps "Hide keyboard". A
    /// stray tap that tries to re-summon the keyboard is immediately
    /// dismissed; the only way back on is the "Show keyboard" button.
    @State private var keyboardAllowed: Bool = true
    /// Monotonic counter: bumping it makes TerminalPaneView call
    /// becomeFirstResponder() on next update. Used to summon the
    /// keyboard programmatically from the show-keyboard button.
    @State private var focusRequestCount: Int = 0

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
        // Fill the container edges (notch, home indicator, landscape
        // side-bands) — but .container not .all, so SwiftUI still
        // respects the `.keyboard` safe-area region and pushes the
        // terminal up when the software keyboard rises. libghostty
        // paints its background color behind its view; the unsafe
        // regions outside our `.container` inherit that color.
        .ignoresSafeArea(.container, edges: .all)
        .toolbar(.hidden, for: .navigationBar)
            .overlay(alignment: .topLeading) {
                backButton
                    .padding(.leading, 12)
                    .padding(.top, 12)
            }
            .overlay(alignment: .bottom) {
                if connection == .live { terminalChrome }
            }
            .animation(.easeInOut(duration: 0.15), value: isKeyboardVisible)
            .animation(.easeInOut(duration: 0.15), value: keyboardAllowed)
            .onReceive(NotificationCenter.default.publisher(
                for: UIResponder.keyboardWillShowNotification
            )) { _ in
                isKeyboardVisible = true
                // If the user had explicitly hidden the keyboard, a stray
                // tap on the terminal can make UITerminalView ask for
                // first-responder again. Immediately dismiss — brief
                // flicker (one frame) but honours the user's intent.
                if !keyboardAllowed {
                    UIApplication.shared.sendAction(
                        #selector(UIResponder.resignFirstResponder),
                        to: nil, from: nil, for: nil
                    )
                }
            }
            .onReceive(NotificationCenter.default.publisher(
                for: UIResponder.keyboardWillHideNotification
            )) { _ in isKeyboardVisible = false }
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
                    controller = TerminalController(
                        configSource: text.map { .generated($0) } ?? .none
                    )
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
        if scenePhase == .background {
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
                    client?.sendEscape()
                }
                terminalTextControl("Tab", accessibilityLabel: "Tab") {
                    client?.sendTab()
                }
                terminalTextControl("^C", accessibilityLabel: "Control C") {
                    client?.sendControl(.c)
                }
                terminalTextControl("^D", accessibilityLabel: "Control D") {
                    client?.sendControl(.d)
                }
                Divider()
                    .frame(height: 28)
                terminalIconControl("arrow.left", accessibilityLabel: "Left arrow") {
                    client?.sendArrow(.left)
                }
                terminalIconControl("arrow.down", accessibilityLabel: "Down arrow") {
                    client?.sendArrow(.down)
                }
                terminalIconControl("arrow.up", accessibilityLabel: "Up arrow") {
                    client?.sendArrow(.up)
                }
                terminalIconControl("arrow.right", accessibilityLabel: "Right arrow") {
                    client?.sendArrow(.right)
                }
                Divider()
                    .frame(height: 28)
                terminalIconControl("return", accessibilityLabel: "Submit return") {
                    client?.submitReturn()
                }
                terminalTextControl("LF", accessibilityLabel: "Insert newline") {
                    client?.insertNewline()
                }
                terminalIconControl(
                    "keyboard.chevron.compact.down",
                    accessibilityLabel: "Hide keyboard"
                ) {
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
            let pane = TerminalPaneView(
                session: client.session,
                controller: controller,
                focusRequestCount: focusRequestCount,
                softwareKeyboardInput: .init(
                    insertText: { text in client.sendSoftwareKeyboardText(text) },
                    deleteBackward: { client.deleteBackward() }
                )
            )
            let cellWidth = client.cellWidthPoints ?? fallbackCellWidth
            let decision = TerminalWidthLayout.decide(
                containerWidth: containerSize.width,
                serverCols: client.serverGrid?.cols,
                cellWidth: cellWidth
            )
            switch decision {
            case .fits:
                pane
            case let .scrollable(frameWidth):
                ScrollView(.horizontal, showsIndicators: true) {
                    pane.frame(width: frameWidth, height: containerSize.height)
                }
            }
        } else {
            // Mac-config fetch in flight, or client not yet assigned.
            loadingPlaceholder
        }
    }

    /// Fallback cell width for the one-frame gap before libghostty's
    /// first resize callback lands. Chosen to overshoot realistic cell
    /// widths for iOS-scale fonts — a too-wide frame just scrolls a few
    /// empty cells, a too-narrow one makes the VT parser wrap.
    private var fallbackCellWidth: CGFloat { 7.0 }

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
    /// Walk the tree to find the title of the leaf whose `sessionName`
    /// matches. Used by SessionStep construction so the terminal view
    /// shows a human title (falls back to session name on miss).
    func title(for sessionName: String) -> String? {
        switch self {
        case let .leaf(name, title):
            return name == sessionName ? title : nil
        case let .split(_, _, left, right):
            return left.title(for: sessionName) ?? right.title(for: sessionName)
        }
    }
}
#endif
