import SwiftUI
import AppKit

extension View {
    /// AppKit-backed right-click menu. Use INSTEAD OF SwiftUI's
    /// `.contextMenu` on rows inside a SwiftUI `List` whose row
    /// container holds multiple sibling views — SwiftUI on macOS
    /// hoists `.contextMenu` modifiers to the row level and only
    /// honors one per row, silently shadowing the rest.
    ///
    /// Implemented as an overlay (not a background) because AppKit's
    /// `menu(for:)` walk goes from the hit view up the *superview*
    /// chain, never to siblings — and any wrapping modifier like
    /// `.dropDestination` adds its own NSView that shadows a
    /// background sibling entirely. The overlay returns `nil` from
    /// `hitTest` for ordinary events so left-clicks and drags pass
    /// through to the underlying view.
    ///
    /// The closure is invoked at right-click time so dynamic state
    /// (current cwd, web-server port, etc.) is sampled fresh on each
    /// open instead of being captured at view-construction time.
    func rightClickMenu(_ build: @escaping () -> NSMenu) -> some View {
        overlay(RightClickMenuOverlay(build: build))
    }
}

enum RightClickHitTest {
    static func shouldAcceptHit(for event: NSEvent?) -> Bool {
        guard let event else { return false }
        switch event.type {
        case .rightMouseDown, .rightMouseUp:
            return true
        case .leftMouseDown, .leftMouseUp:
            // macOS treats ctrl-left-click as a context-menu trigger.
            return event.modifierFlags.contains(.control)
        default:
            return false
        }
    }
}

private struct RightClickMenuOverlay: NSViewRepresentable {
    let build: () -> NSMenu

    func makeNSView(context: Context) -> NSView {
        let v = HostView()
        v.build = build
        return v
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? HostView)?.build = build
    }

    final class HostView: NSView {
        var build: (() -> NSMenu)?

        override func hitTest(_ point: NSPoint) -> NSView? {
            RightClickHitTest.shouldAcceptHit(for: NSApp.currentEvent) ? self : nil
        }

        override func menu(for event: NSEvent) -> NSMenu? { build?() }
    }
}

/// `NSMenuItem` that runs a Swift closure on selection. Lets callers
/// build menus from Swift closures without owning a long-lived
/// `#selector` target — the item itself becomes the target and lives
/// as long as the enclosing menu does.
final class ClosureMenuItem: NSMenuItem {
    private let runAction: () -> Void

    init(title: String, action: @escaping () -> Void, keyEquivalent: String = "") {
        self.runAction = action
        super.init(title: title, action: #selector(invoke), keyEquivalent: keyEquivalent)
        self.target = self
    }

    required init(coder: NSCoder) { fatalError("init(coder:) is not used") }

    @objc private func invoke() { runAction() }
}
