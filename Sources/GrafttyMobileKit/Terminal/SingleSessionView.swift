#if canImport(UIKit)
import GhosttyTerminal
import GrafttyCommandUI
import GrafttyProtocol
import SwiftUI

/// Holds a weak reference to the live `TerminalInputContainerView` so
/// SwiftUI-side code (e.g., terminal control-bar buttons) can reach into
/// the UIKit container to cancel an active selection per IOS-11.7. The
/// container is owned by the `TerminalPaneView` representable; this box
/// is updated from `makeUIView` / `updateUIView` via `captureContainer`.
@MainActor
final class TerminalContainerBox {
    weak var view: TerminalInputContainerView?
    var controlAttachmentID: UUID?
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
    static let autocorrectionDefaultsKey = "GrafttyMobile.terminalAutocorrectionEnabled"

    enum TerminalControlBarItem: String, Hashable {
        case escape
        case tab
        case stickyControl
        case shift
        case controlC
        case controlD
        case navigationDivider
        case left
        case down
        case up
        case right
        case returnDivider
        case submitReturn
        case literalLineFeed
        case autocorrection
        case hideKeyboard
    }

    static let terminalControlBarItems: [TerminalControlBarItem] = [
        .escape,
        .tab,
        .stickyControl,
        .shift,
        .controlC,
        .controlD,
        .navigationDivider,
        .left,
        .down,
        .up,
        .right,
        .returnDivider,
        .submitReturn,
        .literalLineFeed,
        .autocorrection,
        .hideKeyboard,
    ]

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
    let showsProjectRail: Bool
    /// RootView's coordinator, from the environment on BOTH size classes,
    /// so `openTerminal()` can negotiate (or reuse) the per-host
    /// `RemoteHostConnection` for SSH-over-WebRTC. `nil` exists only in
    /// preview and narrowly scoped test contexts; production refuses the
    /// dial when pairing is absent or negotiation fails.
    @Environment(\.remoteConnectionCoordinator) private var coordinator
    /// Not-yet-honored focus requests owned by app-scoped state (the iPad
    /// layout passes `appState.pendingFocusRequests`). A pending delta, not
    /// a monotonic total, so view recreation cannot replay honored requests.
    let externalPendingFocusRequests: Int
    /// Zeroes the external pending count after a successful keyboard focus
    /// (the iPad layout wires this to `appState.consumeFocusRequests()`).
    let onExternalFocusRequestsConsumed: (() -> Void)?
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
    private let fontSizeStore: TerminalFontSizeStore
    private let sidebarNavigation: SidebarNavigationState?
    @Environment(\.recentPaneActions) private var recentPaneActions
    @State private var recordedRecentVisit = false
    private let retainedPanes: RetainedPaneClientPool<RetainedMobilePane>?
    private let remoteConnectionProvider: RemoteConnectionProvider?
    private let previewManagementTransport: ((WorktreeManagementRequest, Host) async throws -> WorktreeManagementResponse)?
    @State private var attentionWorktrees: [WorktreePanes] = []
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.biometricGate) private var gate
    @Environment(\.mobileNotificationPaneActivation) private var notificationPaneActivation

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
    /// False after "Hide keyboard" so terminal touches cannot regain keyboard
    /// focus. "Show keyboard" restores eligibility before requesting focus.
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
    @State private var observedKeyboardBottomInset: CGFloat = 0
    /// Embedded panes read their split tree's single keyboard observation
    /// instead of subscribing themselves (IPAD-2.10).
    @Environment(\.multiPaneKeyboardFrame) private var multiPaneKeyboardFrame
    /// Box that holds a weak reference to the live terminal-input
    /// container so the SwiftUI control-bar buttons can cancel an
    /// active selection per IOS-11.7.
    @State private var paneContainerBox = TerminalContainerBox()
    @StateObject private var agentCompletion = AgentCompletionModel()
    @State private var stickyControlActivation:
        TerminalInputContainerView.StickyControlActivation = .inactive
    @State private var isTrayShiftSelected = false
    @AppStorage(autocorrectionDefaultsKey) private var isAutocorrectionEnabled = false
    /// The iOS-scaled Mac ghostty config used to build `controller`.
    /// Cached so owner-selected font preferences can be applied without re-fetching.
    @State private var baseConfigText: String?
    /// Terminal theme background, parsed from the Mac-resolved ghostty config.
    /// Painted behind the whole session so the control-bar row and the strip
    /// revealed during keyboard transitions match the terminal's background
    /// instead of showing system chrome. The Mac resolves themes / named /
    /// palette colors to hex before sending the config, so this matches what
    /// libghostty actually renders. Falls back to the shared default. Parsed
    /// once when `baseConfigText` is assigned rather than on every body.
    @State private var themeBackgroundColor = GhosttyThemeColors.fallback.background
    /// Latest owner-selected size. Pinch actions already update the live
    /// Ghostty surface; this state preserves that size across configuration updates.
    @State private var preferredFontSize: Float?
    @State private var terminalBrowserRequest: TerminalBrowserRequest?
    @State private var terminalBrowserError: String?

    private var keyboardBottomInset: CGFloat {
        if isEmbeddedPane, let multiPaneKeyboardFrame { return multiPaneKeyboardFrame.bottomInset }
        return observedKeyboardBottomInset
    }

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
        isPaneFocused: Bool = true,
        keyboardAllowed: Bool = true
    ) -> Bool {
        clientIsOwner && isPaneFocused && keyboardAllowed
    }

    static func handleAgentCompletionSceneChange(
        _ phase: ScenePhase,
        model: AgentCompletionModel,
        transportIsAvailable: Bool
    ) {
        guard phase != .active, model.isActive else { return }
        if phase == .inactive, transportIsAvailable {
            model.invalidateBoundary()
        } else {
            model.cancel(preserveLiteral: false)
        }
    }

    static func shouldDismissKeyboard(
        isKeyboardVisible: Bool,
        keyboardAllowed: Bool,
        isPaneFocused: Bool
    ) -> Bool {
        isPaneFocused && isKeyboardVisible && !keyboardAllowed
    }

    /// Runs once per keyboard frame notification. Also dismisses an
    /// in-flight keyboard presentation if Hide keyboard was chosen before
    /// its frame notification arrived.
    private func dismissKeyboardIfDisallowed() {
        guard Self.shouldDismissKeyboard(
            isKeyboardVisible: isKeyboardVisible,
            keyboardAllowed: keyboardAllowed,
            isPaneFocused: isPaneFocused
        ) else { return }
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder),
            to: nil, from: nil, for: nil
        )
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

    static func configByApplyingFontPreference(
        _ preferredFontSize: Float?,
        to baseConfig: String
    ) -> String {
        guard let preferredFontSize else { return baseConfig }
        let clamped = TerminalFontSizeAdjustment.apply(
            steps: 0,
            to: preferredFontSize
        )
        if let configured = GhosttyConfigFetcher.lastFontSize(in: baseConfig),
           abs(configured - Double(clamped)) < 0.0001 {
            return baseConfig
        }
        return MobileTerminalControllerFactory.appendingFontSizeOverride(
            to: baseConfig,
            fontSize: clamped,
            comment: "GrafttyMobile live worktree font size"
        )
    }

    private var effectiveBaseConfigText: String? {
        baseConfigText.map {
            Self.configByApplyingFontPreference(preferredFontSize, to: $0)
        }
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
        showsProjectRail: Bool = true,
        externalPendingFocusRequests: Int = 0,
        onExternalFocusRequestsConsumed: (() -> Void)? = nil,
        ghosttyCommandContext: MobileGhosttyCommandContext? = nil,
        isPaneFocused: Bool = true,
        isEmbeddedPane: Bool = false,
        onPaneInteraction: (() -> Void)? = nil,
        onBackToWorktrees: (() -> Void)? = nil,
        fontSizeStore: TerminalFontSizeStore = .shared,
        sidebarNavigation: SidebarNavigationState? = nil,
        retainedPanes: RetainedPaneClientPool<RetainedMobilePane>? = nil,
        attentionWorktrees: [WorktreePanes] = [],
        initialClient: SessionClient? = nil,
        initialController: TerminalController? = nil,
        initialKeyboardBottomInset: CGFloat = 0,
        remoteConnectionProvider: RemoteConnectionProvider? = nil,
        previewManagementTransport: ((WorktreeManagementRequest, Host) async throws -> WorktreeManagementResponse)? = nil
    ) {
        self.step = step
        self._navigationPath = navigationPath
        self.isFullScreen = isFullScreen
        self.showsProjectRail = showsProjectRail
        self.externalPendingFocusRequests = externalPendingFocusRequests
        self.onExternalFocusRequestsConsumed = onExternalFocusRequestsConsumed
        self.ghosttyCommandContext = ghosttyCommandContext
        self.isPaneFocused = isPaneFocused
        self.isEmbeddedPane = isEmbeddedPane
        self.onPaneInteraction = onPaneInteraction
        self.onBackToWorktrees = onBackToWorktrees
        self.fontSizeStore = fontSizeStore
        self.sidebarNavigation = sidebarNavigation
        self.retainedPanes = retainedPanes
        self.remoteConnectionProvider = remoteConnectionProvider
        self.previewManagementTransport = previewManagementTransport
        self._attentionWorktrees = State(initialValue: attentionWorktrees)
        self._client = State(initialValue: initialClient)
        self._controller = State(initialValue: initialController)
        self._connection = State(initialValue: initialClient == nil ? .connecting : .live)
        self._observedKeyboardBottomInset = State(initialValue: initialKeyboardBottomInset)
    }

    var body: some View {
        ZStack {
            // Terminal theme background also fills keyboard transitions.
            // Content reserves keyboard clearance independently.
            terminalBackground
            sessionView
        }
        .modifier(MobileWorktreeContextDrawer(context: worktreeContext))
        .alert("Could not open link", isPresented: Binding(
            get: { terminalBrowserError != nil }, set: { if !$0 { terminalBrowserError = nil } }
        )) { Button("OK") { terminalBrowserError = nil } } message: { Text(terminalBrowserError ?? "") }
        .background {
            ViewAttachmentObserver(didDetach: detachSession).frame(width: 0, height: 0)
        }
    }

    /// Full-screen resources cover the terminal without ending its attachment.
    /// Release controls and transport only after the pane actually leaves the UI.
    private func detachSession() {
        terminalBrowserRequest = nil
        agentCompletion.invalidateBoundary()
        agentCompletion.loadCandidates = nil
        // Removal is deferred beyond the UIKit update. A replacement route
        // may already own the retained container by the time this runs.
        if let container = paneContainerBox.view,
           container.controlAttachmentID == paneContainerBox.controlAttachmentID {
            container.detachBrowserControls()
            container.onBackRequested = nil
            container.onApplicationScrollRequested = nil
            container.resetStickyModifiers()
            container.onTrayShiftSelectionChange = nil
            container.terminalView.resignFirstResponder()
            if let cached = retainedPanes?.cached(retainedPaneKey),
               cached.client === client, cached.container === container {
                cached.detachControls()
            }
        }
        if retainedPanes == nil { client?.stop() }
        client = nil
        if connection != .ended { connection = .connecting }
    }

    private var worktreeContext: SidebarWorktreeContext? {
        guard !isEmbeddedPane, let row = attentionWorktrees.first(where: {
            if let path = step.worktreePath { return $0.path == path }
            return $0.layout?.leaves.contains(where: { $0.sessionName == step.sessionName }) == true
        }) else { return nil }
        return sidebarNavigation?.worktreeContext(row) ?? SidebarWorktreeContext(worktree: row)
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
                        terminalContent
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                            .overlay(alignment: .bottom) {
                                if agentCompletion.isActive, isPaneFocused {
                                    AgentCompletionPicker(model: agentCompletion)
                                        .frame(maxHeight: 240)
                                        .padding(.horizontal, 8)
                                        .padding(.bottom, 8)
                                }
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
                if isFullScreen || (isEmbeddedPane && isPaneFocused && onBackToWorktrees != nil) {
                    backButton
                        .modifier(TerminalFloatingControlPlacement())
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
            .overlay(alignment: .top) {
                if let client, let paging = client.paging, isPaneFocused,
                   client.connectionState == .live, client.imagePasteProgress == nil {
                    PagedHistoryBanner(paging: paging)
                        .padding(.top, 64)
                        .padding(.horizontal, 16)
                }
            }
            .overlay(alignment: .top) {
                if let client, isPaneFocused {
                    if let progress = client.imagePasteProgress {
                        VStack(spacing: 6) {
                            Text(progress < 1 ? "Uploading image…" : "Pasting image…")
                            ProgressView(value: progress)
                        }
                        .padding(12)
                        .frame(maxWidth: 260)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                        .padding(.top, 64)
                    } else if let error = client.imagePasteError {
                        HStack {
                            Text(error).font(.callout)
                            Button { client.imagePasteError = nil } label: {
                                Image(systemName: "xmark.circle.fill")
                            }
                            .accessibilityLabel("Dismiss image paste error")
                        }
                        .padding(12)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                        .padding(.horizontal, 16)
                        .padding(.top, 64)
                    }
                }
            }
            .overlay(alignment: .topTrailing) {
                if let worktree = step.worktreePath, let coordinator {
                    RemoteOpenButton(host: step.host, worktree: worktree, coordinator: coordinator,
                                     sessionName: step.sessionName,
                                     ownerDeviceID: client?.isOwner == true ? coordinator.localDeviceID : nil,
                                     isActive: isPaneFocused && scenePhase == .active && gate?.state == .unlocked && connection == .live,
                                     managementTransport: previewManagementTransport,
                                     browserConnectionReady: connection == .live,
                                     isPaneFocused: isPaneFocused,
                                     hasOwnershipSnapshot: client?.ownershipSnapshot != nil,
                                     isPaneOwner: { client?.isOwner == true },
                                     canPresentAuthentication: { true },
                                     terminalRequest: $terminalBrowserRequest)
                        .modifier(TerminalFloatingControlPlacement())
                        .padding(.trailing, 12)
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
            .onKeyboardBottomInsetChange(isEnabled: !isEmbeddedPane) { newInset in
                if newInset != observedKeyboardBottomInset {
                    observedKeyboardBottomInset = newInset
                }
                dismissKeyboardIfDisallowed()
            }
            .onChange(of: isEmbeddedPane ? multiPaneKeyboardFrame : nil) {
                dismissKeyboardIfDisallowed()
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
                let macConfig = await coordinator?
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
                    let savedFontSize = step.worktreePath.flatMap {
                        fontSizeStore.fontSize(
                            hostID: step.host.id,
                            worktreePath: $0
                        )
                    }
                    let text = GhosttyConfigFetcher.terminalConfig(
                        macConfig: macConfig,
                        savedFontSize: savedFontSize
                    )
                    preferredStyle = GhosttyConfigFetcher.preferredInterfaceStyle(
                        for: macConfig
                    )
                    controller = retainedPanes?.cached(retainedPaneKey)?.container?.terminalView.controller
                        ?? MobileTerminalControllerFactory.make(configText: text)
                    baseConfigText = text
                    themeBackgroundColor = GhosttyThemeColors(parsingConfigText: text).background
                    preferredFontSize = GhosttyConfigFetcher.lastFontSize(in: text)
                        .map(Float.init)
                }
            }
            .task(id: AttentionObservationKey(dial: dialKey, focused: isPaneFocused)) { await observeAttention() }
            .task(id: notificationRecoveryKey) {
                guard !Task.isCancelled, notificationRecoveryKey.isReady, let client,
                      client.sessionName == step.sessionName,
                      notificationPaneActivation?.consume(hostID: step.host.id,
                                                          sessionName: step.sessionName) == true else { return }
                if client.paging?.status == .requiresRecovery { await client.paging?.recover() }
            }
            .onChange(of: client?.connectionState) { _, state in
                if state != .live {
                    paneContainerBox.view?.cancelPendingApplicationScroll()
                    agentCompletion.cancel(preserveLiteral: false)
                }
                guard state == .ended else { return }
                retainedPanes?.remove(retainedPaneKey)
                client?.stop()
                client = nil
                connection = .ended
            }
            .onChange(of: connection) { _, _ in recordRecentVisit() }
            .onChange(of: isPaneFocused) { _, isFocused in
                recordedRecentVisit = false
                recordRecentVisit()
                if isFocused {
                    if client?.isOwner == true, keyboardAllowed {
                        focusRequestCount &+= 1
                    }
                } else {
                    paneContainerBox.view?.cancelPendingApplicationScroll()
                    paneContainerBox.view?.resetStickyModifiers()
                    paneContainerBox.view?.terminalView.resignFirstResponder()
                }
            }
            .onChange(of: scenePhase) { _, phase in
                if phase != .active { paneContainerBox.view?.cancelPendingApplicationScroll() }
                Self.handleAgentCompletionSceneChange(
                    phase, model: agentCompletion,
                    transportIsAvailable: client?.isOwner == true && client?.connectionState == .live
                )
            }
    }

    private struct NotificationRecoveryKey: Equatable {
        let occurrenceID: UUID?
        let clientID: ObjectIdentifier?
        let isReady: Bool
    }

    private var notificationRecoveryKey: NotificationRecoveryKey {
        // Let a pending page declare expiry before consuming the notification.
        // Recovery enters .installing itself; that must not cancel this task.
        .init(occurrenceID: notificationPaneActivation?.request?.id,
              clientID: client.map(ObjectIdentifier.init),
              isReady: connection == .live && client?.connectionState == .live && isPaneFocused
                  && client?.paging?.status != .loading
                  && scenePhase == .active && gate.isUnlocked)
    }

    private var dialKey: DialKey {
        DialKey(scene: scenePhase, gateUnlocked: gate.isUnlocked)
    }

    private struct DialKey: Hashable {
        let scene: ScenePhase
        let gateUnlocked: Bool
    }

    private struct AttentionObservationKey: Hashable {
        let dial: DialKey
        let focused: Bool
    }

    private func driveConnection() async {
        guard !Task.isCancelled else { return }
        if LiveSessionReadiness.shouldSuspendTransport(scene: scenePhase) {
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
            retainedPanes?.remove(retainedPaneKey)
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
        if let cached = retainedPanes?.cached(retainedPaneKey) {
            if cached.client.connectionState == .ended {
                retainedPanes?.remove(retainedPaneKey)
                connection = .ended
                return
            }
            if cached.requiresValidation, let coordinator {
                // Routes popped during backgrounding no longer have a view
                // task to verify them on foreground. Validate on reuse.
                if let rows = try? await coordinator.worktreePanes(for: step.host),
                   SessionRehydration.decide(sessionName: step.sessionName, worktreesResult: .success(rows)) == .ended {
                    retainedPanes?.remove(retainedPaneKey)
                    connection = .ended
                    return
                }
                guard !Task.isCancelled else { return }
            }
        }
        if let client {
            guard client.connectionState != .ended else {
                client.stop()
                self.client = nil
                connection = .ended
                return
            }
            client.resume()
            connection = .live
            return
        }
        let makeClient = { SessionClient.live(
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
            remoteConnectionProvider: remoteConnectionProvider ?? makeRemoteConnectionProvider(
                coordinator: coordinator,
                host: step.host,
                sessionName: step.sessionName
            )
        ) }
        let new: SessionClient
        if let retainedPanes {
            new = retainedPanes.acquire(retainedPaneKey) { RetainedMobilePane(client: makeClient()) }.client
        } else {
            new = makeClient()
            new.start()
        }
        if Task.isCancelled || connection == .ended {
            retainedPanes?.remove(retainedPaneKey)
            // Re-backgrounded (or ended) between channel construction and
            // assignment. Stop the orphan so the channel does not leak.
            new.stop()
            return
        }
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
        MobileTerminalBackButton(
            accessibilityLabel: backAccessibilityLabel,
            pendingCount: pendingAttentionCount,
            entries: recentPaneActions?.history.entries.filter {
                $0.hostID != step.host.id || $0.visit.item.paneID != step.sessionName
                    || $0.visit.item.worktreeID != step.worktreePath
            } ?? [],
            back: popToParent,
            open: { recentPaneActions?.open($0) }
        )
    }

    var backAccessibilityLabel: String {
        let count = pendingAttentionCount
        guard count > 0 else { return "Back to worktrees" }
        return "Back to worktrees, \(count) pending \(count == 1 ? "worktree" : "worktrees")"
    }

    private var retainedPaneKey: RetainedPaneClientPool<RetainedMobilePane>.Key {
        .init(hostID: step.host.id, sessionName: step.sessionName)
    }

    private var pendingAttentionCount: Int {
        guard let sidebarNavigation else { return 0 }
        let current = step.worktreePath ?? attentionWorktrees.first {
            $0.layout?.leaves.contains { $0.sessionName == step.sessionName } == true
        }?.path
        return MobilePaneAttention.pendingCount(worktrees: attentionWorktrees,
            currentWorktree: current, navigation: sidebarNavigation)
    }

    private func observeAttention() async {
        guard isFullScreen, isPaneFocused, let coordinator,
              LiveSessionReadiness.isActive(scene: scenePhase, gateUnlocked: gate.isUnlocked) else { return }
        for await update in coordinator.worktreeUpdates(for: step.host) {
            guard case let .frame(.snapshot(rows, metadata)) = update else {
                // Do not present a stale count while the host is unreachable.
                attentionWorktrees = []
                continue
            }
            let projects = metadata?.projects ?? SidebarProjection.projects(rows)
            sidebarNavigation?.reconcile(worktrees: rows, projects: projects)
            recentPaneActions?.history.reconcile(hostID: step.host.id, worktrees: rows, projects: projects)
            attentionWorktrees = rows
            recordRecentVisit()
        }
    }

    private func recordRecentVisit() {
        guard !recordedRecentVisit, isPaneFocused, connection == .live,
              let history = recentPaneActions?.history,
              let row = attentionWorktrees.first(where: {
                  $0.path == step.worktreePath && $0.layout?.leaves.contains(where: { $0.sessionName == step.sessionName }) == true
              }) else { return }
        history.record(hostID: step.host.id, hostLabel: step.host.label, worktree: row, sessionName: step.sessionName)
        recordedRecentVisit = true
    }

    func popToParent() {
        if let onBackToWorktrees {
            onBackToWorktrees()
            return
        }
        guard !navigationPath.isEmpty else { return }
        navigationPath = step.worktreePickerPath(showsProjectRail: showsProjectRail)
    }

    var terminalBackSwipeAction: (() -> Void)? {
        isFullScreen ? popToParent : nil
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
            TerminalFloatingGlyphButton(
                systemName: "keyboard",
                accessibilityLabel: "Show keyboard"
            ) {
                keyboardAllowed = true
                focusRequestCount += 1
            }
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
        .modifier(TerminalFloatingGlass())
        .accessibilityLabel("Take Control")
    }

    private var terminalControlBar: some View {
        // Bar is only mounted when `connection == .live`, where
        // `client != nil` — the optional-chaining is purely to satisfy
        // the compiler.
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Self.terminalControlBarItems, id: \.self) { item in
                    terminalControlBarItem(item)
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

    @ViewBuilder
    private func terminalControlBarItem(_ item: TerminalControlBarItem) -> some View {
        switch item {
        case .escape:
            terminalTextControl("Esc", accessibilityLabel: "Escape", completionKey: .escape) {
                client?.sendEscape()
            }
        case .tab:
            terminalTextControl("Tab", accessibilityLabel: "Tab", completionKey: .accept) {
                client?.sendTab(shift: paneContainerBox.view?.isTrayShiftSelected == true)
            }
        case .stickyControl:
            terminalModifierControl(
                "Ctrl",
                accessibilityLabel: "Sticky Control",
                activation: stickyControlActivation
            ) {
                paneContainerBox.view?.toggleStickyControlModifier()
            }
        case .controlC:
            terminalTextControl("^C", accessibilityLabel: "Control C") {
                client?.sendControl(.c)
            }
        case .shift:
            terminalModifierControl(
                "Shift",
                accessibilityLabel: "Tray Shift",
                activation: isTrayShiftSelected ? .locked : .inactive
            ) {
                paneContainerBox.view?.toggleTrayShift()
            }
        case .controlD:
            terminalTextControl("^D", accessibilityLabel: "Control D") {
                client?.sendControl(.d)
            }
        case .navigationDivider, .returnDivider:
            Divider().frame(height: 28)
        case .left:
            terminalIconControl("arrow.left", accessibilityLabel: "Left arrow") {
                client?.sendArrow(.left, shift: paneContainerBox.view?.isTrayShiftSelected == true)
            }
        case .down:
            terminalIconControl("arrow.down", accessibilityLabel: "Down arrow", completionKey: .down) {
                client?.sendArrow(.down, shift: paneContainerBox.view?.isTrayShiftSelected == true)
            }
        case .up:
            terminalIconControl("arrow.up", accessibilityLabel: "Up arrow", completionKey: .up) {
                client?.sendArrow(.up, shift: paneContainerBox.view?.isTrayShiftSelected == true)
            }
        case .right:
            terminalIconControl("arrow.right", accessibilityLabel: "Right arrow") {
                client?.sendArrow(.right, shift: paneContainerBox.view?.isTrayShiftSelected == true)
            }
        case .submitReturn:
            terminalIconControl("return", accessibilityLabel: "Submit return", completionKey: .accept) {
                client?.submitReturn()
            }
        case .literalLineFeed:
            terminalTextControl("LF", accessibilityLabel: "Insert newline") {
                client?.insertNewline()
            }
        case .autocorrection:
            terminalAutocorrectionControl
        case .hideKeyboard:
            terminalIconControl(
                "keyboard.chevron.compact.down",
                accessibilityLabel: "Hide keyboard"
            ) {
                paneContainerBox.view?.resetStickyModifiers()
                keyboardAllowed = false
                UIApplication.shared.sendAction(
                    #selector(UIResponder.resignFirstResponder),
                    to: nil, from: nil, for: nil
                )
            }
        }
    }

    /// Followers scale an authoritative canvas; owners use the physical viewport.
    @ViewBuilder
    private var terminalContent: some View {
        if let controller, let client {
            activeTerminal(
                client: client,
                controller: controller
            )
        } else {
            // Mac-config fetch in flight, or client not yet assigned.
            loadingPlaceholder
        }
    }

    @ViewBuilder
    private func activeTerminal(
        client: SessionClient,
        controller: TerminalController
    ) -> some View {
        let pane = TerminalPaneView(
            session: client.session,
            controller: controller,
            authoritativeGrid: client.snapshotCanvasGrid,
            reservesTopChromeSpace: true,
            showsAdditionalHistory: true,
            pendingFocusRequests:
                max(0, focusRequestCount - consumedFocusRequestCount)
                + externalPendingFocusRequests,
            onFocusRequestsConsumed: {
                consumedFocusRequestCount = focusRequestCount
                onExternalFocusRequestsConsumed?()
            },
            committedSoftwareInput: Self.isTerminalKeyboardEligible(
                clientIsOwner: client.isOwner,
                isPaneFocused: isPaneFocused,
                keyboardAllowed: keyboardAllowed
            ) ? .init(
                insertText: { text in
                    // A focus/eligibility update can flush the pending token
                    // after ownership changed. It must not request takeover.
                    guard client.isOwner, client.connectionState == .live else { return }
                    client.sendSoftwareKeyboardText(text)
                },
                insertControlByte: { byte in client.sendControlByte(byte) },
                deleteBackward: { client.deleteBackward() }
            ) : nil,
            agentCompletion: agentCompletion,
            isAutocorrectionEnabled: isAutocorrectionEnabled,
            hardwareKeyboardCommands: isPaneFocused ? ghosttyCommandContext.map {
                    MobileGhosttyCommandButtons.hardwareKeyboardCommands(for: $0)
                } ?? [] : [],
            renderPace: client.renderPace,
            onUserInteraction: { [weak client] in
                client?.wakeRenderer()
                onPaneInteraction?()
            },
            onApplicationScrollRequested: { [weak client] in
                guard let client, client.canTakeControl else { return }
                keyboardAllowed = false
                client.takeControl()
            },
            configuredFontSize: effectiveBaseConfigText.flatMap {
                GhosttyConfigFetcher.lastFontSize(in: $0).map(Float.init)
            },
            onFontSizeChange: fontSizeChangeHandler(isOwner: client.isOwner),
            preferredInterfaceStyle: preferredStyle,
            onPasteRequested: { [weak client] in
                client?.pasteFromClipboard()
            },
            onBackRequested: terminalBackSwipeAction,
            captureContainer: { [paneContainerBox, client] view in
                paneContainerBox.view = view
                paneContainerBox.controlAttachmentID = view.controlAttachmentID
                let shiftSelected = view.isTrayShiftSelected
                DispatchQueue.main.async { isTrayShiftSelected = shiftSelected }
                view.onTrayShiftSelectionChange = { selected in
                    DispatchQueue.main.async { isTrayShiftSelected = selected }
                }
                retainedPanes?.cached(retainedPaneKey)?.container = view
                client.additionalHistoryRowCapacity = { [weak view] in
                    view?.snapshotScrollView.additionalHistoryRowCapacity ?? 0
                }
                view.onPhysicalViewportReady = { [weak client = client] viewport in
                    client?.physicalViewportDidBecomeReady(viewport)
                }
                view.setStickyControlActivationChangeHandler { activation in
                    // This callback can fire while UIViewRepresentable is
                    // applying input eligibility. Leave that update cycle
                    // before mutating SwiftUI state.
                    DispatchQueue.main.async {
                        stickyControlActivation = activation
                    }
                }
            },
            retainedContainer: retainedPanes?.cached(retainedPaneKey)?.container,
            onOpenURL: { url in
                guard let coordinator, let worktree = step.worktreePath else {
                    terminalBrowserError = "Browser links require a tracked worktree on the originating Mac."
                    return
                }
                terminalBrowserRequest = TerminalBrowserRequest(url: url, scope: .init(
                    hostID: step.host.id, worktree: worktree, sessionName: step.sessionName,
                    ownerDeviceID: client.isOwner ? coordinator.localDeviceID : nil))
            },
            linkContext: AnyHashable(TerminalBrowserRequest.Scope(hostID: step.host.id,
                worktree: step.worktreePath ?? "", sessionName: step.sessionName,
                ownerDeviceID: client.isOwner ? coordinator?.localDeviceID : nil))
        )
        pane
            .onAppear {
                agentCompletion.currentWorktreePath = step.worktreePath
                let provider: RemoteConnectionProvider? = coordinator == nil ? nil : makeRemoteConnectionProvider(
                    coordinator: coordinator, host: step.host, sessionName: step.sessionName
                )
                let baseURL = step.host.baseURL
                let worktreePath = step.worktreePath
                agentCompletion.loadCandidates = {
                    try await AgentCompletionsFetcher.fetch(
                        baseURL: baseURL, provider: provider, worktreePath: worktreePath
                    )
                }
            }
            .onChange(of: client.isOwner) { wasOwner, isOwner in
                if !isOwner { agentCompletion.cancel(preserveLiteral: false) }
                if Self.shouldSynchronizeViewportOnOwnerTransition(
                    wasOwner: wasOwner,
                    isOwner: isOwner
                ) {
                    // Publish the physical viewport after the follower canvas is released.
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

    private func fontSizeChangeHandler(
        isOwner: Bool
    ) -> ((Float) -> Void)? {
        guard isOwner, let worktreePath = step.worktreePath else { return nil }
        let hostID = step.host.id
        return { [fontSizeStore] fontSize in
            preferredFontSize = fontSize
            fontSizeStore.setFontSize(
                fontSize,
                hostID: hostID,
                worktreePath: worktreePath
            )
        }
    }

    /// Wraps a control-bar action so that pressing any key while a
    /// terminal selection is active first cancels the selection
    /// (IOS-11.7). Terminal key entries in `terminalControlBar` route their
    /// action through this wrapper.
    private func controlBarAction(
        _ body: @escaping () -> Void,
        resetsInputContext: Bool = true,
        completionKey: AgentCompletionKey? = nil
    ) -> () -> Void {
        { [paneContainerBox] in
            paneContainerBox.view?.cancelPendingApplicationScroll()
            paneContainerBox.cancelActiveSelectionIfAny()
            if let completionKey, paneContainerBox.view?.handleAgentCompletionControl(completionKey) == true { return }
            if resetsInputContext { paneContainerBox.view?.terminalView.commitAndResetTextContext() }
            body()
        }
    }

    private func terminalTextControl(
        _ title: String,
        accessibilityLabel: String,
        completionKey: AgentCompletionKey? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: controlBarAction(action, completionKey: completionKey)) {
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

    private func terminalModifierControl(
        _ title: String,
        accessibilityLabel: String,
        activation: TerminalInputContainerView.StickyControlActivation,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: controlBarAction(action, resetsInputContext: false)) {
            Text(title)
                .font(.footnote.monospaced().weight(.semibold))
                .foregroundStyle(activation == .inactive ? Color.primary : Color.accentColor)
                .frame(minWidth: 44, minHeight: 34)
                .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(
                    activation == .inactive ? Color.clear : Color.accentColor,
                    lineWidth: activation == .locked ? 2 : 1
                )
        }
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(stickyControlAccessibilityValue(activation))
    }

    private func stickyControlAccessibilityValue(
        _ activation: TerminalInputContainerView.StickyControlActivation
    ) -> String {
        switch activation {
        case .inactive: "Off"
        case .armed: "On for next key"
        case .locked: "Locked"
        }
    }

    private func terminalIconControl(
        _ systemName: String,
        accessibilityLabel: String,
        completionKey: AgentCompletionKey? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: controlBarAction(action, completionKey: completionKey)) {
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

    private var terminalAutocorrectionControl: some View {
        // A preference change must preserve the current input context and
        // completion token, so it does not use the terminal-key action wrapper.
        Button { isAutocorrectionEnabled.toggle() } label: {
            Image(systemName: "textformat.abc")
                .font(.body.weight(.semibold))
                .foregroundStyle(isAutocorrectionEnabled ? Color.accentColor : Color.primary)
                .frame(width: 38, height: 34)
                .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(isAutocorrectionEnabled ? Color.accentColor : Color.clear, lineWidth: 2)
        }
        .accessibilityLabel("Auto-correct")
        .accessibilityValue(isAutocorrectionEnabled ? "On" : "Off")
        .accessibilityAddTraits(isAutocorrectionEnabled ? .isSelected : [])
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
