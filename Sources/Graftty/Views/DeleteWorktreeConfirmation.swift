import AppKit

@MainActor
enum DeleteWorktreeConfirmation {
    static func present(worktreePath: String, on window: NSWindow,
                        confirmed: @escaping (String, NSWindow) -> Void) {
        let config = SheetAlert.Configuration(
            messageText: "Delete Worktree?",
            informativeText: "This will delete the worktree but not the branch.",
            style: .warning, primaryButton: "Delete Worktree", secondaryButton: "Cancel"
        )
        // Context menu tracking can restore window focus after its action.
        // Present on the row's owner once that action has returned.
        DispatchQueue.main.async { [weak window] in
            guard let window, window.isVisible else { return }
            SheetAlert.present(config, on: window) { response in
                guard response == .primary else { return }
                confirmed(worktreePath, window)
            }
        }
    }
}
