import SwiftUI

/// Preferences pane for Graftty — the "General" tab inside the SwiftUI
/// `Settings` scene. The `TabView` + `.tabItem` shell lives in `GrafttyApp`
/// so this view renders its form directly; wrapping another `TabView` here
/// would nest a second "General" tab strip under the first.
struct SettingsView: View {
    @AppStorage("defaultCommand") private var defaultCommand: String = ""
    @AppStorage("defaultCommandFirstPaneOnly") private var firstPaneOnly: Bool = true

    var body: some View {
        Form {
            TextField("Default command:", text: $defaultCommand, prompt: Text("e.g., claude"))
                .textFieldStyle(.roundedBorder)

            Toggle("Run in first pane only", isOn: $firstPaneOnly)

            Text("Runs automatically when a worktree opens. Leave empty to disable.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .frame(minWidth: 420, minHeight: 240)
    }
}
