import SwiftUI
import GrafttyKit

/// A pending Add Worktree sheet presentation, bundling the target repo
/// with the name to pre-fill into the sheet's worktree/branch fields.
/// Identified by `repo.id` so a repeated ⌘T while the sheet is already
/// open is idempotent rather than reset-with-fresh-state.
struct AddWorktreeRequest: Identifiable {
    let repo: RepoEntry
    let prefill: String
    var id: UUID { repo.id }
}

/// Scene-scoped command exposed by `MainWindow` so the `.commands` block
/// in `GrafttyApp` (which can't reach view-local state) can trigger the
/// Add Worktree sheet. A `nil` value means no worktree is currently
/// selected, so the menu item is disabled.
struct AddWorktreeActionKey: FocusedValueKey {
    typealias Value = () -> Void
}

extension FocusedValues {
    var addWorktreeAction: (() -> Void)? {
        get { self[AddWorktreeActionKey.self] }
        set { self[AddWorktreeActionKey.self] = newValue }
    }
}

struct AddWorktreeCommandButton: View {
    @FocusedValue(\.addWorktreeAction) private var action: (() -> Void)?

    var body: some View {
        Button("Add Worktree...") { action?() }
            .keyboardShortcut("t", modifiers: .command)
            .disabled(action == nil)
    }
}
