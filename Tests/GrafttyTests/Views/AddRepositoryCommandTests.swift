import SwiftUI
import Testing
@testable import Graftty

@Suite("@spec LAYOUT-3.6: When the user chooses File → Add Repository… or presses ⇧⌘O, the application shall run the focused window's Add Repository action, and shall disable the command while no window publishes one.")
@MainActor
struct AddRepositoryCommandTests {
    @Test func performsTheFocusedWindowsAction() {
        var calls = 0
        let command = AddRepositoryCommand(action: { calls += 1 })
        #expect(command.isEnabled)
        command.perform()
        #expect(calls == 1)
    }

    @Test func isDisabledWithoutAFocusedWindowAction() {
        let command = AddRepositoryCommand(action: nil)
        #expect(!command.isEnabled)
        command.perform()
    }

    @Test func keepsTheShiftCommandOShortcut() {
        #expect(AddRepositoryCommand.shortcut.key == KeyEquivalent("o"))
        #expect(AddRepositoryCommand.shortcut.modifiers == [.command, .shift])
    }
}
