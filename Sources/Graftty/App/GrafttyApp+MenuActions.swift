import SwiftUI
import AppKit
import GrafttyCommandUI
import GrafttyHostAgent
import GrafttyKit
import GrafttyProtocol
import GrafttyRemoteClient

extension GrafttyApp {
    // MARK: - Focused-pane helpers for menu actions

    /// The terminal currently holding focus in the selected worktree.
    private var focusedPaneSlotID: PaneSlotID? {
        guard let path = appState.selectedWorktreePath else { return nil }
        for repo in appState.repos {
            for wt in repo.worktrees where wt.path == path && (wt.state == .running || wt.workspaceLayout?.root != nil) {
                return wt.presentationPane
            }
        }
        return nil
    }

    private func handleSplit(_ split: PaneSplit) {
        if focusedPresentationIsCompleted { return }
        if routeFocusedHostManagedPaneCommand(.split(split)) { return }
        guard let id = focusedPaneSlotID else { return }
        _ = PaneCommands.splitPane(appState: $appState, terminalManager: terminalManager, targetID: id, split: split)
    }

    private func handleNavigate(_ dir: NavigationDirection) {
        if routeFocusedHostManagedPaneCommand(.focus(dir)) { return }
        guard let id = focusedPaneSlotID else { return }
        PaneCommands.navigatePane(appState: $appState, terminalManager: terminalManager, from: id, direction: dir)
    }

    func handleNavigateTreeOrder(forward: Bool) {
        if routeFocusedHostManagedPaneCommand(
            .focusOrder(forward: forward)
        ) {
            return
        }
        guard let id = focusedPaneSlotID else { return }
        PaneCommands.navigatePaneInTreeOrder(appState: $appState, terminalManager: terminalManager, from: id, forward: forward)
    }

    private func handleToggleZoom() {
        if focusedPresentationIsCompleted { return }
        if routeFocusedHostManagedPaneCommand(.toggleZoom) { return }
        guard let id = focusedPaneSlotID else { return }
        PaneCommands.toggleZoom(appState: $appState, on: id)
    }

    private func handleEqualizeSplits() {
        if routeFocusedHostManagedPaneCommand(.equalize) { return }
        guard let id = focusedPaneSlotID else { return }
        PaneCommands.equalizeSplits(appState: $appState, around: id)
    }

    private func handleClosePane() {
        if let id = focusedPaneSlotID,
           PaneCommands.dismissCompletedTab(appState: $appState, terminalManager: terminalManager, targetID: id) { return }
        if routeFocusedHostManagedPaneCommand(.close) { return }
        guard let id = focusedPaneSlotID else { return }
        PaneCommands.closePane(
            appState: $appState,
            terminalManager: terminalManager,
            targetID: id,
            userInitiated: true
        )
    }

    private var focusedPresentationIsCompleted: Bool {
        guard let path = appState.selectedWorktreePath, let id = focusedPaneSlotID else { return false }
        return appState.worktree(forPath: path)?.hasCompletedContent(in: id) == true
    }

    private func routeFocusedHostManagedPaneCommand(
        _ command: HostManagedPaneCommand
    ) -> Bool {
        guard !focusedPresentationIsCompleted, let terminalID = terminalManager.focusedTerminalID else {
            return false
        }
        return terminalManager.routeHostManagedPaneCommand(
            command,
            for: terminalID
        )
    }

    private func handleReloadConfig() {
        terminalManager.reloadGhosttyConfig()
    }

    private func handleOpenGhosttySettings() {
        Self.openGhosttySettings()
    }

    func handleGhosttyCommand(_ command: GhosttyCommandRegistry.Entry) {
        switch command.kind {
        case .split(let direction):
            handleSplit(paneSplit(for: direction))
        case .closePane:
            handleClosePane()
        case .focusPane(let direction):
            handleNavigate(navigationDirection(for: direction))
        case .focusPaneByOrder(let forward):
            handleNavigateTreeOrder(forward: forward)
        case .unsupported:
            handleUnsupportedGhosttyAction(command.action)
        }
    }

    private func handleUnsupportedGhosttyAction(_ action: GhosttyAction) {
        switch action {
        case .increaseFontSize, .decreaseFontSize, .resetFontSize:
            guard let id = terminalManager.focusedTerminalID else { return }
            terminalManager.handle(for: id)?.followerPresentation?.performZoomAction(action)
        case .toggleSplitZoom:
            handleToggleZoom()
        case .equalizeSplits:
            handleEqualizeSplits()
        case .reloadConfig:
            handleReloadConfig()
        case .openConfig:
            handleOpenGhosttySettings()
        default:
            break
        }
    }

    private func paneSplit(for direction: GhosttySplitDirection) -> PaneSplit {
        switch direction {
        case .left:
            return .left
        case .right:
            return .right
        case .up:
            return .up
        case .down:
            return .down
        }
    }

    private func navigationDirection(for direction: GhosttyPaneFocusDirection) -> NavigationDirection {
        switch direction {
        case .left:
            return .left
        case .right:
            return .right
        case .up:
            return .up
        case .down:
            return .down
        }
    }

    /// Confirm with the user, then destroy every running worktree's panes
    /// (which fires `zmx kill --force` per session via `destroySurface` →
    /// `killZmxSession`) and mark those worktrees `.closed` via
    /// `prepareForStop` — mirroring the per-worktree Stop flow (`TERM-1.2` /
    /// `STATE-2.11`) but applied in bulk. Re-opening any worktree
    /// afterwards spawns fresh zmx daemons. `ZMX-8.1`.
    func restartZMXWithConfirmation() {
        Self.restartZMX(appState: $appState, confirm: { totalPanes, worktreeCount in
            let alert = NSAlert()
            alert.messageText = "Restart ZMX?"
            alert.informativeText = ZmxRestartConfirmation.informativeText(
                paneCount: totalPanes,
                worktreeCount: worktreeCount
            )
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Restart ZMX")
            alert.addButton(withTitle: "Cancel")
            return alert.runModal() == .alertFirstButtonReturn
        }, destroySurfaces: { terminalManager.destroySurfaces(terminalIDs: $0) })
    }

    @MainActor
    static func restartZMX(
        appState: Binding<AppState>,
        confirm: (_ paneCount: Int, _ worktreeCount: Int) -> Bool,
        destroySurfaces: ([PaneSlotID]) -> Void
    ) {
        struct RunningEntry {
            let repoID: UUID
            let worktreeID: UUID
        }
        var running: [RunningEntry] = []
        var totalPanes = 0
        for repo in appState.wrappedValue.repos {
            for wt in repo.worktrees where wt.state == .running {
                let leaves = wt.splitTree.allLeaves
                running.append(RunningEntry(repoID: repo.id, worktreeID: wt.id))
                totalPanes += leaves.count
            }
        }

        guard confirm(totalPanes, running.count) else { return }

        func currentIndices(for entry: RunningEntry) -> (repo: Int, worktree: Int)? {
            guard let repoIdx = appState.wrappedValue.repos.firstIndex(where: { $0.id == entry.repoID }),
                  let worktreeIdx = appState.wrappedValue.repos[repoIdx].worktrees.firstIndex(where: {
                      $0.id == entry.worktreeID && $0.state == .running
                  }) else { return nil }
            return (repoIdx, worktreeIdx)
        }
        for entry in running {
            guard let indices = currentIndices(for: entry) else { continue }
            let terminalIDs = appState.wrappedValue.repos[indices.repo].worktrees[indices.worktree].splitTree.allLeaves
            destroySurfaces(terminalIDs)
            // Teardown can call back into app state. Resolve again before writing.
            guard let indices = currentIndices(for: entry) else { continue }
            appState.wrappedValue.repos[indices.repo].worktrees[indices.worktree].prepareForStop()
        }
        // The menu bar stays usable with no window open (#604).
        Self.persistAppState(appState.wrappedValue)
    }

    /// Resolve the user's Ghostty config file path, create it if missing,
    /// and hand it to `NSWorkspace.open` so it launches in the user's
    /// default editor for that file type — same behavior as Ghostty.app's
    /// own "Open Configuration" menu. `TERM-9.2`.
    ///
    /// Static so the `open_config` keybind callback that
    /// `TerminalPaneActions.install` wires (which has no `self`) can share
    /// the implementation with the menu button's instance handler.
    static func openGhosttySettings() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let url = GhosttyConfigLocator.resolveURL(home: home)
        do {
            try GhosttyConfigLocator.ensureExists(at: url)
        } catch {
            let alert = NSAlert()
            alert.messageText = "Could Not Create Ghostty Config"
            alert.informativeText = "Failed to create \(url.path): \(error.localizedDescription)"
            alert.alertStyle = .warning
            alert.runModal()
            return
        }
        NSWorkspace.shared.open(url)
    }

    // MARK: - View builder for bridge-shortcutted menu buttons

    /// Wraps a menu button so its keyboard shortcut is derived from the
    /// keybind bridge at runtime, not hardcoded. If the action has no
    /// configured binding (or the key can't be translated to a
    /// `KeyboardShortcut`), the button renders without a shortcut hint.
    @MainActor
    @ViewBuilder
    func bridgedButton(
        _ command: GhosttyCommandRegistry.Entry,
        shortcutsByAction: [GhosttyAction: KeyboardShortcut],
        onTap: @escaping () -> Void
    ) -> some View {
        Group {
            if let shortcut = shortcutsByAction[command.action] {
                Button(command.label, action: onTap).keyboardShortcut(shortcut)
            } else {
                Button(command.label, action: onTap)
            }
        }
    }

    static func installAgentHookAssets() {
        do {
            _ = try AgentHookInstaller(
                rootDirectory: AgentHookInstaller.rootDirectory(),
                grafttyCLIPath: agentHookCLIPath()
            ).install()
        } catch {
            NSLog("[Graftty] Agent hook asset install failed: %@", String(describing: error))
        }
    }

    static func agentHookCLIPath() -> String {
        let bundled = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Helpers/graftty")
            .path
        if FileManager.default.fileExists(atPath: bundled) {
            return bundled
        }
        return "graftty"
    }

    func installCLI() {
        let bundleCLI = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Helpers/graftty")
        let symlink = "/usr/local/bin/graftty"

        switch CLIInstaller.plan(source: bundleCLI.path, destination: symlink) {
        case .directSymlink(let source, let destination):
            runDirectSymlink(source: source, destination: destination)
        case .showSudoCommand(let command, let destination):
            showSudoInstallAlert(command: command, destination: destination)
        case .sourceMissing(let source):
            // Dev build: `swift run Graftty` skips bundle.sh so the
            // Helpers dir doesn't exist. Surface it instead of
            // creating a dangling symlink. `ATTN-1.1`.
            let alert = NSAlert()
            alert.messageText = "CLI Binary Not Found"
            alert.informativeText = """
                The bundled CLI was not found at \(source). \
                If you are running a development build, run \
                `scripts/bundle.sh` first, then install from the bundled app.
                """
            alert.alertStyle = .warning
            alert.runModal()
        }
    }

    private func runDirectSymlink(source: String, destination: String) {
        let alert = NSAlert()
        alert.messageText = "Install CLI Tool"
        alert.informativeText = "Create a symlink at \(destination) pointing to the Graftty CLI?"
        alert.addButton(withTitle: "Install")
        alert.addButton(withTitle: "Cancel")

        guard alert.runModal() == .alertFirstButtonReturn else { return }

        do {
            try? FileManager.default.removeItem(atPath: destination)
            try FileManager.default.createSymbolicLink(
                atPath: destination,
                withDestinationPath: source
            )
        } catch {
            let errorAlert = NSAlert()
            errorAlert.messageText = "Installation Failed"
            errorAlert.informativeText = error.localizedDescription
            errorAlert.runModal()
        }
    }

    /// Parent directory isn't writable (e.g. /usr/local/bin owned by root).
    /// Surface a sudo command the user can copy and run in Terminal.
    private func showSudoInstallAlert(command: String, destination: String) {
        let alert = NSAlert()
        alert.messageText = "Administrator Access Required"
        alert.informativeText = "Installing to \(destination) requires sudo. Copy this command and run it in Terminal:"
        alert.addButton(withTitle: "Copy Command")
        alert.addButton(withTitle: "Cancel")

        // Attach a selectable, read-only text field so the user can also
        // eyeball / manually select the exact command.
        let textField = NSTextField(string: command)
        textField.isEditable = false
        textField.isSelectable = true
        textField.drawsBackground = true
        textField.backgroundColor = .textBackgroundColor
        textField.frame = NSRect(x: 0, y: 0, width: 440, height: 44)
        textField.isBordered = true
        textField.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        alert.accessoryView = textField

        if alert.runModal() == .alertFirstButtonReturn {
            Pasteboard.copy(command)
        }
    }
}
