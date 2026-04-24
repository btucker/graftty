#if canImport(UIKit)
import GhosttyTerminal
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

    public init(
        session: InMemoryTerminalSession,
        controller: TerminalController,
        focusRequestCount: Int = 0,
        softwareKeyboardInput: SoftwareKeyboardInput? = nil
    ) {
        self.session = session
        self.controller = controller
        self.focusRequestCount = focusRequestCount
        self.softwareKeyboardInput = softwareKeyboardInput
    }

    public func makeCoordinator() -> Coordinator { Coordinator() }

    public final class Coordinator {
        var lastFocusRequest: Int = 0
    }

    public func makeUIView(context: Context) -> TerminalInputContainerView {
        let view = TerminalInputContainerView()
        view.terminalView.controller = controller
        view.terminalView.configuration = TerminalSurfaceOptions(backend: .inMemory(session))
        view.inputProxy.insertTextHandler = softwareKeyboardInput?.insertText
        view.inputProxy.deleteBackwardHandler = softwareKeyboardInput?.deleteBackward
        context.coordinator.lastFocusRequest = focusRequestCount
        return view
    }

    public func updateUIView(_ view: TerminalInputContainerView, context: Context) {
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

        inputProxy.terminalView = terminalView
        inputProxy.isHidden = true
        inputProxy.isUserInteractionEnabled = false
        addSubview(inputProxy)

        let tap = UITapGestureRecognizer(target: self, action: #selector(focusKeyboardInput))
        tap.cancelsTouchesInView = false
        addGestureRecognizer(tap)
    }

    @objc func focusKeyboardInput() {
        _ = inputProxy.becomeFirstResponder()
    }
}

final class TerminalSoftwareKeyboardProxyView: UIView, UIKeyInput, UITextInputTraits {
    weak var terminalView: UITerminalView?
    var insertTextHandler: ((String) -> Void)?
    var deleteBackwardHandler: (() -> Void)?

    override var canBecomeFirstResponder: Bool { true }
    var hasText: Bool { true }

    override var inputAccessoryView: UIView? {
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
#endif
