import SwiftUI

/// Scene-scoped command exposed by `MainWindow` so the `.commands` block
/// in `GrafttyApp` (which can't reach view-local state) can open the
/// Add Repository panel. A `nil` value means no window publishes the
/// action, so the menu item is disabled. LAYOUT-3.6.
struct AddRepositoryActionKey: FocusedValueKey {
    typealias Value = () -> Void
}

extension FocusedValues {
    var addRepositoryAction: (() -> Void)? {
        get { self[AddRepositoryActionKey.self] }
        set { self[AddRepositoryActionKey.self] = newValue }
    }
}

/// The File → Add Repository… command, separated from its SwiftUI
/// button so the enable/perform behaviour is testable.
struct AddRepositoryCommand {
    static let shortcut = KeyboardShortcut("o", modifiers: [.command, .shift])

    let action: (() -> Void)?

    var isEnabled: Bool { action != nil }

    func perform() { action?() }
}

struct AddRepositoryCommandButton: View {
    @FocusedValue(\.addRepositoryAction) private var action: (() -> Void)?

    var body: some View {
        let command = AddRepositoryCommand(action: action)
        Button("Add Repository...") { command.perform() }
            .keyboardShortcut(AddRepositoryCommand.shortcut)
            .disabled(!command.isEnabled)
    }
}
