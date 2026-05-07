// Sources/Graftty/Views/SettingsView.swift
import AppKit
import GrafttyKit
import SwiftUI

/// Preferences pane for Graftty — the "General" tab inside the SwiftUI
/// `Settings` scene. The `TabView` + `.tabItem` shell lives in `GrafttyApp`
/// so this view renders its form directly; wrapping another `TabView` here
/// would nest a second "General" tab strip under the first.
struct SettingsView: View {
    private enum EditorKind: String {
        case shell = ""
        case app
        case cli
    }

    @AppStorage(SettingsKeys.defaultCommand) private var defaultCommand: String = ""
    @AppStorage("defaultCommandFirstPaneOnly") private var firstPaneOnly: Bool = true
    @AppStorage(SettingsKeys.editorKind) private var editorKind: String = ""
    @AppStorage(SettingsKeys.editorAppBundleID) private var editorAppBundleID: String = ""
    @AppStorage(SettingsKeys.editorCliCommand) private var editorCliCommand: String = ""

    @State private var resolvedShellEditor: String = ""
    @State private var availableApps: [TextEditorApp] = []

    let onRestartZMX: () -> Void

    /// Shared with `TerminalManager`; the `shellEditorValue()` probe-cache lives
    /// here so the Settings caption doesn't fire a second `$SHELL -ilc` probe.
    let editorPreference: EditorPreference?

    var body: some View {
        Form {
            VStack(alignment: .leading, spacing: 6) {
                Text("Default command:")
                TextField("", text: $defaultCommand, prompt: Text("e.g., claude"))
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Toggle("Run in first pane only", isOn: $firstPaneOnly)

            Text("Runs automatically when a worktree opens. Leave empty to disable.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Divider().padding(.vertical, 4)

            Text("Editor")
                .font(.headline)

            Picker(selection: $editorKind) {
                Text(shellEditorRowLabel).tag(EditorKind.shell.rawValue)
                Text("App").tag(EditorKind.app.rawValue)
                Text("CLI Editor").tag(EditorKind.cli.rawValue)
            } label: {
                Text("Editor:")
            }
            .pickerStyle(.radioGroup)

            if editorKind == EditorKind.app.rawValue {
                Picker(selection: $editorAppBundleID) {
                    Text("Choose…").tag("")
                    ForEach(availableApps) { app in
                        Text(app.displayName).tag(app.bundleID)
                    }
                } label: {
                    Text("Application:")
                }
                .onAppear { loadAvailableAppsIfNeeded() }
            }

            if editorKind == EditorKind.cli.rawValue {
                TextField("CLI command:", text: $editorCliCommand, prompt: Text("e.g., nvim"))
                    .textFieldStyle(.roundedBorder)
            }

            Text("Used when you cmd-click a file path in a pane.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Divider().padding(.vertical, 4)

            HStack {
                Button("Restart ZMX…", action: onRestartZMX)
                Spacer()
            }

            Text("Ends all running terminal sessions. Use this if panes become unresponsive or you want fresh zmx daemons.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .frame(minWidth: 420, minHeight: 360)
        .onAppear { loadResolvedShellEditor() }
    }

    private var shellEditorRowLabel: String {
        if resolvedShellEditor.isEmpty {
            return "Use $EDITOR from shell"
        }
        return "Use $EDITOR from shell  (current: \(resolvedShellEditor))"
    }

    /// Read the (already-cached) shell `$EDITOR` from the shared preference
    /// so this row's caption matches what cmd-click would actually fall back
    /// to. Hops to a background queue in case the cache is cold and the
    /// underlying probe still has to spawn the shell.
    private func loadResolvedShellEditor() {
        guard let pref = editorPreference else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            let value = pref.shellEditorValue() ?? "vi"
            DispatchQueue.main.async {
                self.resolvedShellEditor = value
            }
        }
    }

    private func loadAvailableAppsIfNeeded() {
        guard availableApps.isEmpty else { return }
        let sampleURL = URL(fileURLWithPath: "/tmp/x.txt")
        let urls = NSWorkspace.shared.urlsForApplications(toOpen: sampleURL)

        var seen = Set<String>()
        var apps: [TextEditorApp] = []
        for url in urls {
            guard let bundle = Bundle(url: url),
                  let bundleID = bundle.bundleIdentifier,
                  !seen.contains(bundleID) else { continue }
            seen.insert(bundleID)

            let displayName = FileManager.default.displayName(atPath: url.path)
            apps.append(TextEditorApp(bundleID: bundleID, displayName: displayName, url: url))
        }
        apps.sort { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        self.availableApps = apps
    }
}

private struct TextEditorApp: Identifiable {
    let bundleID: String
    let displayName: String
    let url: URL
    var id: String { bundleID }
}
