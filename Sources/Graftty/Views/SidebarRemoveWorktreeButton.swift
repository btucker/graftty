import AppKit
import SwiftUI

/// Keeps removal separate from row selection and supplies the clicked window
/// to the existing confirmation flow, even when multiple windows are open.
struct SidebarRemoveWorktreeButton: NSViewRepresentable {
    let name: String
    let color: Color
    let onRemove: (NSWindow) -> Void

    func makeNSView(context: Context) -> SidebarRemoveWorktreeButtonView { .init() }
    func updateNSView(_ view: SidebarRemoveWorktreeButtonView, context: Context) {
        view.onRemove = onRemove
        view.contentTintColor = NSColor(color)
        view.toolTip = "Remove merged worktree"
        view.setAccessibilityLabel("Remove worktree \(name)")
    }
}

final class SidebarRemoveWorktreeButtonView: NSButton {
    var onRemove: ((NSWindow) -> Void)?
    init() {
        super.init(frame: .init(x: 0, y: 0, width: 24, height: 20))
        image = NSImage(systemSymbolName: "trash", accessibilityDescription: "Remove worktree")
        imagePosition = .imageOnly
        isBordered = false
        setButtonType(.momentaryPushIn)
        target = self
        action = #selector(removeWorktree)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func removeWorktree() {
        guard let window else { return }
        onRemove?(window)
    }
}
