#if canImport(UIKit)
import GhosttyTerminal
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
        public let deleteBackward: () -> Void

        public init(
            insertText: @escaping (String) -> Void,
            deleteBackward: @escaping () -> Void
        ) {
            self.insertText = insertText
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
    public let pendingFocusRequests: Int
    /// Fired once per successful keyboard focus so the owners of the
    /// focus-request counters can mark them consumed.
    public let onFocusRequestsConsumed: (() -> Void)?
    public let committedSoftwareInput: CommittedSoftwareInput?
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
    /// Forces the terminal view's color-scheme appearance, overriding the
    /// iOS system appearance. Use `.dark` or `.light` when the Ghostty
    /// config specifies an explicit single theme so that libghostty's
    /// `traitCollectionDidChange` → `setColorScheme()` path never
    /// substitutes a system-default theme over the user's choice.
    /// Pass `.unspecified` (the default) when the config uses a
    /// `light:X,dark:Y` pair and should adapt to system appearance.
    public let preferredInterfaceStyle: UIUserInterfaceStyle
    /// Invoked when SwiftUI is about to remove this representable from
    /// the tree — typically because `renderActivity` flipped to `.idle`.
    /// Passes nil rather than rendering the live Metal-backed terminal
    /// layer during teardown.
    public let onWillUnmount: ((UIImage?) -> Void)?
    /// Invoked when the user taps **Paste** in the long-press menu.
    /// `RootView` wires this to read `UIPasteboard.general.string` and
    /// forward to `SessionClient.sendPaste(_:)`. (IOS-11.8)
    public let onPasteRequested: (() -> Void)?
    /// Captures the live `TerminalInputContainerView` so the SwiftUI
    /// layer can call `cancelActiveSelectionIfAny()` from elsewhere
    /// (e.g., terminal control-bar buttons) per IOS-11.7.
    public let captureContainer: ((TerminalInputContainerView) -> Void)?

    public init(
        session: InMemoryTerminalSession,
        controller: TerminalController,
        pendingFocusRequests: Int = 0,
        onFocusRequestsConsumed: (() -> Void)? = nil,
        committedSoftwareInput: CommittedSoftwareInput? = nil,
        hardwareKeyboardCommands: [HardwareKeyboardCommand] = [],
        renderPace: TerminalRenderPace = .full,
        onUserInteraction: (() -> Void)? = nil,
        preferredInterfaceStyle: UIUserInterfaceStyle = .unspecified,
        onWillUnmount: ((UIImage?) -> Void)? = nil,
        onPasteRequested: (() -> Void)? = nil,
        captureContainer: ((TerminalInputContainerView) -> Void)? = nil
    ) {
        self.session = session
        self.controller = controller
        self.pendingFocusRequests = pendingFocusRequests
        self.onFocusRequestsConsumed = onFocusRequestsConsumed
        self.committedSoftwareInput = committedSoftwareInput
        self.hardwareKeyboardCommands = hardwareKeyboardCommands
        self.renderPace = renderPace
        self.onUserInteraction = onUserInteraction
        self.preferredInterfaceStyle = preferredInterfaceStyle
        self.onWillUnmount = onWillUnmount
        self.onPasteRequested = onPasteRequested
        self.captureContainer = captureContainer
    }

    public func makeCoordinator() -> Coordinator { Coordinator() }

    public final class Coordinator {
        var onWillUnmount: ((UIImage?) -> Void)?
        /// Fired once per successful keyboard focus so the counter owners
        /// can zero the pending count. Consumption lives with the counters
        /// (not here) because this Coordinator dies with the representable
        /// while the counters survive remounts (IPAD-8.9).
        var onFocusRequestsConsumed: (() -> Void)?

        func applyFocusRequest(_ pendingRequests: Int, to view: TerminalInputContainerView) {
            guard pendingRequests > 0 else { return }
            DispatchQueue.main.async { [weak self, weak view] in
                guard let self, let view else { return }
                if view.focusKeyboardInput() {
                    self.onFocusRequestsConsumed?()
                }
            }
        }
    }

    public func makeUIView(context: Context) -> TerminalInputContainerView {
        let view = TerminalInputContainerView()
        view.overrideUserInterfaceStyle = preferredInterfaceStyle
        view.terminalView.controller = controller
        view.terminalView.configuration = TerminalSurfaceOptions(backend: .inMemory(session))
        view.committedSoftwareInput = committedSoftwareInput
        view.hardwareKeyboardCommands = hardwareKeyboardCommands
        view.terminalView.renderPace = renderPace
        view.onUserInteraction = onUserInteraction
        view.onPasteRequested = onPasteRequested
        context.coordinator.onWillUnmount = onWillUnmount
        context.coordinator.onFocusRequestsConsumed = onFocusRequestsConsumed
        captureContainer?(view)
        context.coordinator.applyFocusRequest(pendingFocusRequests, to: view)
        return view
    }

    public func updateUIView(_ view: TerminalInputContainerView, context: Context) {
        view.overrideUserInterfaceStyle = preferredInterfaceStyle
        view.terminalView.configuration = TerminalSurfaceOptions(backend: .inMemory(session))
        view.committedSoftwareInput = committedSoftwareInput
        view.hardwareKeyboardCommands = hardwareKeyboardCommands
        view.terminalView.renderPace = renderPace
        view.onUserInteraction = onUserInteraction
        view.onPasteRequested = onPasteRequested
        context.coordinator.onWillUnmount = onWillUnmount
        context.coordinator.onFocusRequestsConsumed = onFocusRequestsConsumed
        context.coordinator.applyFocusRequest(pendingFocusRequests, to: view)
    }

    public static func dismantleUIView(_: TerminalInputContainerView, coordinator: Coordinator) {
        guard let onWillUnmount = coordinator.onWillUnmount else { return }
        onWillUnmount(nil)
    }
}

public final class TerminalInputContainerView: UIView, TerminalSoftwareInputDelegate {
    private struct HardwareKeyboardCommandSignature: Equatable {
        let id: String
        let title: String
        let input: String
        let modifierFlags: UIKeyModifierFlags
    }

    let terminalView = UITerminalView(frame: .zero)
    private var isCommittedSoftwareInputEligible = false
    private var storedCommittedSoftwareInput: TerminalPaneView.CommittedSoftwareInput?
    var committedSoftwareInput: TerminalPaneView.CommittedSoftwareInput? {
        get { storedCommittedSoftwareInput }
        set {
            if let newValue {
                storedCommittedSoftwareInput = newValue
                isCommittedSoftwareInputEligible = true
                terminalView.isKeyboardInputEnabled = true
            } else {
                isCommittedSoftwareInputEligible = false
                terminalView.isKeyboardInputEnabled = false
                storedCommittedSoftwareInput = nil
            }
        }
    }
    private var storedHardwareKeyboardCommands: [TerminalPaneView.HardwareKeyboardCommand] = []
    private(set) var keyCommandUpdateRequestCountForTesting = 0
    private(set) lazy var selectionController = TerminalSelectionController(
        surface: RealSurfaceProxy(surfaceProvider: { [weak self] in self?.terminalView.surface })
    )

    /// Called when the user taps the Paste action in the long-press
    /// menu — the SwiftUI layer wires this to `SessionClient.sendPaste`.
    public var onPasteRequested: (() -> Void)?
    /// Called on any touch that begins on the terminal surface — powers
    /// render-pace promotion back to `.full` (local scrolling renders
    /// without host output, so a finger on the surface must count as
    /// activity). Wired by the SwiftUI layer to `SessionClient.wakeRenderer()`.
    public var onUserInteraction: (() -> Void)?
    public var hardwareKeyboardCommands: [TerminalPaneView.HardwareKeyboardCommand] {
        get { storedHardwareKeyboardCommands }
        set {
            let previousSignature = effectiveHardwareKeyboardCommandSignature
            storedHardwareKeyboardCommands = newValue
            guard previousSignature != effectiveHardwareKeyboardCommandSignature else { return }
            cachedKeyCommands = nil
            keyCommandUpdateRequestCountForTesting += 1
            UIMenuSystem.main.setNeedsRebuild()
        }
    }

    /// UIKit queries `keyCommands` on every hardware key-down (plus menu and
    /// discoverability-HUD builds), so the built array is cached and only
    /// invalidated when the command signature actually changes. Fired
    /// commands resolve their `perform` closure by id from
    /// `storedHardwareKeyboardCommands` at handle time (see
    /// `matchingHardwareKeyboardCommand`), so a signature-equal update never
    /// needs a rebuilt array.
    private var cachedKeyCommands: [UIKeyCommand]?

    override public var keyCommands: [UIKeyCommand]? {
        guard !hardwareKeyboardCommands.isEmpty else { return nil }
        if let cachedKeyCommands { return cachedKeyCommands }
        let commands = hardwareKeyboardCommands.map { command in
            let keyCommand = UIKeyCommand(
                title: command.title,
                image: nil,
                action: #selector(handleHardwareKeyboardCommand(_:)),
                input: command.input,
                modifierFlags: command.modifierFlags.appCommandModifiers,
                propertyList: command.id,
                alternates: [],
                discoverabilityTitle: command.title,
                attributes: [],
                state: .off
            )
            keyCommand.wantsPriorityOverSystemBehavior = true
            return keyCommand
        }
        cachedKeyCommands = commands
        return commands
    }

    private var effectiveHardwareKeyboardCommandSignature: [HardwareKeyboardCommandSignature] {
        hardwareKeyboardCommands.map {
            HardwareKeyboardCommandSignature(
                id: $0.id,
                title: $0.title,
                input: $0.input,
                modifierFlags: $0.modifierFlags.appCommandModifiers
            )
        }
    }

    private lazy var longPressMenu = UIEditMenuInteraction(delegate: self)
    private lazy var selectionMenu = UIEditMenuInteraction(delegate: self)

    private lazy var anyTouchObserver: AnyTouchObserverGestureRecognizer = {
        let r = AnyTouchObserverGestureRecognizer()
        r.cancelsTouchesInView = false
        r.onTouchBegan = { [weak self] in self?.onUserInteraction?() }
        return r
    }()

    private lazy var longPressRecognizer: UILongPressGestureRecognizer = {
        let r = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:)))
        r.minimumPressDuration = 0.45
        return r
    }()

    private lazy var selectionPanRecognizer: UIPanGestureRecognizer = {
        let r = UIPanGestureRecognizer(target: self, action: #selector(handleSelectionPan(_:)))
        r.isEnabled = false
        return r
    }()

    /// Captures the most-recent long-press location so the menu's
    /// `Select` action can word-select at the original touch point even
    /// after the gesture has ended. Updated on `.began`.
    private var lastLongPressPoint: CGPoint = .zero
    /// Paste and edit-menu dismissal are independent UIKit callbacks whose
    /// relative ordering is not part of our contract. Pair them by long-press
    /// menu generation and refocus only after both have happened.
    private var longPressMenuGeneration: UInt = 0
    private var pendingPasteRefocusGeneration: UInt?
    private var completedLongPressMenuDismissalGeneration: UInt?

    override public init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setup() {
        backgroundColor = .clear
        isOpaque = false

        terminalView.translatesAutoresizingMaskIntoConstraints = false
        terminalView.softwareInputDelegate = self
        terminalView.isKeyboardInputEnabled = false
        terminalView.showsInputAccessory = false
        addSubview(terminalView)
        NSLayoutConstraint.activate([
            terminalView.leadingAnchor.constraint(equalTo: leadingAnchor),
            terminalView.trailingAnchor.constraint(equalTo: trailingAnchor),
            terminalView.topAnchor.constraint(equalTo: topAnchor),
            terminalView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        configureTerminalPanRecognizersForIndirectScrolling()

        let tap = UITapGestureRecognizer(target: self, action: #selector(handleFocusKeyboardInputTap))
        tap.cancelsTouchesInView = false
        addGestureRecognizer(tap)

        addInteraction(longPressMenu)
        addInteraction(selectionMenu)
        addGestureRecognizer(longPressRecognizer)
        addGestureRecognizer(selectionPanRecognizer)
        addGestureRecognizer(anyTouchObserver)
    }

    private func configureTerminalPanRecognizersForIndirectScrolling() {
        terminalView.gestureRecognizers?
            .compactMap { $0 as? UIPanGestureRecognizer }
            .forEach { recognizer in
                recognizer.allowedScrollTypesMask = [.continuous, .discrete]
            }
    }

    @objc private func handleFocusKeyboardInputTap() {
        _ = focusKeyboardInput()
    }

    @discardableResult
    func focusKeyboardInput() -> Bool {
        terminalView.becomeFirstResponder()
    }

    /// @spec IOS-11.1: When the user long-presses a focused terminal pane, the application shall present a `UIEditMenuInteraction` menu at the touch point containing **Select**, **Select All**, and (when `UIPasteboard.general.hasStrings` is true at menu-build time) **Paste**.
    @objc private func handleLongPress(_ recognizer: UILongPressGestureRecognizer) {
        guard recognizer.state == .began else { return }
        let point = recognizer.location(in: self)
        lastLongPressPoint = point
        longPressMenuGeneration &+= 1
        pendingPasteRefocusGeneration = nil
        completedLongPressMenuDismissalGeneration = nil
        let config = UIEditMenuConfiguration(
            identifier: longPressMenuIdentifier(for: longPressMenuGeneration),
            sourcePoint: point
        )
        longPressMenu.presentEditMenu(with: config)
    }

    @objc private func handleSelectionPan(_ recognizer: UIPanGestureRecognizer) {
        guard selectionController.isActive else { return }
        let point = recognizer.location(in: self)
        switch recognizer.state {
        case .changed:
            selectionController.extend(to: point)
        case .ended, .cancelled, .failed:
            presentSelectionMenu(near: point)
        default: break
        }
    }

    /// Touch types masked pan recognizers may keep receiving while selection
    /// mode is active: indirect pointer only, so trackpad/mouse scrolling
    /// (IOS-6.17) stays live while finger drags belong to the selection pan.
    static let indirectPointerOnlyTouchTypes: [NSNumber] = [
        NSNumber(value: UITouch.TouchType.indirectPointer.rawValue)
    ]

    /// Masked pans whose `allowedTouchTypes` were narrowed on entering
    /// selection mode, with their prior values, so exit restores exactly
    /// what libghostty/setup installed.
    private var selectionModeSavedTouchTypes: [(UIPanGestureRecognizer, [NSNumber])] = []

    /// @spec IOS-11.4: While in selection mode, the application shall extend the live selection by forwarding pan-gesture positions to `surface.sendMousePos(...)`, and libghostty's built-in pan-to-scroll recognizers on the underlying `UITerminalView` shall stop receiving direct touches (indirect trackpad/mouse scrolling stays enabled) until selection mode exits.
    private func enterSelectionMode() {
        selectionPanRecognizer.isEnabled = true
        selectionModeSavedTouchTypes = []
        terminalView.gestureRecognizers?.forEach { recognizer in
            if let pan = recognizer as? UIPanGestureRecognizer,
               !pan.allowedScrollTypesMask.isEmpty {
                // A non-empty scroll mask only ADDS indirect scroll-event
                // recognition — the pan still recognizes finger drags, and
                // left enabled it would race the selection pan for them.
                // Narrow it to indirect touches instead of disabling it so
                // trackpad scrolling keeps working during selection.
                selectionModeSavedTouchTypes.append((pan, pan.allowedTouchTypes))
                pan.allowedTouchTypes = Self.indirectPointerOnlyTouchTypes
                return
            }
            recognizer.isEnabled = false
        }
    }

    private func exitSelectionMode() {
        selectionPanRecognizer.isEnabled = false
        for (pan, savedTouchTypes) in selectionModeSavedTouchTypes {
            pan.allowedTouchTypes = savedTouchTypes
        }
        selectionModeSavedTouchTypes = []
        terminalView.gestureRecognizers?.forEach { $0.isEnabled = true }
    }

    fileprivate func performSelectAtLongPressPoint() {
        selectionController.beginSelection(at: lastLongPressPoint)
        enterSelectionMode()
        presentSelectionMenu(near: lastLongPressPoint)
    }

    fileprivate func performSelectAll() {
        selectionController.selectAll()
        enterSelectionMode()
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        presentSelectionMenu(near: center)
    }

    fileprivate func performPaste(for menuGeneration: UInt) {
        onPasteRequested?()
        guard menuGeneration == longPressMenuGeneration else { return }
        pendingPasteRefocusGeneration = menuGeneration
        refocusKeyboardAfterEditMenuDismissalIfReady(for: menuGeneration)
    }

    fileprivate func performCopy() {
        _ = selectionController.copy(toPasteboard: UIPasteboard.general)
        exitSelectionMode()
    }

    fileprivate func performCancelSelection() {
        selectionController.cancel()
        exitSelectionMode()
    }

    /// Called by parent SwiftUI layer when a control-bar key is pressed,
    /// to satisfy IOS-11.7's "press a key while active" cancel path.
    public func cancelActiveSelectionIfAny() {
        guard selectionController.isActive else { return }
        performCancelSelection()
    }

    /// @spec IOS-11.5: When selection mode is active and the user lifts their finger after Select / Select All / extend, the application shall present a second `UIEditMenuInteraction` menu anchored near the selection rect containing **Copy** and **Cancel**.
    private func presentSelectionMenu(near point: CGPoint) {
        let config = UIEditMenuConfiguration(identifier: "selection" as AnyHashable, sourcePoint: point)
        selectionMenu.presentEditMenu(with: config)
    }

    // MARK: - Test seams

    /// Internal-visibility access for unit tests: terminal pan recognizers
    /// accept indirect pointer scroll input while selection gestures remain
    /// owned by `selectionPanRecognizer`.
    var terminalPanRecognizersAllowIndirectScrollingForTesting: Bool {
        let pans = terminalView.gestureRecognizers?.compactMap { $0 as? UIPanGestureRecognizer } ?? []
        return !pans.isEmpty && pans.allSatisfy {
            $0.allowedScrollTypesMask.contains(.continuous)
                && $0.allowedScrollTypesMask.contains(.discrete)
        }
    }

    /// Internal-visibility access for unit tests: invokes `enterSelectionMode`.
    func enterSelectionModeForTesting() {
        enterSelectionMode()
    }

    /// Internal-visibility access for unit tests: invokes `exitSelectionMode`.
    func exitSelectionModeForTesting() {
        exitSelectionMode()
    }

    /// Internal-visibility access for unit tests: invokes the paste menu
    /// action without presenting UIKit's edit menu.
    func performPasteForTesting() {
        performPaste(for: longPressMenuGeneration)
    }

    /// Internal-visibility access for unit tests: drives the real long-press
    /// edit-menu interaction's dismissal callback without presenting UIKit UI.
    func dismissLongPressMenuForTesting(animator: any UIEditMenuInteractionAnimating) {
        editMenuInteraction(
            longPressMenu,
            willDismissMenuFor: UIEditMenuConfiguration(
                identifier: longPressMenuIdentifier(for: longPressMenuGeneration),
                sourcePoint: .zero
            ),
            animator: animator
        )
    }

    /// Internal-visibility access for unit tests: proves the independent
    /// selection-menu interaction cannot consume a pending Paste refocus.
    func dismissSelectionMenuForTesting(animator: any UIEditMenuInteractionAnimating) {
        editMenuInteraction(
            selectionMenu,
            willDismissMenuFor: UIEditMenuConfiguration(
                identifier: "selection" as AnyHashable,
                sourcePoint: .zero
            ),
            animator: animator
        )
    }

    /// Internal-visibility access for unit tests: simulates the any-touch
    /// observer's `touchesBegan` callback without a real UIKit touch event.
    func simulateAnyTouchBeganForTesting() {
        onUserInteraction?()
    }

    private func refocusKeyboardAfterEditMenuDismissalIfReady(for generation: UInt) {
        guard pendingPasteRefocusGeneration == generation,
              completedLongPressMenuDismissalGeneration == generation
        else { return }
        pendingPasteRefocusGeneration = nil
        // Leave UIKit's dismissal-completion turn before asking its terminal
        // responder to focus, so any remaining internal cleanup runs first.
        DispatchQueue.main.async { [weak self] in
            guard let self,
                  self.longPressMenuGeneration == generation,
                  self.terminalView.canBecomeFirstResponder
            else { return }
            _ = self.focusKeyboardInput()
        }
    }

    private func longPressMenuIdentifier(for generation: UInt) -> AnyHashable {
        "long-press:\(generation)" as AnyHashable
    }

    public func terminalView(_: UITerminalView, insertText text: String) -> Bool {
        guard isCommittedSoftwareInputEligible else { return true }
        guard let insertText = storedCommittedSoftwareInput?.insertText else { return false }
        insertText(text)
        return true
    }

    public func terminalViewDeleteBackward(_: UITerminalView) -> Bool {
        guard isCommittedSoftwareInputEligible else { return true }
        guard let deleteBackward = storedCommittedSoftwareInput?.deleteBackward else { return false }
        deleteBackward()
        return true
    }

    override public func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(handleHardwareKeyboardCommand(_:)),
           let command = sender as? UIKeyCommand {
            return matchingHardwareKeyboardCommand(for: command) != nil
        }
        return super.canPerformAction(action, withSender: sender)
    }

    @objc private func handleHardwareKeyboardCommand(_ command: UIKeyCommand) {
        matchingHardwareKeyboardCommand(for: command)?.perform()
    }

    private func matchingHardwareKeyboardCommand(
        for keyCommand: UIKeyCommand
    ) -> TerminalPaneView.HardwareKeyboardCommand? {
        guard let commandID = keyCommand.propertyList as? String,
              let input = keyCommand.input else { return nil }
        let modifierFlags = keyCommand.modifierFlags.appCommandModifiers
        return hardwareKeyboardCommands.first {
            $0.id == commandID
                && $0.title == keyCommand.title
                && $0.input == input
                && $0.modifierFlags.appCommandModifiers == modifierFlags
        }
    }

    func performHardwareKeyboardCommandForTesting(input: String, modifierFlags: UIKeyModifierFlags) {
        let normalizedModifiers = modifierFlags.appCommandModifiers
        guard let command = hardwareKeyboardCommands.first(where: {
            $0.input == input
                && $0.modifierFlags.appCommandModifiers == normalizedModifiers
        }) else { return }
        handleHardwareKeyboardCommand(UIKeyCommand(
            title: command.title,
            image: nil,
            action: #selector(handleHardwareKeyboardCommand(_:)),
            input: command.input,
            modifierFlags: command.modifierFlags.appCommandModifiers,
            propertyList: command.id,
            alternates: [],
            discoverabilityTitle: command.title,
            attributes: [],
            state: .off
        ))
    }
}

/// Observes touch-begin without claiming the gesture: reports, then
/// immediately fails so libghostty's pan/pinch and the selection
/// recognizers proceed untouched. Powers render-pace promotion —
/// local scrolling renders without host output, so a finger on the
/// surface must count as activity.
final class AnyTouchObserverGestureRecognizer: UIGestureRecognizer {
    var onTouchBegan: (() -> Void)?

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        onTouchBegan?()
        state = .failed
    }
}

private extension UIKeyModifierFlags {
    var appCommandModifiers: UIKeyModifierFlags {
        intersection([.shift, .control, .alternate, .command])
    }
}

extension TerminalInputContainerView: UIEditMenuInteractionDelegate {
    public func editMenuInteraction(
        _ interaction: UIEditMenuInteraction,
        menuFor configuration: UIEditMenuConfiguration,
        suggestedActions: [UIMenuElement]
    ) -> UIMenu? {
        if interaction === longPressMenu {
            guard configuration.identifier == longPressMenuIdentifier(for: longPressMenuGeneration)
            else { return nil }
            return longPressUIMenu(for: longPressMenuGeneration)
        }
        return selectionUIMenu()
    }

    public func editMenuInteraction(
        _ interaction: UIEditMenuInteraction,
        willDismissMenuFor configuration: UIEditMenuConfiguration,
        animator: any UIEditMenuInteractionAnimating
    ) {
        guard interaction === longPressMenu,
              configuration.identifier == longPressMenuIdentifier(for: longPressMenuGeneration)
        else { return }
        let generation = longPressMenuGeneration
        animator.addCompletion { [weak self] in
            guard let self, self.longPressMenuGeneration == generation else { return }
            self.completedLongPressMenuDismissalGeneration = generation
            self.refocusKeyboardAfterEditMenuDismissalIfReady(for: generation)
        }
    }

    private func longPressUIMenu(for generation: UInt) -> UIMenu {
        var children: [UIMenuElement] = [
            UIAction(title: "Select") { [weak self] _ in self?.performSelectAtLongPressPoint() },
            UIAction(title: "Select All") { [weak self] _ in self?.performSelectAll() },
        ]
        if UIPasteboard.general.hasStrings {
            children.append(UIAction(title: "Paste") { [weak self] _ in
                self?.performPaste(for: generation)
            })
        }
        return UIMenu(children: children)
    }

    private func selectionUIMenu() -> UIMenu {
        UIMenu(children: [
            UIAction(title: "Copy") { [weak self] _ in self?.performCopy() },
            UIAction(title: "Cancel", attributes: .destructive) { [weak self] _ in
                self?.performCancelSelection()
            },
        ])
    }
}

#endif
