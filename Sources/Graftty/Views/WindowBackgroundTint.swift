import SwiftUI
import AppKit

/// Applies ghostty-derived chrome settings to the host `NSWindow`:
/// background color tint (so the hidden-title-bar strip doesn't render
/// system white), transparent titlebar + full-size content view (so the
/// breadcrumb can sit at y=0 alongside the traffic lights), and
/// appearance name (so system-rendered chrome — traffic lights, sidebar
/// toggle icon, menus, alerts — matches the theme's dark/light-ness).
///
/// Without this, `.windowStyle(.hiddenTitleBar)` leaves a visible strip
/// of white chrome and the traffic lights render with the wrong contrast.
struct WindowBackgroundTint: NSViewRepresentable {
    let theme: GhosttyTheme

    func makeNSView(context: Context) -> NSView {
        let view = TintView()
        view.theme = theme
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? TintView)?.theme = theme
        (nsView as? TintView)?.apply()
    }

    private final class TintView: NSView {
        var theme: GhosttyTheme = .fallback

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            apply()
        }

        func apply() {
            guard let window else { return }
            window.backgroundColor = theme.backgroundNSColor
            window.titlebarAppearsTransparent = true
            // Extend the content view under the title bar so the
            // breadcrumb row can sit alongside the traffic lights
            // instead of below them. `.windowStyle(.hiddenTitleBar)`
            // hides the title but doesn't set this on its own.
            window.styleMask.insert(.fullSizeContentView)
            // Appearance drives system chrome rendering — traffic
            // lights' color, sidebar-toggle icon shade, context-menu
            // style. Pick dark/light from the ghostty background so
            // none of that fights the theme.
            window.appearance = theme.nsAppearance
        }
    }
}

extension View {
    /// Apply ghostty-derived chrome to the host NSWindow: background tint,
    /// transparent titlebar, full-size content view, and light/dark
    /// appearance. Use with `.windowStyle(.hiddenTitleBar)`.
    func windowBackgroundTint(theme: GhosttyTheme) -> some View {
        background(WindowBackgroundTint(theme: theme))
    }
}
