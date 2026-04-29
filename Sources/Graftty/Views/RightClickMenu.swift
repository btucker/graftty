import SwiftUI
import AppKit

extension View {
    /// AppKit-backed right-click menu. Use INSTEAD OF SwiftUI's
    /// `.contextMenu` on rows inside a SwiftUI `List` whose row
    /// container holds multiple sibling views — SwiftUI on macOS
    /// hoists `.contextMenu` modifiers to the row level and only
    /// honors one per row, silently shadowing the rest. Hosting the
    /// menu on a per-view background `NSView` gives each row its own
    /// menu regardless of List-row hoisting.
    ///
    /// The closure is invoked at right-click time so dynamic state
    /// (current cwd, web-server port, etc.) is sampled fresh on each
    /// open instead of being captured at view-construction time.
    func rightClickMenu(_ build: @escaping () -> NSMenu) -> some View {
        background(RightClickMenuBackground(build: build))
    }
}

private struct RightClickMenuBackground: NSViewRepresentable {
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
