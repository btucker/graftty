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
/// InMemoryTerminalSession for its lifetime; both are torn down when
/// the view pops from the stack.
struct SingleSessionView: View {
    let step: SessionStep
    @Binding var navigationPath: NavigationPath

    @State private var client: SessionClient
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

    init(step: SessionStep, navigationPath: Binding<NavigationPath>) {
        self.step = step
        self._navigationPath = navigationPath
        let wsURL = RootView.makeWebSocketURL(base: step.host.baseURL, session: step.sessionName)
        let ws = URLSessionWebSocketClient(url: wsURL)
        self._client = State(initialValue: SessionClient(sessionName: step.sessionName, webSocket: ws))
    }

    var body: some View {
        GeometryReader { geo in
            terminalContent(containerSize: geo.size)
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
            .overlay(alignment: .bottomTrailing) {
                HStack(spacing: 8) {
                    if isKeyboardVisible {
                        newlineButton
                            .transition(.opacity.combined(with: .scale))
                    }
                    keyboardButton
                        .transition(.opacity.combined(with: .scale))
                }
                .padding(.trailing, 12)
                .padding(.bottom, 12)
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
            .task { client.start() }
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
            .onDisappear { client.stop() }
    }

    /// Partially-transparent back button in the top-left. Pops the
    /// current SessionStep off `navigationPath`, landing on the worktree
    /// detail the user drilled in from. The nav bar is hidden while the
    /// terminal is full-screen, so this is the only in-app affordance
    /// for going back (edge-swipe is still available but undiscoverable).
    private var backButton: some View {
        Button {
            if !navigationPath.isEmpty {
                navigationPath.removeLast()
            }
        } label: {
            keyboardGlyph("chevron.left")
        }
        .accessibilityLabel("Back")
    }

    /// IOS-6.4: inserts a literal newline; the keyboard's Return submits.
    private var newlineButton: some View {
        Button {
            client.insertNewline()
        } label: {
            keyboardGlyph("arrow.turn.down.left")
        }
        .accessibilityLabel("Insert newline")
    }

    /// Tri-state floating button:
    ///   - keyboard visible → chevron-down, "Hide keyboard" (disables + resigns)
    ///   - keyboard hidden by user → chevron-up, "Show keyboard" (re-enables,
    ///     TerminalPaneView.updateUIView calls becomeFirstResponder on the
    ///     off→on edge so the keyboard reappears without requiring a tap)
    ///   - otherwise → no button
    @ViewBuilder
    private var keyboardButton: some View {
        if isKeyboardVisible {
            Button {
                keyboardAllowed = false
                UIApplication.shared.sendAction(
                    #selector(UIResponder.resignFirstResponder),
                    to: nil, from: nil, for: nil
                )
            } label: {
                keyboardGlyph("keyboard.chevron.compact.down")
            }
            .accessibilityLabel("Hide keyboard")
        } else if !keyboardAllowed {
            Button {
                keyboardAllowed = true
                focusRequestCount += 1
            } label: {
                keyboardGlyph("keyboard")
            }
            .accessibilityLabel("Show keyboard")
        }
    }

    /// The terminal body, wrapped in a horizontal ScrollView only when
    /// the server's grid is wider than the container can render at
    /// libghostty's actual cell width. The inner TerminalPaneView takes
    /// the full server-grid width so libghostty's VT parser renders
    /// every column faithfully — a narrower frame would make its VT
    /// parser wrap lines at `frame.width / realCellWidth < serverCols`.
    @ViewBuilder
    private func terminalContent(containerSize: CGSize) -> some View {
        if let controller {
            let pane = TerminalPaneView(
                session: client.session,
                controller: controller,
                focusRequestCount: focusRequestCount
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
            // TerminalController not yet constructed (Mac config fetch
            // in flight). Minimal placeholder; expected lifetime is a
            // few tens of ms on cache hits, up to one round-trip on
            // the first pane of a new host.
            Color.black
                .overlay(ProgressView().tint(.white))
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
