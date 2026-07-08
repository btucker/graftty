#if canImport(UIKit)
import SwiftUI

struct MobileWorktreeNavActionKey: FocusedValueKey {
    typealias Value = (_ forward: Bool) -> Void
}

extension FocusedValues {
    var mobileWorktreeNavAction: ((Bool) -> Void)? {
        get { self[MobileWorktreeNavActionKey.self] }
        set { self[MobileWorktreeNavActionKey.self] = newValue }
    }
}

struct MobileWorktreeNavCommandButtons: View {
    @FocusedValue(\.mobileWorktreeNavAction) private var action: ((Bool) -> Void)?

    var body: some View {
        Group {
            Button("Next Worktree") { action?(true) }
                .keyboardShortcut(.tab, modifiers: [.control])
            Button("Previous Worktree") { action?(false) }
                .keyboardShortcut(.tab, modifiers: [.control, .shift])
        }
        .disabled(action == nil)
    }
}
#endif
