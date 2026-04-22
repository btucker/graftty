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
    public let focusRequestCount: Int
    public let onFocus: () -> Void

    public init(
        session: InMemoryTerminalSession,
        focusRequestCount: Int = 0,
        onFocus: @escaping () -> Void = {}
    ) {
        self.session = session
        self.focusRequestCount = focusRequestCount
        self.onFocus = onFocus
    }

    public func makeCoordinator() -> Coordinator { Coordinator() }

    public final class Coordinator {
        var lastFocusRequest: Int = 0
    }

    public func makeUIView(context: Context) -> UITerminalView {
        let view = UITerminalView(frame: .zero)
        view.controller = TerminalController.shared
        view.configuration = TerminalSurfaceOptions(backend: .inMemory(session))
        context.coordinator.lastFocusRequest = focusRequestCount
        return view
    }

    public func updateUIView(_ view: UITerminalView, context: Context) {
        view.configuration = TerminalSurfaceOptions(backend: .inMemory(session))
        if context.coordinator.lastFocusRequest != focusRequestCount {
            context.coordinator.lastFocusRequest = focusRequestCount
            // Async hop so the call happens outside the current view-update
            // transaction; UIKit is happier when responder changes aren't
            // driven synchronously from a SwiftUI render pass.
            DispatchQueue.main.async {
                _ = view.becomeFirstResponder()
            }
        }
    }
}
#endif
