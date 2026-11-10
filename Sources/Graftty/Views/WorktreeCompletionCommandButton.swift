import AppKit
import SwiftUI

/// A native menu shortcut routes to the terminal that is actually first responder.
struct WorktreeCompletionCommandButton: View {
    static let shortcut = KeyboardShortcut("k", modifiers: [.command, .shift])

    var body: some View {
        Button("Complete Worktree…") {
            NSApp.sendAction(#selector(SurfaceNSView.completeWorktree(_:)), to: nil, from: nil)
        }
        .keyboardShortcut(Self.shortcut)
    }
}
