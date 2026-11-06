import SwiftUI
import GrafttyProtocol
import GrafttyKit

/// A pending Add Worktree sheet presentation, bundling the target repo
/// with the name to pre-fill into the sheet's worktree/branch fields.
/// Identified by `repo.id` so a repeated ⌘T while the sheet is already
/// open is idempotent rather than reset-with-fresh-state.
struct AddWorktreeRequest: Identifiable {
    let repo: RepoEntry
    let prefill: String
    var existingBranch: String? = nil
    var hostContext: AddWorktreeHostContext? = nil
    var id: UUID { repo.id }
}

/// The Host row, for a project on several hosts. Changing host reopens the
/// sheet for that host, because each host has its own branch list.
struct AddWorktreeHostContext {
    let projectName: String
    let choices: [AddWorktreeHostChoice]
    let selectedID: String
    let onSelect: (_ id: String, _ name: String, _ branch: String?) -> Void
    /// The chosen host becomes the project's default once a worktree exists on it.
    let onCreated: () -> Void
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
