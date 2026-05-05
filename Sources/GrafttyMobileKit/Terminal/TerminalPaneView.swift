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

    public let session: InMemoryTerminalSession
    public let controller: TerminalController
    public let focusRequestCount: Int
    public let softwareKeyboardInput: SoftwareKeyboardInput?
    /// Forces the terminal view's color-scheme appearance, overriding the
    /// iOS system appearance. Use `.dark` or `.light` when the Ghostty
    /// config specifies an explicit single theme so that libghostty's
    /// `traitCollectionDidChange` → `setColorScheme()` path never
    /// substitutes a system-default theme over the user's choice.
    /// Pass `.unspecified` (the default) when the config uses a
    /// `light:X,dark:Y` pair and should adapt to system appearance.
    public let preferredInterfaceStyle: UIUserInterfaceStyle

    public init(
        session: InMemoryTerminalSession,
        controller: TerminalController,
        focusRequestCount: Int = 0,
        softwareKeyboardInput: SoftwareKeyboardInput? = nil,
        preferredInterfaceStyle: UIUserInterfaceStyle = .unspecified
    ) {
        self.session = session
        self.controller = controller
        self.focusRequestCount = focusRequestCount
        self.softwareKeyboardInput = softwareKeyboardInput
        self.preferredInterfaceStyle = preferredInterfaceStyle
    }

    public func makeCoordinator() -> Coordinator { Coordinator() }

    public final class Coordinator {
        var lastFocusRequest: Int = 0
    }

    public func makeUIView(context: Context) -> TerminalInputContainerView {
        let view = TerminalInputContainerView()
        view.overrideUserInterfaceStyle = preferredInterfaceStyle
        view.terminalView.controller = controller
        view.terminalView.configuration = TerminalSurfaceOptions(backend: .inMemory(session))
        view.inputProxy.insertTextHandler = softwareKeyboardInput?.insertText
        view.inputProxy.deleteBackwardHandler = softwareKeyboardInput?.deleteBackward
        context.coordinator.lastFocusRequest = focusRequestCount
        return view
    }

    public func updateUIView(_ view: TerminalInputContainerView, context: Context) {
        view.overrideUserInterfaceStyle = preferredInterfaceStyle
        view.terminalView.configuration = TerminalSurfaceOptions(backend: .inMemory(session))
        view.inputProxy.insertTextHandler = softwareKeyboardInput?.insertText
        view.inputProxy.deleteBackwardHandler = softwareKeyboardInput?.deleteBackward
        if context.coordinator.lastFocusRequest != focusRequestCount {
            context.coordinator.lastFocusRequest = focusRequestCount
            DispatchQueue.main.async {
                view.focusKeyboardInput()
            }
        }
    }
}

public final class TerminalInputContainerView: UIView {
    let terminalView = UITerminalView(frame: .zero)
    let inputProxy = TerminalSoftwareKeyboardProxyView(frame: .zero)

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

        let tap = UITapGestureRecognizer(target: self, action: #selector(focusKeyboardInput))
        tap.cancelsTouchesInView = false
        addGestureRecognizer(tap)
    }

    @objc func focusKeyboardInput() {
        _ = inputProxy.becomeFirstResponder()
    }
}

final class TerminalSoftwareKeyboardProxyView: UIView, UIKeyInput, UITextInputTraits {
    var insertTextHandler: ((String) -> Void)?
    var deleteBackwardHandler: (() -> Void)?

    override var canBecomeFirstResponder: Bool { true }
    var hasText: Bool { true }

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
