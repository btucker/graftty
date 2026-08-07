#if canImport(UIKit)
import GhosttyTerminal
import GrafttyProtocol
import SwiftUI

public struct RootView: View {

    @State private var hostStore = HostStore()
    @State private var gate = BiometricGate()
    @State private var navigationPath = NavigationPath()
    @Environment(\.scenePhase) private var scenePhase
    @State private var iPadAppState = IPadAppState()
    /// Owned here (not per-screen) so a negotiated SSH connection survives
    /// navigation-stack pushes/pops on the compact path and layout
    /// transitions on the iPad path — both `compactBody`'s
    /// `SingleSessionView` and `IPadRootLayout` are handed the SAME
    /// instance so a host negotiated once from either surface is cached
    /// for the other.
    @State private var coordinator = RemoteConnectionCoordinator(
        connectionsAllowedInitially: false
    )
    @State private var nearbyMacBrowser = NearbyMacBrowser()
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    public init() {}

    public var body: some View {
        ZStack {
            switch horizontalSizeClass {
            case .regular:
                IPadRootLayout(
                    hostStore: hostStore,
                    appState: iPadAppState,
                    coordinator: coordinator,
                    nearbyMacBrowser: nearbyMacBrowser
                )
            default:
                compactBody
            }
            if gate.state == .locked {
                lockOverlay
            }
        }
        .environment(\.biometricGate, gate)
        .task {
            await gate.authenticate()
            updateConnectionAccess()
        }
        .onChange(of: gate.state) { _, _ in
            updateConnectionAccess()
        }
        .onAppear { nearbyMacBrowser.start() }
        .onChange(of: nearbyMacBrowser.candidates) { _, candidates in
            coordinator.updateDiscoveryCandidates(candidates)
            for candidate in candidates
            where coordinator.isTrustedDiscoveryCandidate(candidate) {
                try? hostStore.refreshDiscoveredDevice(
                    id: candidate.deviceID,
                    label: candidate.label,
                    baseURL: candidate.baseURL
                )
            }
        }
        .onChange(of: scenePhase) { _, newPhase in
            switch newPhase {
            case .background:
                gate.applicationDidEnterBackground()
                // Only `.background`, not `.inactive`: IPAD-5.1 is scoped to
                // "enters the background." `.inactive` also fires for
                // Control Center pulls / app-switcher / call banners, where
                // tearing down every negotiated connection would force a
                // needless full re-negotiation on the very next frame —
                // Per-view terminal channels also survive `.inactive` per
                // IOS-10.1, avoiding churn while the shared transport is
                // intentionally kept alive.
                updateConnectionAccess()
            case .active:
                gate.applicationWillEnterForeground()
                updateConnectionAccess()
                if gate.state == .locked {
                    Task { await gate.authenticate() }
                }
            default:
                break
            }
        }
    }

    private func updateConnectionAccess() {
        coordinator.setConnectionsAllowed(
            scenePhase != .background && gate.state == .unlocked
        )
    }

    @ViewBuilder
    private var compactBody: some View {
        NavigationStack(path: $navigationPath) {
            HostPickerView(
                store: hostStore,
                browser: nearbyMacBrowser,
                coordinator: coordinator
            )
                .navigationDestination(for: Host.self) { host in
                    WorktreePickerView(
                        host: host,
                        coordinator: coordinator,
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
                        worktree: step.worktree,
                        coordinator: coordinator
                    ) { sessionName in
                        navigationPath.append(SessionStep(
                            host: step.host,
                            sessionName: sessionName,
                            title: step.worktree.layout?.title(for: sessionName) ?? sessionName
                        ))
                    }
                }
                .navigationDestination(for: SessionStep.self) { step in
                    SingleSessionView(step: step, navigationPath: $navigationPath, coordinator: coordinator)
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
        components.queryItems = [
            URLQueryItem(name: "session", value: session),
            // Advertise the iOS client kind through the transport the daemon
            // trusts (`declaredDisplayClientKind`). `URLSessionWebSocketClient`
            // connects with a bare URL (no custom header / User-Agent), so this
            // query param is the only kind signal the server sees. Without it
            // the connection is classified `.web`, the store stamps
            // `ownerKind=.web`, and `SessionClient.isOwner` (which requires
            // `.ios`) is never true — the phone becomes a permanent follower
            // that cannot confirm ownership after Take Control or input
            // takeover.
            URLQueryItem(name: "client", value: "ios"),
        ]
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
    func fitTerminalToCurrentSize() { view?.terminalView.fitToSize() }
}

/// Fullscreen terminal view for one session. Owns the authenticated terminal
/// channel and `InMemoryTerminalSession`; transient `.inactive` phases preserve
/// both, while `.background` closes transport but keeps the mounted terminal
/// session alive. Once `.active` and unlocked, the same client re-dials without
/// freeing and remounting Ghostty's renderer during a QuartzCore transaction.
struct SingleSessionView: View {
    static let sessionRole: SessionClient.Role = .fullscreen

    let step: SessionStep
    @Binding var navigationPath: NavigationPath
    /// True for the iPhone compact path (fullscreen route via
    /// NavigationStack push) where the back button and edge-to-edge bleed
    /// belong; false when this view lives inside the iPad
    /// `NavigationSplitView` detail column, where the system already owns
    /// chrome for back-navigation and a hidden navigation bar would also
    /// hide the sidebar-toggle button — leaving no way to re-show a
    /// collapsed sidebar (IPAD-1.7).
    let isFullScreen: Bool
    /// Injected from `RootView` on BOTH size classes so `openTerminal()`
    /// can negotiate (or reuse) the per-host `RemoteHostConnection` for
    /// SSH-over-WebRTC. `nil` exists only in preview and narrowly scoped
    /// test contexts; production refuses the dial when pairing is absent
    /// or negotiation fails.
    let coordinator: RemoteConnectionCoordinator?
    /// Not-yet-honored focus requests owned by app-scoped state (the iPad
    /// layout passes `appState.pendingFocusRequests`). A pending delta, not
    /// a monotonic total, so view recreation cannot replay honored requests.
    let externalPendingFocusRequests: Int
    /// Zeroes the external pending count after a successful keyboard focus
    /// (the iPad layout wires this to `appState.consumeFocusRequests()`).
    let onExternalFocusRequestsConsumed: (() -> Void)?
    let autoTakeControlRequestCount: Int
    let ghosttyCommandContext: MobileGhosttyCommandContext?
    /// Regular-width iPad mounts one real `SingleSessionView` per pane. Only
    /// the selected pane may own UIKit keyboard input and app shortcuts.
    let isPaneFocused: Bool
    /// Embedded panes let their shared multi-pane parent manage the keyboard
    /// inset once for the whole split tree.
    let isEmbeddedPane: Bool
    /// Fired from the terminal's UIKit touch observer before focus/input is
    /// attempted, allowing the split tree to select this leaf first.
    let onPaneInteraction: (() -> Void)?
    /// Embedded regular-width panes use the iPad sidebar rather than a
    /// `NavigationStack`; this callback gives their reconnect/ended actions a
    /// real route back to the worktree list.
    let onBackToWorktrees: (() -> Void)?
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
    /// How much of `focusRequestCount` has already been honored with a
    /// successful `becomeFirstResponder()`. Same `@State` lifetime as the
    /// counter itself, so the pair stays consistent across TerminalPaneView
    /// remounts (idle-snapshot swaps) and resets together when this view's
    /// identity changes (IPAD-8.9).
    @State private var consumedFocusRequestCount: Int = 0
    /// Height (pts) of the keyboard's overlap with the screen, used
    /// as an explicit bottom padding on the fullscreen layout
    /// (`IOS-6.9`). Populated from `keyboardWillChangeFrame`.
    @State private var keyboardBottomInset: CGFloat = 0
    /// Box that holds a weak reference to the live terminal-input
    /// container so the SwiftUI control-bar buttons can cancel an
    /// active selection per IOS-11.7.
    @State private var paneContainerBox = TerminalContainerBox()
    /// The iOS-scaled Mac ghostty config used to build `controller`.
    /// Cached so the follower/ownerless auto-fit path (IOS-5.6) can re-apply
    /// the base config or a font-size override without re-fetching.
    @State private var baseConfigText: String?
    /// Last font-size override applied via TerminalWidthLayout.decide while
    /// not owner, so we can detect transitions (e.g. base ↔ override) and
    /// avoid pointlessly rebuilding the controller config on every layout
    /// tick. Set to nil while the base config is in effect.
    @State private var liveFontOverride: Float?
    /// Injected by the iPad layout as `appState.autoTakeControlPolicy` so the
    /// fulfillment latch survives view recreation; direct constructions
    /// (compact path, previews, tests) default to a fresh instance, which is
    /// inert because their `autoTakeControlRequestCount` is always 0.
    private let autoTakeControlPolicy: AutoTakeControlPolicy
    /// Scene-suspension memory only: if this fullscreen pane was the display
    /// owner before iOS forced the live session down, the next dial may reclaim
    /// an ownerless session. It deliberately does not apply to navigation-away
    /// teardown, where the user intentionally left the pane.
    @State private var reclaimControlOnNextDial = false

    private var isKeyboardVisible: Bool { keyboardBottomInset > 0 }

    static func shouldShowTakeControl(
        isFullScreen: Bool,
        clientCanTakeControl: Bool
    ) -> Bool {
        // Fullscreen controls navigation chrome, not display ownership.
        clientCanTakeControl
    }

    static func shouldExposeKeyboard(
        clientIsOwner: Bool,
        keyboardAllowed: Bool,
        isKeyboardVisible: Bool
    ) -> Bool {
        clientIsOwner
    }

    static func isTerminalKeyboardEligible(
        clientIsOwner: Bool,
        isPaneFocused: Bool = true
    ) -> Bool {
        clientIsOwner && isPaneFocused
    }

    static func shouldDismissKeyboard(
        isKeyboardVisible: Bool,
        keyboardAllowed: Bool,
        isPaneFocused: Bool
    ) -> Bool {
        isPaneFocused && isKeyboardVisible && !keyboardAllowed
    }

    /// Reference type on purpose: the fulfillment latch must outlive any one
    /// `SingleSessionView` identity. The instance is owned by `IPadAppState`
    /// (the same scope as `ownershipRequestCount`) so a detail-view
    /// recreation — e.g. the focused-pane fallback after the host closes a
    /// pane — cannot reset the latch and replay an already-fulfilled
    /// ownership request (IPAD-8.8).
    final class AutoTakeControlPolicy {
        private var fulfilledRequestCount: Int = 0

        init() {}

        func shouldTakeControl(
            requestCount: Int,
            isOwner: Bool,
            canTakeControl: Bool
        ) -> Bool {
            guard requestCount > fulfilledRequestCount else { return false }
            if isOwner {
                fulfilledRequestCount = requestCount
                return false
            }
            if canTakeControl {
                fulfilledRequestCount = requestCount
                return true
            }
            return false
        }
    }

    static func shouldFocusKeyboardOnOwnerTransition(
        wasOwner: Bool,
        isOwner: Bool,
        keyboardAllowed: Bool
    ) -> Bool {
        !wasOwner && isOwner && keyboardAllowed
    }

    static func shouldSynchronizeViewportOnOwnerTransition(
        wasOwner: Bool,
        isOwner: Bool
    ) -> Bool {
        !wasOwner && isOwner
    }

    /// Terminal theme background, parsed from the Mac-resolved ghostty config.
    /// Painted behind the whole session so the control-bar row and the strip
    /// revealed during keyboard transitions match the terminal's background
    /// instead of showing system chrome. The Mac resolves themes / named /
    /// palette colors to hex before sending the config, so this matches what
    /// libghostty actually renders. Falls back to the shared default.
    private var themeBackgroundColor: Color {
        (baseConfigText.map(GhosttyThemeColors.init(parsingConfigText:)) ?? .fallback).background
    }

    enum ConnectionState: Equatable {
        case connecting
        case live
        case suspended
        case ended

        var presentation: ConnectionPresentation {
            switch self {
            case .connecting:
                return .loading
            case .live, .suspended:
                return .terminal
            case .ended:
                return .ended
            }
        }
    }

    enum ConnectionPresentation: Equatable {
        case loading
        case terminal
        case ended
    }

    init(
        step: SessionStep,
        navigationPath: Binding<NavigationPath>,
        isFullScreen: Bool = true,
        coordinator: RemoteConnectionCoordinator? = nil,
        externalPendingFocusRequests: Int = 0,
        onExternalFocusRequestsConsumed: (() -> Void)? = nil,
        autoTakeControlRequestCount: Int = 0,
        autoTakeControlPolicy: AutoTakeControlPolicy = AutoTakeControlPolicy(),
        ghosttyCommandContext: MobileGhosttyCommandContext? = nil,
        isPaneFocused: Bool = true,
        isEmbeddedPane: Bool = false,
        onPaneInteraction: (() -> Void)? = nil,
        onBackToWorktrees: (() -> Void)? = nil
    ) {
        self.step = step
        self._navigationPath = navigationPath
        self.isFullScreen = isFullScreen
        self.coordinator = coordinator
        self.externalPendingFocusRequests = externalPendingFocusRequests
        self.onExternalFocusRequestsConsumed = onExternalFocusRequestsConsumed
        self.autoTakeControlRequestCount = autoTakeControlRequestCount
        self.autoTakeControlPolicy = autoTakeControlPolicy
        self.ghosttyCommandContext = ghosttyCommandContext
        self.isPaneFocused = isPaneFocused
        self.isEmbeddedPane = isEmbeddedPane
        self.onPaneInteraction = onPaneInteraction
        self.onBackToWorktrees = onBackToWorktrees
    }

    var body: some View {
        ZStack {
            // Terminal theme background behind everything — including under the
            // keyboard, so its rounded corners (and the control-bar row) show
            // the terminal's color instead of system chrome. Ignores all
            // safe-area regions (incl. `.keyboard`) so it bleeds the full
            // screen; the keyboard-padded content sits on top of it.
            terminalBackground
            sessionView
        }
    }

    @ViewBuilder
    private var terminalBackground: some View {
        if isFullScreen {
            themeBackgroundColor.ignoresSafeArea()
        } else {
            themeBackgroundColor
        }
    }

    private var sessionView: some View {
        Group {
            switch connection.presentation {
            case .loading:
                loadingPlaceholder
            case .terminal:
                GeometryReader { _ in
                    VStack(spacing: 0) {
                        GeometryReader { termGeo in
                            terminalContent(containerSize: termGeo.size)
                                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                        }
                        // While the keyboard is up, the control bar is laid out
                        // in-flow directly below the terminal. Because this VStack
                        // already lives inside the keyboard-reduced area, the bar
                        // lands at the keyboard top and the terminal inherently
                        // reserves its height — no PreferenceKey measurement, no
                        // overlay/keyboard-avoidance mismatch.
                        if isKeyboardVisible && isPaneFocused {
                            terminalChrome
                        }
                    }
                }
            case .ended:
                endedBanner
            }
        }
        // IOS-6.9: explicit bottom padding lifts the terminal above
        // the keyboard. SwiftUI's automatic `.keyboard` safe-area
        // avoidance is unreliable when UITerminalView is the focused
        // responder, so we drive it ourselves.
        .padding(.bottom, isEmbeddedPane ? 0 : keyboardBottomInset)
        // IOS-4.8 + IPAD-1.7: fullscreen path bleeds to every edge
        // (under the notch, home indicator, landscape bands) and hides
        // the navigation bar so libghostty's background shows through.
        // The iPad split-column path keeps the navigation bar so its
        // system sidebar-toggle button stays available, and respects
        // the column's bounds so the sidebar doesn't visually overlap.
        .modifier(FullScreenChrome(enabled: isFullScreen))
            .overlay(alignment: .topLeading) {
                if isFullScreen {
                    backButton
                        .padding(.leading, 12)
                        .padding(.top, 12)
                }
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
                // Keyboard-hidden affordances (Take Control / show-keyboard)
                // float over the edge-to-edge terminal. When the keyboard is up
                // the bar is laid out in-flow instead (see the `.live` VStack),
                // so the terminal reserves its height.
                if connection == .live, !isKeyboardVisible, isPaneFocused {
                    terminalChrome
                }
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
                if Self.shouldDismissKeyboard(
                    isKeyboardVisible: isKeyboardVisible,
                    keyboardAllowed: keyboardAllowed,
                    isPaneFocused: isPaneFocused
                ) {
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
            .task(id: dialKey) {
                guard LiveSessionReadiness.isActive(
                    scene: scenePhase,
                    gateUnlocked: gate.isUnlocked
                ) else {
                    return
                }
                // Fetch Mac config, then construct the per-host
                // TerminalController with it baked into the init source.
                // Doing it this way (vs. TerminalController.shared +
                // updateConfigSource) means `baseConfigTemplate` captures
                // the Mac config, so scene-phase / trait-collection
                // color-scheme recomputes preserve the Mac theme.
                let text = await coordinator?
                    .presentation(for: step.host)?
                    .ghosttyConfig
                // `.task(id:)` cancellation is cooperative. A presentation
                // lookup may still return after backgrounding or locking;
                // never create/configure a Ghostty surface from that stale
                // lifecycle task.
                guard !Task.isCancelled,
                      LiveSessionReadiness.isActive(
                          scene: scenePhase,
                          gateUnlocked: gate.isUnlocked
                      )
                else { return }
                if controller == nil {
                    preferredStyle = GhosttyConfigFetcher.preferredInterfaceStyle(for: text)
                    controller = MobileTerminalControllerFactory.make(configText: text)
                    baseConfigText = text
                }
            }
            .onDisappear {
                client?.stop()
                client = nil
            }
            .onChange(of: autoTakeControlRequestCount) { _, _ in
                attemptAutoTakeControl()
            }
            .onChange(of: client?.canTakeControl) { _, _ in
                attemptAutoTakeControl()
            }
            .onChange(of: client?.isOwner) { _, _ in
                attemptAutoTakeControl()
            }
            .onChange(of: client?.connectionState) { _, state in
                guard state == .ended else { return }
                client?.stop()
                client = nil
                connection = .ended
            }
            .onChange(of: isPaneFocused) { _, isFocused in
                if isFocused {
                    attemptAutoTakeControl()
                    if client?.isOwner == true, keyboardAllowed {
                        focusRequestCount &+= 1
                    }
                } else {
                    paneContainerBox.view?.terminalView.resignFirstResponder()
                }
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
        guard !Task.isCancelled else { return }
        if LiveSessionReadiness.shouldSuspendTransport(scene: scenePhase) {
            if client?.isOwner == true {
                reclaimControlOnNextDial = true
            }
            client?.suspend()
            if connection != .ended { connection = .suspended }
            // RootView's coordinator access gate tears down the negotiated
            // connection on the same `.background` transition. The
            // foreground provider re-negotiates after that eviction.
            return
        }
        guard LiveSessionReadiness.isActive(scene: scenePhase, gateUnlocked: gate.isUnlocked) else { return }
        switch connection {
        case .live, .ended:
            return
        case .connecting:
            // First dial — trust the paired panes snapshot that put the
            // user here. Skip verification to keep the cold-open fast.
            await openTerminal()
        case .suspended:
            // IOS-7.2 / IOS-7.3: verify the session still exists before
            // re-opening a terminal channel that the host can't satisfy.
            await verifyThenOpen()
        }
    }

    private func verifyThenOpen() async {
        let result: Result<[WorktreePanes], Error>
        do {
            guard let coordinator else {
                await openTerminal()
                return
            }
            result = .success(
                try await coordinator.worktreePanes(for: step.host)
            )
        } catch {
            result = .failure(error)
        }
        if Task.isCancelled { return }
        switch SessionRehydration.decide(
            sessionName: step.sessionName,
            worktreesResult: result
        ) {
        case .ended:
            client?.stop()
            client = nil
            connection = .ended
        case .dial:
            await openTerminal()
        }
    }

    private func openTerminal() async {
        // Guard before the dial so we do not negotiate an authenticated
        // channel that we would immediately abort.
        if Task.isCancelled || connection == .ended { return }
        if let client {
            guard client.connectionState != .ended else {
                client.stop()
                self.client = nil
                connection = .ended
                return
            }
            client.resume(
                reclaimControlOnOwnerlessConnect: reclaimControlOnNextDial
            )
            connection = .live
            reclaimControlOnNextDial = false
            attemptAutoTakeControl()
            return
        }
        let new = SessionClient.live(
            baseURL: step.host.baseURL,
            sessionName: step.sessionName,
            role: Self.sessionRole,
            // REMOTE-2.1 (substance; the spec ID itself lands in W4):
            // `makeRemoteConnectionProvider` captures the COORDINATOR +
            // host, not a pre-resolved connection — every dial
            // `SessionClient`'s backoff loop performs asks the
            // coordinator fresh (and is the ONLY negotiation path;
            // there is no separate pre-resolve here), so a
            // degraded/evicted connection heals via a real
            // re-negotiation (fresh WebRTC + fresh SSH userauth)
            // instead of redialing the same dead actor forever.
            remoteConnectionProvider: makeRemoteConnectionProvider(
                coordinator: coordinator,
                host: step.host,
                sessionName: step.sessionName
            ),
            reclaimControlOnOwnerlessConnect: reclaimControlOnNextDial
        )
        if Task.isCancelled || connection == .ended {
            // Re-backgrounded (or ended) between channel construction and
            // assignment. Stop the orphan so the channel does not leak.
            new.stop()
            return
        }
        new.start()
        client = new
        connection = .live
        reclaimControlOnNextDial = false
        attemptAutoTakeControl()
    }

    private var loadingPlaceholder: some View {
        Color.black.overlay(ProgressView().tint(.white))
    }

    private var endedBanner: some View {
        ContentUnavailableView {
            Label("Session no longer running", systemImage: "xmark.circle")
        } description: {
            Text("This pane's process exited.")
        } actions: {
            if !isEmbeddedPane || onBackToWorktrees != nil {
                Button("Back to worktrees", action: popToParent)
                    .buttonStyle(.borderedProminent)
            }
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
        .buttonStyle(.plain)
        .accessibilityLabel("Back")
    }

    private func popToParent() {
        if let onBackToWorktrees {
            onBackToWorktrees()
            return
        }
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
            Button("Back to worktrees") { popToParent() }
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
        let shouldShowTakeControl = client.map {
            Self.shouldShowTakeControl(
                isFullScreen: isFullScreen,
                clientCanTakeControl: $0.canTakeControl
            )
        } ?? false
        let shouldExposeKeyboard = client.map {
            Self.shouldExposeKeyboard(
                clientIsOwner: $0.isOwner,
                keyboardAllowed: keyboardAllowed,
                isKeyboardVisible: isKeyboardVisible
            )
        } ?? false
        if shouldShowTakeControl || shouldExposeKeyboard {
            VStack(spacing: 8) {
                if let client, shouldShowTakeControl {
                    takeControlButton(client: client)
                }
                if shouldExposeKeyboard && isKeyboardVisible {
                    terminalControlBar
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                } else if shouldExposeKeyboard && !keyboardAllowed {
                    HStack {
                        Spacer()
                        keyboardButton
                            .transition(.opacity.combined(with: .scale))
                    }
                    .padding(.trailing, 12)
                }
            }
            // No gap below the bar while the keyboard is up — it should sit
            // flush against the keyboard. The 8pt breathing room is only for
            // the keyboard-hidden affordances (compact button / take-control),
            // which float above the home indicator.
            .padding(.bottom, isKeyboardVisible ? 0 : 8)
        } else {
            Color.clear
                .frame(width: 0, height: 0)
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

    private func takeControlButton(client: SessionClient) -> some View {
        Button {
            client.takeControl()
        } label: {
            Label("Take Control", systemImage: "hand.raised.fill")
                .font(.footnote.weight(.semibold))
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
        .background(.regularMaterial, in: Capsule())
        .overlay(
            Capsule()
                .strokeBorder(.separator.opacity(0.35), lineWidth: 0.5)
        )
        .accessibilityLabel("Take Control")
    }

    private func attemptAutoTakeControl() {
        guard isPaneFocused, let client else { return }
        if autoTakeControlPolicy.shouldTakeControl(
            requestCount: autoTakeControlRequestCount,
            isOwner: client.isOwner,
            canTakeControl: client.canTakeControl
        ) {
            client.takeControl()
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

    /// The terminal body. While not the display owner, applies a font-size
    /// override to the controller via `reconcileFontOverride` so that
    /// `authoritativeCols × cellWidth ≤ containerWidth` and the pane renders at
    /// the full container width with no horizontal ScrollView (IOS-5.6).
    @ViewBuilder
    private func terminalContent(containerSize: CGSize) -> some View {
        if let controller, let client {
            activeTerminal(
                client: client,
                controller: controller,
                containerSize: containerSize
            )
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
            pendingFocusRequests:
                max(0, focusRequestCount - consumedFocusRequestCount)
                + externalPendingFocusRequests,
            onFocusRequestsConsumed: {
                consumedFocusRequestCount = focusRequestCount
                onExternalFocusRequestsConsumed?()
            },
            committedSoftwareInput: Self.isTerminalKeyboardEligible(
                clientIsOwner: client.isOwner,
                isPaneFocused: isPaneFocused
            ) ? .init(
                insertText: { text in client.sendSoftwareKeyboardText(text) },
                deleteBackward: { client.deleteBackward() }
            ) : nil,
            hardwareKeyboardCommands: isPaneFocused ? ghosttyCommandContext.map {
                    MobileGhosttyCommandButtons.hardwareKeyboardCommands(for: $0)
                } ?? [] : [],
            renderPace: client.renderPace,
            onUserInteraction: { [weak client] in
                client?.wakeRenderer()
                onPaneInteraction?()
            },
            preferredInterfaceStyle: preferredStyle,
            // @spec IOS-11.8: When the user taps **Paste** in the long-press menu,
            // the application shall read `UIPasteboard.general.string` and, when
            // non-empty, send it via `SessionClient.sendPaste(_:)`. An empty or
            // absent clipboard string shall be a silent no-op.
            onPasteRequested: { [weak client] in
                guard let client, let text = UIPasteboard.general.string, !text.isEmpty else {
                    return
                }
                client.sendPaste(text)
            },
            captureContainer: { [paneContainerBox] view in paneContainerBox.view = view }
        )
        pane
            .task(id: TerminalFontFitTaskKey(
                containerSize: containerSize,
                authoritativeCols: client.authoritativeGrid?.cols,
                isOwner: client.isOwner,
                baseConfig: baseConfigText
            )) {
                reconcileFontOverride(
                    client: client,
                    controller: controller,
                    containerWidth: containerSize.width
                )
            }
            .onChange(of: client.isOwner) { wasOwner, isOwner in
                if Self.shouldSynchronizeViewportOnOwnerTransition(
                    wasOwner: wasOwner,
                    isOwner: isOwner
                ) {
                    // Ownership may arrive while the surface still has the
                    // follower-fit font. Restore the owner font synchronously,
                    // then explicitly ask Ghostty for its resulting grid on
                    // the next runloop. Relying on a later incidental layout
                    // leaves the remote PTY at the previous owner's size until
                    // the user types or shows the keyboard.
                    reconcileFontOverride(
                        client: client,
                        controller: controller,
                        containerWidth: containerSize.width
                    )
                    DispatchQueue.main.async { [paneContainerBox] in
                        paneContainerBox.fitTerminalToCurrentSize()
                    }
                }
                if Self.shouldFocusKeyboardOnOwnerTransition(
                    wasOwner: wasOwner,
                    isOwner: isOwner,
                    keyboardAllowed: keyboardAllowed
                ), isPaneFocused {
                    focusRequestCount += 1
                }
            }
    }

    /// @spec IOS-6.10
    /// Owner promotion restores the base config font: while a follower,
    /// the auto-fit override shrinks the font to match the authoritative
    /// (often desktop-width) grid. The owner-transition handler then
    /// explicitly synchronizes Ghostty's metrics on the next runloop so
    /// the resulting owner resize cannot wait for keyboard input.
    /// While owner with no override active, the reconciler leaves the
    /// font alone so pinch-to-zoom keeps adjusting from that baseline.
    private func reconcileFontOverride(
        client: SessionClient,
        controller: TerminalController,
        containerWidth: CGFloat
    ) {
        guard let baseConfig = baseConfigText else { return }
        let configSize = Float(
            GhosttyConfigFetcher.lastFontSize(in: baseConfig)
                ?? GhosttyConfigFetcher.defaultIOSFontSize
        )

        // The font size currently applied to the controller — either the
        // live override or the base config size. We pair this with
        // libghostty's reported cellWidthPoints to derive the real
        // monospace aspect of the currently-installed font.
        let measuredAt: Float = liveFontOverride ?? configSize

        let decision = TerminalWidthLayout.decide(
            containerWidth: containerWidth,
            authoritativeCols: client.authoritativeGrid?.cols,
            configFontSize: configSize,
            measuredCellWidthPoints: client.cellWidthPoints,
            measuredAtFontSize: measuredAt,
            isOwner: client.isOwner
        )
        switch TerminalWidthLayout.overrideAction(
            decision: decision,
            liveFontOverride: liveFontOverride
        ) {
        case .keep:
            return
        case .restoreConfigFont:
            controller.updateConfigSource(.generated(baseConfig))
            liveFontOverride = nil
        case let .applyOverride(pointSize):
            let overridden = MobileTerminalControllerFactory.appendingFontSizeOverride(
                to: baseConfig,
                fontSize: pointSize,
                comment: "GrafttyMobile auto-fit - non-owner"
            )
            controller.updateConfigSource(.generated(overridden))
            liveFontOverride = pointSize
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

    /// Wraps a control-bar action so that pressing any key while a
    /// terminal selection is active first cancels the selection
    /// (IOS-11.7). Every entry in `terminalControlBar` routes its
    /// action through this wrapper.
    private func controlBarAction(_ body: @escaping () -> Void) -> () -> Void {
        { [paneContainerBox] in
            paneContainerBox.cancelActiveSelectionIfAny()
            body()
        }
    }

    private func terminalTextControl(
        _ title: String,
        accessibilityLabel: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: controlBarAction(action)) {
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
        Button(action: controlBarAction(action)) {
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

/// Two distinct chrome behaviors composed into one modifier:
/// * Edge-to-edge bleed (`.ignoresSafeArea`) is on for BOTH paths — the
///   terminal fills the entire detail column (and entire screen on
///   iPhone), matching the Mac sidebar's title-bar-hidden look. Without
///   this on iPad the nav bar carves ~44pt off the top and the home
///   indicator carves ~25pt off the bottom, making the terminal short.
/// * Hiding the navigation bar (`.toolbar(.hidden, …)`) is iPhone-only.
///   The iPad split-column path keeps the nav bar present but
///   transparent (`.toolbarBackground(.hidden, …)`) so the system's
///   sidebar-toggle button floats over the terminal — like the Mac
///   sidebar toggle floats next to the traffic lights — without
///   stealing height from the terminal.
private struct FullScreenChrome: ViewModifier {
    let enabled: Bool

    func body(content: Content) -> some View {
        if enabled {
            content
                .ignoresSafeArea()
                .toolbar(.hidden, for: .navigationBar)
        } else {
            content
                // IPAD-1.10: top/bottom edges only — the terminal
                // extends under the navigation bar and home indicator
                // but stays within the column's horizontal bounds so
                // the sidebar shifts the terminal rather than
                // overlapping it.
                .ignoresSafeArea(.container, edges: [.top, .bottom])
                .toolbarBackground(.hidden, for: .navigationBar)
        }
    }
}
#endif
