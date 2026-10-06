import AppKit
import SwiftUI
import GrafttyKit

/// A native popup fills the advertised target, including the label and arrow.
struct SidebarWorktreeOrderControl: NSViewRepresentable {
    @Binding var selection: WorktreeOrderMode
    var color: NSColor
    static let choices: [(title: String, mode: WorktreeOrderMode)] = [
        ("Manual Order", .manual), ("Recent Activity", .recentActivity),
    ]

    func makeCoordinator() -> Coordinator { Coordinator(selection: $selection) }

    func makeNSView(context: Context) -> NSPopUpButton {
        let button = SidebarOrderPopUpButton(frame: .zero, pullsDown: false)
        button.isBordered = false
        button.font = .systemFont(ofSize: 11, weight: .semibold)
        button.addItems(withTitles: Self.choices.map(\.title))
        button.target = context.coordinator
        button.action = #selector(Coordinator.selectOrder(_:))
        button.toolTip = "Worktree order"
        button.setAccessibilityLabel("Worktree order")
        return button
    }

    func updateNSView(_ button: NSPopUpButton, context: Context) {
        context.coordinator.selection = $selection
        button.contentTintColor = color
        button.selectItem(at: Self.choices.firstIndex { $0.mode == selection } ?? 0)
    }

    final class Coordinator: NSObject {
        var selection: Binding<WorktreeOrderMode>
        init(selection: Binding<WorktreeOrderMode>) { self.selection = selection }
        @objc func selectOrder(_ sender: NSPopUpButton) {
            guard SidebarWorktreeOrderControl.choices.indices.contains(sender.indexOfSelectedItem) else { return }
            selection.wrappedValue = SidebarWorktreeOrderControl.choices[sender.indexOfSelectedItem].mode
        }
    }
}

/// AppKit's borderless popup has a 5pt left alignment inset. SwiftUI's
/// native wrapper clips hit testing to the alignment rectangle, leaving
/// that strip of the popup outside its event target. Use matching bounds.
final class SidebarOrderPopUpButton: NSPopUpButton {
    override var alignmentRectInsets: NSEdgeInsets { NSEdgeInsets() }
}
