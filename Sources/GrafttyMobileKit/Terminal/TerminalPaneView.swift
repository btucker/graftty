#if canImport(UIKit)
import GhosttyTerminal
import SwiftUI
import UIKit

/// A SwiftUI wrapper around `UITerminalView` backed by an
/// `InMemoryTerminalSession` (no PTY — safe inside App Sandbox).
public struct TerminalPaneView: UIViewRepresentable {
    public let session: InMemoryTerminalSession
    public let onFocus: () -> Void

    public init(
        session: InMemoryTerminalSession,
        onFocus: @escaping () -> Void = {}
    ) {
        self.session = session
        self.onFocus = onFocus
    }

    public func makeUIView(context _: Context) -> UITerminalView {
        let view = UITerminalView(frame: .zero)
        view.controller = TerminalControllerStore.shared
        view.configuration = TerminalSurfaceOptions(backend: .inMemory(session))
        return view
    }

    public func updateUIView(_ view: UITerminalView, context _: Context) {
        // Assigning is idempotent for the same session object; replacing
        // swaps the backend when the session changes.
        view.configuration = TerminalSurfaceOptions(backend: .inMemory(session))
    }
}
#endif
