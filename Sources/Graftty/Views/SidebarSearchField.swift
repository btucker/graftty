import AppKit
import SwiftUI

/// Native search provides editing, a clear button, and Escape handling.
struct SidebarSearchField: NSViewRepresentable {
    @Binding var query: String

    func makeCoordinator() -> Coordinator { Coordinator(query: $query) }

    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.placeholderString = "Search projects and worktrees"
        field.setAccessibilityLabel("Search projects and worktrees")
        field.font = .systemFont(ofSize: 13)
        field.sendsSearchStringImmediately = true
        field.sendsWholeSearchString = false
        field.delegate = context.coordinator
        field.target = context.coordinator
        field.action = #selector(Coordinator.search(_:))
        return field
    }

    func updateNSView(_ field: NSSearchField, context: Context) {
        context.coordinator.query = $query
        if field.stringValue != query { field.stringValue = query }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSSearchField, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 240, height: 30)
    }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var query: Binding<String>
        init(query: Binding<String>) { self.query = query }

        @objc func search(_ sender: NSSearchField) {
            query.wrappedValue = sender.stringValue
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSSearchField else { return }
            query.wrappedValue = field.stringValue
        }
    }
}
