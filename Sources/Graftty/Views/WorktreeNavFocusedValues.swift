import SwiftUI

/// Scene-scoped command exposed by `MainWindow` so the `.commands` block in
/// `GrafttyApp` (which can't reach view-local state) can drive worktree
/// navigation. The `Bool` is `forward` — `true` for `next_tab`
/// (ctrl+tab), `false` for `previous_tab` (ctrl+shift+tab). A `nil` value
/// means there is nothing to navigate (0/1 selectable worktree), so the
/// menu items are disabled.
struct WorktreeNavActionKey: FocusedValueKey {
    typealias Value = (_ forward: Bool) -> Void
}

extension FocusedValues {
    var worktreeNavAction: ((Bool) -> Void)? {
        get { self[WorktreeNavActionKey.self] }
        set { self[WorktreeNavActionKey.self] = newValue }
    }
}

struct WorktreeNavCommandButtons: View {
    @FocusedValue(\.worktreeNavAction) private var action: ((Bool) -> Void)?
    let nextShortcut: KeyboardShortcut?
    let previousShortcut: KeyboardShortcut?

    var body: some View {
        Group {
            button("Next Worktree", forward: true, shortcut: nextShortcut)
            button("Previous Worktree", forward: false, shortcut: previousShortcut)
        }
    }

    @ViewBuilder
    private func button(_ label: LocalizedStringKey, forward: Bool, shortcut: KeyboardShortcut?) -> some View {
        let b = Button(label) { action?(forward) }.disabled(action == nil)
        if let shortcut { b.keyboardShortcut(shortcut) } else { b }
    }
}
