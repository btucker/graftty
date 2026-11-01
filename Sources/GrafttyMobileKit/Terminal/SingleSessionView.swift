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
    private let parentPaneFocused: Bool
    private var isPaneFocused: Bool { parentPaneFocused && !terminalSheet.isPresented }
    private let isTerminalSheet: Bool
    @State private var terminalSheet = CompactTerminalPresentation()
    @State private var terminalSheetWorktree: WorktreePanes?
    /// IPAD-2.26: contained routes keep the home-indicator inset, so their
    /// keyboard padding subtracts the gap between the window bottom and the
    /// content bottom. A safe-area inset alone would include the keyboard.
    @State private var windowBottom: CGFloat = 0
    @State private var containedContentBottom: CGFloat = 0
    private var containerBottomInset: CGFloat { max(0, windowBottom - containedContentBottom) }
    private var isCompactShellRoute: Bool { compactWorkspace != nil && sessionAgent == nil }
    /// Embedded panes let their shared multi-pane parent manage the keyboard
    /// inset once for the whole split tree.
    let isEmbeddedPane: Bool
    private let embeddedPaneHeader: AnyView?
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
    @State private var connectedAssignment: String?
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
    @State private var retainedAttachmentID = UUID()
    @StateObject private var agentCompletion = AgentCompletionModel()
    @State private var stickyControlActivation:
        TerminalInputContainerView.StickyControlActivation = .inactive
    @State private var isTrayShiftSelected = false
    @State private var scrollbackMapModel: ScrollbackMapModel?
    /// The floating top-right controls' height, so the scrollback map sits below them.
    @State private var floatingControlsHeight: CGFloat = 44
    @AppStorage(autocorrectionDefaultsKey) private var isAutocorrectionEnabled = false
    /// The iOS-scaled Mac ghostty config used to build `controller`.
    /// Cached so owner-selected font preferences can be applied without re-fetching.
    @State private var baseConfigText: String?
    /// Terminal theme, parsed from the Mac-resolved ghostty config.
    /// Painted behind the whole session so the control-bar row and the strip
    /// revealed during keyboard transitions match the terminal's background
    /// instead of showing system chrome. The Mac resolves themes / named /
    /// palette colors to hex before sending the config, so this matches what
    /// libghostty actually renders. Falls back to the shared default. Parsed
    /// once when `baseConfigText` is assigned rather than on every body.
    @State private var terminalTheme = GhosttyThemeColors.fallback
    /// Latest owner-selected size. Pinch actions already update the live
    /// Ghostty surface; this state preserves that size across configuration updates.
    @State private var preferredFontSize: Float?
    @State private var terminalBrowserRequest: TerminalBrowserRequest?
    @State private var terminalBrowserError: String?

    private var keyboardBottomInset: CGFloat {
        if terminalSheet.isPresented { return 0 }
        if isEmbeddedPane, let multiPaneKeyboardFrame { return multiPaneKeyboardFrame.bottomInset }
        return observedKeyboardBottomInset
    }

    private var isKeyboardVisible: Bool { keyboardBottomInset > 0 }

    /// IPAD-1.18: fullscreen controls navigation chrome, not display
    /// ownership, so Take Control depends only on the client.
    static func shouldShowTakeControl(clientCanTakeControl: Bool) -> Bool {
        clientCanTakeControl
    }

    /// IOS-6.13: keyboard chrome appears only for the display owner.
    static func shouldExposeKeyboard(clientIsOwner: Bool) -> Bool {
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
        embeddedPaneHeader: AnyView? = nil,
        isTerminalSheet: Bool = false,
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
        self.parentPaneFocused = isPaneFocused
        self.isTerminalSheet = isTerminalSheet
        self.isEmbeddedPane = isEmbeddedPane
        self.embeddedPaneHeader = embeddedPaneHeader
        self.onPaneInteraction = onPaneInteraction
        self.onBackToWorktrees = onBackToWorktrees
        self.fontSizeStore = fontSizeStore
        self.sidebarNavigation = sidebarNavigation
        self.retainedPanes = retainedPanes
        self.remoteConnectionProvider = remoteConnectionProvider
        self.previewManagementTransport = previewManagementTransport
        self._attentionWorktrees = State(initialValue: attentionWorktrees)
        self._terminalSheetWorktree = State(initialValue: attentionWorktrees.first { $0.path == step.worktreePath })
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
        // IPAD-2.26: explicit padding is the only keyboard avoidance. Without
        // this, SwiftUI also avoids the keyboard and the UIKit terminal
        // expands back into the keyboard safe area.
        .ignoresSafeArea(.keyboard, edges: isTerminalSheet || compactWorkspace != nil ? .bottom : [])
        .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).maxY + $0.safeAreaInsets.bottom } action: { windowBottom = $0 }
        .modifier(MobileWorktreeContextDrawer(context: worktreeContext, theme: terminalTheme, onShowAgent: { id in
            guard let session = compactWorkspace?.agents?.first(where: { $0.id == id })?.presentationSessionName else { return }
            selectWorkspaceSession(session)
        }))
        .task(id: isCompactShellRoute) {
            guard isCompactShellRoute, let workspace = compactWorkspace else { return }
            terminalSheetWorktree = workspace
            terminalSheet.select(step.sessionName, in: workspace)
            await terminalSheet.open(in: workspace, create: createCompactTerminal)
        }
        .sheet(isPresented: $terminalSheet.isPresented) {
            if let workspace = compactWorkspace ?? terminalSheetWorktree {
                CompactTerminalSheet(worktree: workspace, presentation: terminalSheet, create: createCompactTerminal, theme: terminalTheme) { session in
                    SingleSessionView(step: SessionStep(host: step.host, worktreePath: step.worktreePath,
                        sessionName: session, title: workspace.layout?.title(for: session) ?? "Terminal", worktreeProject: step.worktreeProject),
                        navigationPath: .constant(NavigationPath()), isFullScreen: false, isTerminalSheet: true,
                        onBackToWorktrees: { terminalSheet.isPresented = false }, fontSizeStore: fontSizeStore, retainedPanes: retainedPanes,
                        attentionWorktrees: attentionWorktrees, remoteConnectionProvider: remoteConnectionProvider)
                }
            }
        }
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
        retainedPanes?.detach(retainedPaneKey, owner: retainedAttachmentID)
        client = nil
        if connection != .ended { connection = .connecting }
    }

    private var worktreeContext: SidebarWorktreeContext? {
        isEmbeddedPane ? nil : paneWorktreeContext
    }

    private var paneWorktreeContext: SidebarWorktreeContext? {
        guard let row = attentionWorktrees.first(where: {
            if let path = step.worktreePath { return $0.path == path }
            return $0.layout?.leaves.contains(where: { $0.sessionName == step.sessionName }) == true
        }) else { return nil }
        return sidebarNavigation?.worktreeContext(row) ?? SidebarWorktreeContext(worktree: row)
    }

    /// The timeline the scrollback map marks, while this focused pane is its worktree's agent pane.
    private var agentScrollbackTimeline: WorktreeTimeline? {
        guard isPaneFocused, let context = paneWorktreeContext, context.agentPaneID == step.sessionName else { return nil }
        return WorktreeTimeline(context)
    }

    private var compactWorkspace: WorktreePanes? {
        guard isFullScreen else { return nil }
        return CompactTerminalPresentation.agentWorkspace(path: step.worktreePath, rows: attentionWorktrees, fallback: terminalSheetWorktree)
    }
    private var sessionAgent: AgentSessionInfo? {
        (attentionWorktrees.first { $0.path == step.worktreePath } ?? terminalSheetWorktree)?.agents?.first {
            $0.presentationSessionName == step.sessionName
        }
    }
    private var completedAgent: AgentSessionInfo? { sessionAgent.flatMap { $0.isCompleted ? $0 : nil } }

    private var compactAgentKey: String { "workspace.iphone.agent.\(step.host.id).\(step.worktreePath ?? "")" }
    private func selectWorkspaceSession(_ target: String) {
        guard target != step.sessionName, let workspace = compactWorkspace,
              workspace.layout?.leaves.contains(where: { $0.sessionName == target }) == true
                || workspace.agents?.contains(where: { $0.presentationSessionName == target }) == true else { return }
        if workspace.agents?.contains(where: { $0.sessionName == step.sessionName }) == true {
            UserDefaults.standard.set(step.sessionName, forKey: compactAgentKey)
        }
        let destination = SessionStep(host: step.host, worktreePath: step.worktreePath, sessionName: target,
            title: workspace.agents?.first { $0.presentationSessionName == target }?.name ?? workspace.layout?.title(for: target) ?? "Terminal",
            worktreeProject: step.worktreeProject)
        if !navigationPath.isEmpty { navigationPath.removeLast() }
        navigationPath.append(destination)
    }

    private func openCompactTerminal(in workspace: WorktreePanes) {
        terminalSheetWorktree = workspace
        Task { await terminalSheet.open(in: workspace, create: createCompactTerminal) }
    }

    private func createCompactTerminal() async throws -> String? {
        guard let coordinator, let workspace = compactWorkspace else {
            throw CompactTerminalError.unavailable
        }
        if let target = workspace.layout?.leaves.first?.sessionName {
            let environment = await buildPaneEnvironment(remoteHost: coordinator.connection(for: step.host))
            guard let control = environment.paneControlClient else { throw CompactTerminalError.unavailable }
            do {
                let response = try await control.split(target: target, direction: .down)
                await environment.close()
                switch response {
                case .splitCreated(let session): return session
                case .error(_, let message): throw CompactTerminalError.host(message)
                case .ok: return nil // Legacy host: select its pushed shell inventory.
                }
            } catch {
                await environment.close()
                throw error
            }
        }
        let response = try await coordinator.sendWorktreeManagement(.open(worktreeID: workspace.path), to: step.host)
        if case .error(_, let message, _, _) = response { throw CompactTerminalError.host(message) }
        if case .created(_, let session) = response { return session }
        return nil
    }

    private enum CompactTerminalError: LocalizedError {
        case unavailable, host(String)
        var errorDescription: String? {
            switch self {
            case .unavailable: "Connect to the host to open a terminal."
            case .host(let message): message
            }
        }
    }

    @ViewBuilder
    private var terminalBackground: some View {
        if isFullScreen {
            terminalTheme.background.ignoresSafeArea()
        } else {
            terminalTheme.background
        }
    }

    private var sessionView: some View {
        VStack(spacing: 0) {
            if isEmbeddedPane, embeddedPaneHeader != nil || (step.worktreePath != nil && coordinator != nil) {
                HStack(spacing: 0) {
                    if let embeddedPaneHeader { embeddedPaneHeader }
                    else { Spacer(minLength: 0) }
                    remoteOpenControls
                }
                .frame(minHeight: 44)
                .background(terminalTheme.background)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("workspace.pane.header")
            }
            if let workspace = compactWorkspace {
                Text(workspace.displayName).font(.subheadline).lineLimit(1).foregroundStyle(terminalTheme.foreground)
                    .frame(maxWidth: .infinity).padding(.leading, 68).padding(.trailing, 120).frame(height: 64)
                CompactAgentBar(worktree: workspace, session: step.sessionName, onSelect: selectWorkspaceSession, attentionContext: worktreeContext, hostID: step.host.id, host: step.host, theme: terminalTheme)
            }
            if isCompactShellRoute {
                ContentUnavailableView("Select an agent", systemImage: "terminal",
                    description: Text("Choose an agent above, or open Terminal from the top-right controls."))
                    .foregroundStyle(terminalTheme.foreground)
            } else if let agent = completedAgent, let path = step.worktreePath {
                VStack(spacing: 0) {
                    MobileAgentConversationView(host: step.host, worktreePath: path, agent: agent)

                }
            } else {
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
        }
        // IOS-6.9: explicit bottom padding lifts the terminal above
        // the keyboard. SwiftUI's automatic `.keyboard` safe-area
        // avoidance is unreliable when UITerminalView is the focused
        // responder, so we drive it ourselves.
        .padding(.bottom, isEmbeddedPane ? 0 : max(0, keyboardBottomInset - ((isTerminalSheet || compactWorkspace != nil) ? containerBottomInset : 0)))
        // Fullscreen terminals reach the screen edges. Embedded terminals
        // respect the workspace's header and safe-area boundaries.
        .modifier(FullScreenChrome(enabled: isFullScreen, contained: isEmbeddedPane || isTerminalSheet || compactWorkspace != nil))
        .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).maxY } action: { containedContentBottom = $0 }
            .overlay(alignment: .topLeading) {
                if isFullScreen {
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
                        // Clear the compact workspace's title and agent bar.
                        .padding(.top, compactWorkspace == nil ? 64 : 116)
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
                if !isEmbeddedPane {
                    remoteOpenControls
                        .modifier(TerminalFloatingControlPlacement())
                        .padding(.trailing, 12)
                }
            }
            .overlay(alignment: .topTrailing) {
                if let model = scrollbackMapModel, let timeline = agentScrollbackTimeline {
                    // CONTEXT-37: below the floating controls, which hold Worktree context.
                    let controlsHeight = step.worktreePath != nil && coordinator != nil ? floatingControlsHeight : 0
                    ScrollbackMapOverlayHost(model: model, timeline: timeline,
                                             isVisible: scenePhase == .active && connection == .live)
                        .padding(.top, ScrollbackMapLayout.topInset(belowControlsAt: 12, controlsHeight: controlsHeight))
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
            .task(id: ConversationDialKey(dial: dialKey, completionID: isCompactShellRoute ? "shell-in-sheet" : completedAgent?.completionID, assignmentID: sessionAgent?.assignmentID)) {
                if let assignment = sessionAgent?.assignmentID, assignment != connectedAssignment {
                    let replaced = completedAgent == nil && RetainedMobilePane.discardPreviousAssignment(
                        from: retainedPanes, key: retainedPaneKey, assignmentID: assignment)
                    if completedAgent == nil && (replaced || connectedAssignment != nil || connection == .ended) {
                        detachSession()
                        retainedPanes?.remove(retainedPaneKey)
                        connection = .connecting
                    }
                    connectedAssignment = assignment
                }
                if completedAgent == nil && !isCompactShellRoute { await driveConnection() }
                else { detachSession() }
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
                    terminalTheme = GhosttyThemeColors(parsingConfigText: text)
                    preferredFontSize = GhosttyConfigFetcher.lastFontSize(in: text)
                        .map(Float.init)
                }
            }
            .task(id: AttentionObservationKey(dial: dialKey, focused: parentPaneFocused)) { await observeAttention() }
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

    private struct ConversationDialKey: Hashable {
        let dial: DialKey
        let completionID: String?
        let assignmentID: String?
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
                client?.stop(); client = nil
                await verifyThenOpen()
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
            retainedPanes.attach(retainedPaneKey, owner: retainedAttachmentID)
            new = retainedPanes.acquire(retainedPaneKey) { RetainedMobilePane(client: makeClient(), assignmentID: sessionAgent?.assignmentID) }.client
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
        guard isFullScreen, parentPaneFocused, let coordinator,
              LiveSessionReadiness.isActive(scene: scenePhase, gateUnlocked: gate.isUnlocked) else { return }
        for await update in coordinator.worktreeUpdates(for: step.host) {
            // An update already handed over when SwiftUI cancelled this task
            // belongs to an observation that has ended.
            guard !Task.isCancelled else { return }
            switch update {
            case .unavailable:
                // Do not present a stale count while the host is unreachable.
                attentionWorktrees = []
            case let .frame(.snapshot(rows, metadata)):
                let projects = metadata?.projects ?? SidebarProjection.projects(rows)
                sidebarNavigation?.reconcile(worktrees: rows, projects: projects)
                recentPaneActions?.history.reconcile(hostID: step.host.id, worktrees: rows, projects: projects)
                attentionWorktrees = rows
                if let current = rows.first(where: { $0.path == step.worktreePath }) { terminalSheetWorktree = current }
                recordRecentVisit()
            }
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
            Self.shouldShowTakeControl(clientCanTakeControl: $0.canTakeControl)
        } ?? false
        let shouldExposeKeyboard = client.map {
            Self.shouldExposeKeyboard(clientIsOwner: $0.isOwner)
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

    @ViewBuilder
    private var remoteOpenControls: some View {
        if !isTerminalSheet, let worktree = step.worktreePath, let coordinator {
            RemoteOpenButton(host: step.host, worktree: worktree, coordinator: coordinator,
                sessionName: step.sessionName,
                ownerDeviceID: client?.isOwner == true ? coordinator.localDeviceID : nil,
                isActive: isPaneFocused && scenePhase == .active && gate?.state == .unlocked && connection == .live,
                managementTransport: previewManagementTransport,
                browserConnectionReady: connection == .live,
                isPaneFocused: isPaneFocused,
                hasOwnershipSnapshot: client?.ownershipSnapshot != nil,
                onOpenTerminal: compactWorkspace.map { workspace in { openCompactTerminal(in: workspace) } },
                isPaneOwner: { client?.isOwner == true },
                canPresentAuthentication: { true },
                terminalRequest: $terminalBrowserRequest)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { floatingControlsHeight = $0 }
                .fixedSize(horizontal: isEmbeddedPane, vertical: isEmbeddedPane)
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
            reservesTopChromeSpace: !isEmbeddedPane && !isTerminalSheet && compactWorkspace == nil,
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
                MobileTerminalRegistry.shared.register(view, sessionName: client.sessionName)
                let mapModel = view.scrollbackMapModel
                DispatchQueue.main.async { if scrollbackMapModel !== mapModel { scrollbackMapModel = mapModel } }
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

/// Fullscreen routes fill the screen. Contained routes, including embedded
/// iPad panes, respect the header and safe-area bounds supplied by their parent.
private struct FullScreenChrome: ViewModifier {
    let enabled: Bool
    var contained = false

    func body(content: Content) -> some View {
        if contained { content.ignoresSafeArea(.keyboard).toolbar(enabled ? .hidden : .automatic, for: .navigationBar) }
        else if enabled {
            content
                .ignoresSafeArea()
                .toolbar(.hidden, for: .navigationBar)
        } else {
            content
                // Standalone regular-width routes keep their edge-to-edge
                // presentation; embedded workspaces use the contained branch.
                .ignoresSafeArea(.container, edges: [.top, .bottom])
                .toolbarBackground(.hidden, for: .navigationBar)
        }
    }
}
#endif
