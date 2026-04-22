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
    public let session: InMemoryTerminalSession
    public let controller: TerminalController
    public let focusRequestCount: Int

    public init(
        session: InMemoryTerminalSession,
        controller: TerminalController,
        focusRequestCount: Int = 0
    ) {
        self.session = session
        self.controller = controller
        self.focusRequestCount = focusRequestCount
    }

    public func makeCoordinator() -> Coordinator { Coordinator() }

    public final class Coordinator {
        var lastFocusRequest: Int = 0
    }

    public func makeUIView(context: Context) -> UITerminalView {
        let view = UITerminalView(frame: .zero)
        view.controller = controller
        view.configuration = TerminalSurfaceOptions(backend: .inMemory(session))
        context.coordinator.lastFocusRequest = focusRequestCount
        return view
    }

    public func updateUIView(_ view: UITerminalView, context: Context) {
        view.configuration = TerminalSurfaceOptions(backend: .inMemory(session))
        if context.coordinator.lastFocusRequest != focusRequestCount {
            context.coordinator.lastFocusRequest = focusRequestCount
            DispatchQueue.main.async {
                _ = view.becomeFirstResponder()
            }
        }
    }
}
#endif
