#if canImport(UIKit)
import GhosttyTerminal
import GrafttyCommandUI
import GrafttyProtocol
import SwiftUI
import UIKit

/// A SwiftUI wrapper around `UITerminalView` backed by an
/// `InMemoryTerminalSession` (no PTY — safe inside App Sandbox).
///
/// `pendingFocusRequests` is the number of not-yet-honored keyboard focus
/// requests; while it is positive the wrapped `UITerminalView` calls
/// `becomeFirstResponder` on each `updateUIView` and reports success via
/// `onFocusRequestsConsumed` so the counter owners can zero it. This lets
/// `SingleSessionView`'s "Show keyboard" button programmatically summon the
/// keyboard without the user having to tap the terminal itself. Passing a
/// pending delta (not a monotonic total) is what keeps a remounted pane —
/// whose fresh `Coordinator` has no memory — from replaying an old,
/// already-honored request and re-summoning a dismissed keyboard (IPAD-8.9).
public struct TerminalPaneView: UIViewRepresentable {
    public struct CommittedSoftwareInput {
        public let insertText: (String) -> Void
        public let insertControlByte: ((UInt8) -> Void)?
        public let deleteBackward: () -> Void

        public init(
            insertText: @escaping (String) -> Void,
            insertControlByte: ((UInt8) -> Void)? = nil,
            deleteBackward: @escaping () -> Void
        ) {
            self.insertText = insertText
            self.insertControlByte = insertControlByte
            self.deleteBackward = deleteBackward
        }
    }

    public struct HardwareKeyboardCommand {
        public let id: String
        public let title: String
        public let input: String
        public let modifierFlags: UIKeyModifierFlags
        public let perform: () -> Void

        public init(
            id: String,
            title: String,
            input: String,
            modifierFlags: UIKeyModifierFlags,
            perform: @escaping () -> Void
        ) {
            self.id = id
            self.title = title
            self.input = input
            self.modifierFlags = modifierFlags
            self.perform = perform
        }
    }

    public let session: InMemoryTerminalSession
    public let controller: TerminalController
    /// The leader's grid, from ownership or a paged checkpoint. The canvas preserves
    /// both dimensions while its presentation fits the available container.
    public let authoritativeGrid: SessionClient.GridSize?
    /// Keeps the first row below top chrome while the scroll viewport fills
    /// the pane. Preview tiles do not reserve interactive chrome space.
    public let reservesTopChromeSpace: Bool
    public let showsAdditionalHistory: Bool
    public let pendingFocusRequests: Int
    /// Fired once per successful keyboard focus so the owners of the
    /// focus-request counters can mark them consumed.
    public let onFocusRequestsConsumed: (() -> Void)?
    public let committedSoftwareInput: CommittedSoftwareInput?
    public let agentCompletion: AgentCompletionModel?
    public let isAutocorrectionEnabled: Bool
    public let hardwareKeyboardCommands: [HardwareKeyboardCommand]
    /// Governs how frequently `UITerminalView` repaints while no host output
    /// is arriving. `.full` (the default) matches display refresh; `.reduced`
    /// throttles idle repaints. Threaded straight through from
    /// `SessionClient.renderPace` at call sites that have a client.
    public let renderPace: TerminalRenderPace
    /// Invoked on any touch that begins on the terminal surface — local
    /// scrolling and selection render without new host output, so a finger
    /// on the surface must still promote the render pace back to `.full`.
    /// Call sites with a `SessionClient` wire this to `client.wakeRenderer()`.
    public let onUserInteraction: (() -> Void)?
    public let onApplicationScrollRequested: (() -> Void)?
    /// Effective config font used as the starting point for libghostty's
    /// built-in one-point pinch steps.
    public let configuredFontSize: Float?
    /// Present only while this pane owns the display. Follower presentation
    /// zoom must never become the saved worktree font preference.
    public let onFontSizeChange: ((Float) -> Void)?
    /// Forces the terminal view's color-scheme appearance, overriding the
    /// iOS system appearance. Use `.dark` or `.light` when the Ghostty
    /// config specifies an explicit single theme so that libghostty's
    /// `traitCollectionDidChange` → `setColorScheme()` path never
    /// substitutes a system-default theme over the user's choice.
    /// Pass `.unspecified` (the default) when the config uses a
    /// `light:X,dark:Y` pair and should adapt to system appearance.
    public let preferredInterfaceStyle: UIUserInterfaceStyle
    /// Invoked when the user taps **Paste** in the long-press menu.
    /// `RootView` wires this to read `UIPasteboard.general.string` and
    /// forward to `SessionClient.sendPaste(_:)`. (IOS-11.8)
    public let onPasteRequested: (() -> Void)?
    public let onBackRequested: (() -> Void)?
    /// Captures the live `TerminalInputContainerView` so the SwiftUI
    /// layer can call `cancelActiveSelectionIfAny()` from elsewhere
    /// (e.g., terminal control-bar buttons) per IOS-11.7.
    public let captureContainer: ((TerminalInputContainerView) -> Void)?
    public let retainedContainer: TerminalInputContainerView?
    /// Routes an explicit native or menu link activation to the owning pane.
    public let onOpenURL: ((URL) -> Void)?
    /// Change when the origin or owner changes to invalidate captured menu actions.
    public let linkContext: AnyHashable?

    public init(
        session: InMemoryTerminalSession,
        controller: TerminalController,
        authoritativeGrid: SessionClient.GridSize? = nil,
        reservesTopChromeSpace: Bool = false,
        showsAdditionalHistory: Bool = false,
        pendingFocusRequests: Int = 0,
        onFocusRequestsConsumed: (() -> Void)? = nil,
        committedSoftwareInput: CommittedSoftwareInput? = nil,
        agentCompletion: AgentCompletionModel? = nil,
        isAutocorrectionEnabled: Bool = false,
        hardwareKeyboardCommands: [HardwareKeyboardCommand] = [],
        renderPace: TerminalRenderPace = .full,
        onUserInteraction: (() -> Void)? = nil,
        onApplicationScrollRequested: (() -> Void)? = nil,
        configuredFontSize: Float? = nil,
        onFontSizeChange: ((Float) -> Void)? = nil,
        preferredInterfaceStyle: UIUserInterfaceStyle = .unspecified,
        onPasteRequested: (() -> Void)? = nil,
        onBackRequested: (() -> Void)? = nil,
        captureContainer: ((TerminalInputContainerView) -> Void)? = nil,
        retainedContainer: TerminalInputContainerView? = nil,
        onOpenURL: ((URL) -> Void)? = nil,
        linkContext: AnyHashable? = nil
    ) {
        self.session = session
        self.controller = controller
        self.authoritativeGrid = authoritativeGrid
        self.reservesTopChromeSpace = reservesTopChromeSpace
        self.showsAdditionalHistory = showsAdditionalHistory
        self.pendingFocusRequests = pendingFocusRequests
        self.onFocusRequestsConsumed = onFocusRequestsConsumed
        self.committedSoftwareInput = committedSoftwareInput
        self.agentCompletion = agentCompletion
        self.isAutocorrectionEnabled = isAutocorrectionEnabled
        self.hardwareKeyboardCommands = hardwareKeyboardCommands
        self.renderPace = renderPace
        self.onUserInteraction = onUserInteraction
        self.onApplicationScrollRequested = onApplicationScrollRequested
        self.configuredFontSize = configuredFontSize
        self.onFontSizeChange = onFontSizeChange
        self.preferredInterfaceStyle = preferredInterfaceStyle
        self.onPasteRequested = onPasteRequested
        self.onBackRequested = onBackRequested
        self.captureContainer = captureContainer
        self.retainedContainer = retainedContainer
        self.onOpenURL = onOpenURL
        self.linkContext = linkContext
    }

    public func makeCoordinator() -> Coordinator { Coordinator() }

    public final class Coordinator {
        let controlAttachmentID = UUID()
        /// Fired once per successful keyboard focus so the counter owners
        /// can zero the pending count. Consumption lives with the counters
        /// (not here) because this Coordinator dies with the representable
        /// while the counters survive remounts (IPAD-8.9).
        var onFocusRequestsConsumed: (() -> Void)?

        func applyFocusRequest(_ pendingRequests: Int, to view: TerminalInputContainerView) {
            guard pendingRequests > 0 else { return }
            DispatchQueue.main.async { [weak self, weak view] in
                guard let self, let view,
                      view.controlAttachmentID == self.controlAttachmentID else { return }
                if view.focusKeyboardInput() {
                    self.onFocusRequestsConsumed?()
                }
            }
        }
    }

    public func makeUIView(context: Context) -> TerminalInputContainerView {
        let view = retainedContainer ?? TerminalInputContainerView()
        view.controlAttachmentID = context.coordinator.controlAttachmentID
        view.overrideUserInterfaceStyle = preferredInterfaceStyle
        view.reservesTopChromeSpace = reservesTopChromeSpace
        view.authoritativeGrid = authoritativeGrid
        view.snapshotScrollView.showsAdditionalHistory = showsAdditionalHistory
        view.terminalView.controller = controller
        view.terminalView.configuration = TerminalSurfaceOptions(backend: .inMemory(session))
        view.agentCompletion = agentCompletion
        view.terminalView.isAutocorrectionEnabled = isAutocorrectionEnabled
        view.committedSoftwareInput = committedSoftwareInput
        view.hardwareKeyboardCommands = hardwareKeyboardCommands
        view.terminalView.renderPace = renderPace
        view.onUserInteraction = onUserInteraction
        view.onApplicationScrollRequested = onApplicationScrollRequested
        view.configureFontSizeObservation(
            initialFontSize: configuredFontSize,
            onChange: onFontSizeChange
        )
        view.onPasteRequested = onPasteRequested
        view.onBackRequested = onBackRequested
        view.openURL = onOpenURL ?? { _ in }
        view.linkContext = linkContext
        context.coordinator.onFocusRequestsConsumed = onFocusRequestsConsumed
        captureContainer?(view)
        context.coordinator.applyFocusRequest(pendingFocusRequests, to: view)
        return view
    }

    public func updateUIView(_ view: TerminalInputContainerView, context: Context) {
        // SwiftUI can update an outgoing representable after its retained
        // container has already been adopted by a replacement route.
        guard view.controlAttachmentID == context.coordinator.controlAttachmentID else { return }
        view.overrideUserInterfaceStyle = preferredInterfaceStyle
        view.reservesTopChromeSpace = reservesTopChromeSpace
        view.authoritativeGrid = authoritativeGrid
        view.snapshotScrollView.showsAdditionalHistory = showsAdditionalHistory
        view.terminalView.configuration = TerminalSurfaceOptions(backend: .inMemory(session))
        view.agentCompletion = agentCompletion
        view.terminalView.isAutocorrectionEnabled = isAutocorrectionEnabled
        view.committedSoftwareInput = committedSoftwareInput
        view.hardwareKeyboardCommands = hardwareKeyboardCommands
        view.terminalView.renderPace = renderPace
        view.onUserInteraction = onUserInteraction
        view.onApplicationScrollRequested = onApplicationScrollRequested
        view.configureFontSizeObservation(
            initialFontSize: configuredFontSize,
            onChange: onFontSizeChange
        )
        view.onPasteRequested = onPasteRequested
        view.onBackRequested = onBackRequested
        view.openURL = onOpenURL ?? { _ in }
        view.linkContext = linkContext
        context.coordinator.onFocusRequestsConsumed = onFocusRequestsConsumed
        context.coordinator.applyFocusRequest(pendingFocusRequests, to: view)
    }
}
#endif
