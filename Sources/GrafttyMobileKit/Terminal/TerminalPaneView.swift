#if canImport(UIKit)
import GhosttyTerminal
import ObjectiveC
import SwiftUI
import UIKit

/// A SwiftUI wrapper around `UITerminalView` backed by an
/// `InMemoryTerminalSession` (no PTY — safe inside App Sandbox).
///
/// `focusRequestCount` is a monotonically-increasing counter; incrementing
/// it causes the wrapped `UITerminalView` to call `becomeFirstResponder`
/// on the next `updateUIView`. This lets `SingleSessionView`'s
/// "Show keyboard" button programmatically summon the keyboard without
/// the user having to tap the terminal itself.
public struct TerminalPaneView: UIViewRepresentable {
    public struct SoftwareKeyboardInput {
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
    public let focusRequestCount: Int
    public let softwareKeyboardInput: SoftwareKeyboardInput?
    public let hardwareKeyboardCommands: [HardwareKeyboardCommand]
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
        focusRequestCount: Int = 0,
        softwareKeyboardInput: SoftwareKeyboardInput? = nil,
        hardwareKeyboardCommands: [HardwareKeyboardCommand] = [],
        preferredInterfaceStyle: UIUserInterfaceStyle = .unspecified,
        onWillUnmount: ((UIImage?) -> Void)? = nil,
        onPasteRequested: (() -> Void)? = nil,
        captureContainer: ((TerminalInputContainerView) -> Void)? = nil
    ) {
        self.session = session
        self.controller = controller
        self.focusRequestCount = focusRequestCount
        self.softwareKeyboardInput = softwareKeyboardInput
        self.hardwareKeyboardCommands = hardwareKeyboardCommands
        self.preferredInterfaceStyle = preferredInterfaceStyle
        self.onWillUnmount = onWillUnmount
        self.onPasteRequested = onPasteRequested
        self.captureContainer = captureContainer
    }

    public func makeCoordinator() -> Coordinator { Coordinator() }

    public final class Coordinator {
        var lastFocusRequest: Int = 0
        var onWillUnmount: ((UIImage?) -> Void)?

        func applyFocusRequest(_ focusRequestCount: Int, to view: TerminalInputContainerView) {
            guard lastFocusRequest != focusRequestCount else { return }
            DispatchQueue.main.async { [weak self, weak view] in
                guard let self, let view else { return }
                if view.focusKeyboardInput() {
                    self.lastFocusRequest = focusRequestCount
                }
            }
        }
    }

    public func makeUIView(context: Context) -> TerminalInputContainerView {
        let view = TerminalInputContainerView()
        view.overrideUserInterfaceStyle = preferredInterfaceStyle
        view.terminalView.controller = controller
        view.terminalView.configuration = TerminalSurfaceOptions(backend: .inMemory(session))
        view.inputProxy.softwareKeyboardInputEnabled = softwareKeyboardInput != nil
        view.inputProxy.insertTextHandler = softwareKeyboardInput?.insertText
        view.inputProxy.deleteBackwardHandler = softwareKeyboardInput?.deleteBackward
        view.hardwareKeyboardCommands = hardwareKeyboardCommands
        view.onPasteRequested = onPasteRequested
        context.coordinator.onWillUnmount = onWillUnmount
        captureContainer?(view)
        context.coordinator.applyFocusRequest(focusRequestCount, to: view)
        return view
    }

    public func updateUIView(_ view: TerminalInputContainerView, context: Context) {
        view.overrideUserInterfaceStyle = preferredInterfaceStyle
        view.terminalView.configuration = TerminalSurfaceOptions(backend: .inMemory(session))
        view.inputProxy.softwareKeyboardInputEnabled = softwareKeyboardInput != nil
        view.inputProxy.insertTextHandler = softwareKeyboardInput?.insertText
        view.inputProxy.deleteBackwardHandler = softwareKeyboardInput?.deleteBackward
        view.hardwareKeyboardCommands = hardwareKeyboardCommands
        view.onPasteRequested = onPasteRequested
        context.coordinator.onWillUnmount = onWillUnmount
        context.coordinator.applyFocusRequest(focusRequestCount, to: view)
    }

    public static func dismantleUIView(_: TerminalInputContainerView, coordinator: Coordinator) {
        guard let onWillUnmount = coordinator.onWillUnmount else { return }
        onWillUnmount(nil)
    }
}

public final class TerminalInputContainerView: UIView {
    let terminalView = UITerminalView(frame: .zero)
    let inputProxy = TerminalSoftwareKeyboardProxyView(frame: .zero)
    private(set) lazy var selectionController = TerminalSelectionController(
        surface: RealSurfaceProxy(surfaceProvider: { [weak self] in self?.terminalView.surface })
    )

    /// Called when the user taps the Paste action in the long-press
    /// menu — the SwiftUI layer wires this to `SessionClient.sendPaste`.
    public var onPasteRequested: (() -> Void)?
    public var hardwareKeyboardCommands: [TerminalPaneView.HardwareKeyboardCommand] {
        get { inputProxy.hardwareKeyboardCommands }
        set { inputProxy.hardwareKeyboardCommands = newValue }
    }

    private lazy var longPressMenu = UIEditMenuInteraction(delegate: self)
    private lazy var selectionMenu = UIEditMenuInteraction(delegate: self)

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
    private(set) var keyboardRefocusRequestCountForTesting = 0

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
        addSubview(terminalView)
        NSLayoutConstraint.activate([
            terminalView.leadingAnchor.constraint(equalTo: leadingAnchor),
            terminalView.trailingAnchor.constraint(equalTo: trailingAnchor),
            terminalView.topAnchor.constraint(equalTo: topAnchor),
            terminalView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        inputProxy.translatesAutoresizingMaskIntoConstraints = false
        inputProxy.backgroundColor = .clear
        inputProxy.isOpaque = false
        addSubview(inputProxy)
        NSLayoutConstraint.activate([
            inputProxy.leadingAnchor.constraint(equalTo: leadingAnchor),
            inputProxy.trailingAnchor.constraint(equalTo: trailingAnchor),
            inputProxy.topAnchor.constraint(equalTo: topAnchor),
            inputProxy.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        configureTerminalPanRecognizersForIndirectScrolling()

        let tap = UITapGestureRecognizer(target: self, action: #selector(handleFocusKeyboardInputTap))
        tap.cancelsTouchesInView = false
        addGestureRecognizer(tap)

        addInteraction(longPressMenu)
        addInteraction(selectionMenu)
        addGestureRecognizer(longPressRecognizer)
        addGestureRecognizer(selectionPanRecognizer)
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
        inputProxy.becomeFirstResponder()
    }

    /// @spec IOS-11.1: When the user long-presses a focused terminal pane, the application shall present a `UIEditMenuInteraction` menu at the touch point containing **Select**, **Select All**, and (when `UIPasteboard.general.hasStrings` is true at menu-build time) **Paste**.
    @objc private func handleLongPress(_ recognizer: UILongPressGestureRecognizer) {
        guard recognizer.state == .began else { return }
        let point = recognizer.location(in: self)
        lastLongPressPoint = point
        let config = UIEditMenuConfiguration(identifier: nil, sourcePoint: point)
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

    /// @spec IOS-11.4: While in selection mode, the application shall extend the live selection by forwarding pan-gesture positions to `surface.sendMousePos(...)`, and libghostty's built-in pan-to-scroll recognizer on the underlying `UITerminalView` shall be disabled until selection mode exits.
    private func enterSelectionMode() {
        selectionPanRecognizer.isEnabled = true
        terminalView.gestureRecognizers?.forEach { recognizer in
            if let pan = recognizer as? UIPanGestureRecognizer,
               !pan.allowedScrollTypesMask.isEmpty {
                return
            }
            recognizer.isEnabled = false
        }
    }

    private func exitSelectionMode() {
        selectionPanRecognizer.isEnabled = false
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

    fileprivate func performPaste() {
        onPasteRequested?()
        refocusKeyboardAfterEditMenuAction()
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

    /// Internal-visibility access for unit tests: Task 6 removed terminal
    /// gesture-driven ownership claims. Long-press presents edit menus and
    /// pinch belongs to libghostty's local zoom handling, not takeover.
    var hasOwnershipClaimGestureHookForTesting: Bool {
        false
    }

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

    /// Internal-visibility access for unit tests: synthesized pinch gestures
    /// are ownership-neutral.
    func simulatePinchForTesting(state: UIGestureRecognizer.State, scale: CGFloat) {
    }

    /// Internal-visibility access for unit tests: simulates the
    /// long-press handler's `.began` branch without presenting UIKit UI.
    func simulateLongPressBeganForTesting() {
    }

    /// Internal-visibility access for unit tests: invokes the paste menu
    /// action without presenting UIKit's edit menu.
    func performPasteForTesting() {
        performPaste()
    }

    private func refocusKeyboardAfterEditMenuAction() {
        guard inputProxy.canBecomeFirstResponder else { return }
        keyboardRefocusRequestCountForTesting += 1
        DispatchQueue.main.async { [weak self] in
            self?.focusKeyboardInput()
        }
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
            return longPressUIMenu()
        }
        return selectionUIMenu()
    }

    private func longPressUIMenu() -> UIMenu {
        var children: [UIMenuElement] = [
            UIAction(title: "Select") { [weak self] _ in self?.performSelectAtLongPressPoint() },
            UIAction(title: "Select All") { [weak self] _ in self?.performSelectAll() },
        ]
        if UIPasteboard.general.hasStrings {
            children.append(UIAction(title: "Paste") { [weak self] _ in self?.performPaste() })
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

final class TerminalSoftwareKeyboardProxyView: UIView, UIKeyInput, UITextInputTraits {
    private struct HardwareKeyboardCommandSignature: Equatable {
        let id: String
        let title: String
        let input: String
        let modifierFlags: UIKeyModifierFlags
    }

    var softwareKeyboardInputEnabled = false
    var insertTextHandler: ((String) -> Void)?
    var deleteBackwardHandler: (() -> Void)?
    private var storedHardwareKeyboardCommands: [TerminalPaneView.HardwareKeyboardCommand] = []
    private(set) var keyCommandUpdateRequestCountForTesting = 0

    var hardwareKeyboardCommands: [TerminalPaneView.HardwareKeyboardCommand] {
        get { storedHardwareKeyboardCommands }
        set {
            let previousSignature = effectiveHardwareKeyboardCommandSignature
            storedHardwareKeyboardCommands = newValue
            guard previousSignature != effectiveHardwareKeyboardCommandSignature else { return }
            keyCommandUpdateRequestCountForTesting += 1
            UIMenuSystem.main.setNeedsRebuild()
        }
    }

    override var keyCommands: [UIKeyCommand]? {
        guard !hardwareKeyboardCommands.isEmpty else { return nil }
        return hardwareKeyboardCommands.map { command in
            let keyCommand = UIKeyCommand(
                title: command.title,
                action: #selector(handleHardwareKeyboardCommand(_:)),
                input: command.input,
                modifierFlags: command.modifierFlags.appCommandModifiers
            )
            keyCommand.discoverabilityTitle = command.title
            keyCommand.wantsPriorityOverSystemBehavior = true
            return keyCommand
        }
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

    override var canBecomeFirstResponder: Bool { softwareKeyboardInputEnabled }
    var hasText: Bool { true }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(handleHardwareKeyboardCommand(_:)),
           let command = sender as? UIKeyCommand {
            return matchingHardwareKeyboardCommand(for: command) != nil
        }
        return super.canPerformAction(action, withSender: sender)
    }

    override var inputAccessoryView: UIView? {
        nil
    }

    /// IOS-6.8: hit-test transparent. Touches pass through to
    /// `UITerminalView` underneath so its pan-to-scroll and pinch-to-zoom
    /// gesture recognizers receive them. The keyboard responder chain
    /// is independent of hit-testing — `becomeFirstResponder()` from the
    /// container's tap recognizer still routes software-keyboard input
    /// here per IOS-6.6.
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        nil
    }

    func insertText(_ text: String) {
        insertTextHandler?(text)
    }

    func deleteBackward() {
        deleteBackwardHandler?()
    }

    @objc private func handleHardwareKeyboardCommand(_ command: UIKeyCommand) {
        matchingHardwareKeyboardCommand(for: command)?.perform()
    }

    private func matchingHardwareKeyboardCommand(
        for keyCommand: UIKeyCommand
    ) -> TerminalPaneView.HardwareKeyboardCommand? {
        guard let input = keyCommand.input else { return nil }
        let modifierFlags = keyCommand.modifierFlags.appCommandModifiers
        return hardwareKeyboardCommands.first {
            $0.input == input && $0.modifierFlags.appCommandModifiers == modifierFlags
        }
    }

    func performHardwareKeyboardCommandForTesting(input: String, modifierFlags: UIKeyModifierFlags) {
        handleHardwareKeyboardCommand(
            UIKeyCommand(
                action: #selector(handleHardwareKeyboardCommand(_:)),
                input: input,
                modifierFlags: modifierFlags
            )
        )
    }

    var autocorrectionType: UITextAutocorrectionType {
        get { .no }
        set {}
    }

    var autocapitalizationType: UITextAutocapitalizationType {
        get { .none }
        set {}
    }

    var smartQuotesType: UITextSmartQuotesType {
        get { .no }
        set {}
    }

    var smartDashesType: UITextSmartDashesType {
        get { .no }
        set {}
    }

    var smartInsertDeleteType: UITextSmartInsertDeleteType {
        get { .no }
        set {}
    }

    var spellCheckingType: UITextSpellCheckingType {
        get { .no }
        set {}
    }

    var keyboardType: UIKeyboardType {
        get { .default }
        set {}
    }
}

/// libghostty-spm's `UITerminalView` is `final` and unconditionally returns
/// its own `terminalInputAccessory` from `inputAccessoryView`. On iOS it
/// also auto-focuses itself in `touchesBegan` — once the keyboard responder
/// — UIKit mounts the GhosttyKit bar above the keyboard alongside graftty's
/// own SwiftUI `terminalControlBar` (`IOS-6.1`). The package exposes no
/// opt-out, so we replace two `@objc` getters at the ObjC runtime level:
///   - `inputAccessoryView` → nil, so even if `UITerminalView` ever does
///      win the responder race, no accessory mounts.
///   - `canBecomeFirstResponder` → false, so the `becomeFirstResponder()`
///      call inside its `touchesBegan` is a no-op and our `inputProxy`
///      stays the first responder (IOS-6.6 routing). The view's pan and
///      pinch gesture recognizers are unaffected — UIKit doesn't gate
///      gesture recognizers on responder status.
/// UIKit's keyboard / responder machinery dispatches via `objc_msgSend`
/// and picks up our IMPs. The swaps are idempotent (`dispatch_once`
/// semantics via `static let`) and fire from `GrafttyMobileApp.init`.
/// (`IOS-6.7`.)
extension UITerminalView {
    static func suppressGhosttyInputAccessory() {
        _ = swizzleInputAccessoryViewToNilOnce
        _ = swizzleCanBecomeFirstResponderToFalseOnce
    }

    private static let swizzleInputAccessoryViewToNilOnce: Void = {
        let selector = #selector(getter: UIResponder.inputAccessoryView)
        guard let method = class_getInstanceMethod(UITerminalView.self, selector) else { return }
        let block: @convention(block) (UIResponder) -> UIView? = { _ in nil }
        method_setImplementation(method, imp_implementationWithBlock(block))
    }()

    private static let swizzleCanBecomeFirstResponderToFalseOnce: Void = {
        let selector = #selector(getter: UIResponder.canBecomeFirstResponder)
        guard let method = class_getInstanceMethod(UITerminalView.self, selector) else { return }
        let block: @convention(block) (UIResponder) -> Bool = { _ in false }
        method_setImplementation(method, imp_implementationWithBlock(block))
    }()
}
#endif
