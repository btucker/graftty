import SwiftUI
import AppKit

/// Wraps a libghostty surface's NSView for use in SwiftUI.
struct SurfaceViewWrapper: NSViewRepresentable {
    let nsView: NSView

    func makeNSView(context: Context) -> NSView {
        nsView
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        // No updates needed — the view is managed by libghostty
    }
}
