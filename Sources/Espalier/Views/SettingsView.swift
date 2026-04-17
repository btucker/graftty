import SwiftUI

/// Preferences pane for Espalier. Exposed via the SwiftUI `Settings` scene,
/// so the system adds a "Settings…" menu item under "About Espalier" and
/// binds the standard ⌘, shortcut automatically.
struct SettingsView: View {
    @AppStorage("defaultCommand") private var defaultCommand: String = ""
    @AppStorage("defaultCommandFirstPaneOnly") private var firstPaneOnly: Bool = true

    var body: some View {
        TabView {
            generalTab
                .tabItem { Label("General", systemImage: "gear") }
        }
        .frame(width: 440)
        .padding(20)
    }

    private var generalTab: some View {
        Form {
            TextField("Default command:", text: $defaultCommand, prompt: Text("e.g., claude"))
                .textFieldStyle(.roundedBorder)

            Toggle("Run in first pane only", isOn: $firstPaneOnly)

            Text("Runs automatically when a worktree opens. Leave empty to disable.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
