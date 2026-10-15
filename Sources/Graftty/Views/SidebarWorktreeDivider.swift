import AppKit
import SwiftUI

/// A native separator keeps its drawing and measured bounds together.
struct SidebarWorktreeDivider: NSViewRepresentable {
    func makeNSView(context: Context) -> NSBox {
        let divider = SidebarSeparatorBox()
        divider.boxType = .separator
        divider.setAccessibilityIdentifier("Worktree list divider")
        return divider
    }

    func updateNSView(_ divider: NSBox, context: Context) {}
}

/// NSBox adds two points above and below its separator alignment rect.
/// Keep the native bounds inside the one-point SwiftUI divider allocation.
private final class SidebarSeparatorBox: NSBox {
    override var alignmentRectInsets: NSEdgeInsets { NSEdgeInsets() }
}
