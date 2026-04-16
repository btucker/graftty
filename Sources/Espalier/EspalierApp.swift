import SwiftUI
import AppKit
import EspalierKit

/// Holds long-lived non-SwiftUI services for the app. Retained for the lifetime of
/// `EspalierApp` so weak delegates (e.g. `WorktreeMonitor.delegate`) stay alive.
@MainActor
final class AppServices {
    let socketServer: SocketServer
    let worktreeMonitor: WorktreeMonitor
    var worktreeMonitorBridge: WorktreeMonitorBridge?

    init(socketPath: String) {
        self.socketServer = SocketServer(socketPath: socketPath)
        self.worktreeMonitor = WorktreeMonitor()
    }
}

@main
struct EspalierApp: App {
    @State private var appState: AppState
    @StateObject private var terminalManager: TerminalManager
    private let services: AppServices

    init() {
        let loaded = (try? AppState.load(from: AppState.defaultDirectory)) ?? AppState()
        _appState = State(initialValue: loaded)

        let socketPath = AppState.defaultDirectory.appendingPathComponent("espalier.sock").path
        _terminalManager = StateObject(wrappedValue: TerminalManager(socketPath: socketPath))
        services = AppServices(socketPath: socketPath)
    }

    var body: some Scene {
        WindowGroup {
            MainWindow(appState: $appState, terminalManager: terminalManager)
                .onAppear { startup() }
                .onChange(of: appState) { _, newState in
                    try? newState.save(to: AppState.defaultDirectory)
                }
        }
        // Default size only. Restoration of the exact saved frame is handled
        // by WindowFrameTracker (see MainWindow), which applies the saved
        // NSWindow.frame directly after the window is created. We cannot use
        // SwiftUI's `.defaultPosition(_:)` for this because on macOS 14 it
        // takes a UnitPoint (normalized 0..1), not pixel coordinates — passing
        // pixel values is silently a no-op.
        .defaultSize(width: 1400, height: 900)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Add Repository...") {
                    // MainWindow handles the file picker via its own button.
                    // This menu item is a placeholder for the standard shortcut.
                }
                .keyboardShortcut("o", modifiers: [.command, .shift])

                Divider()

                Button("Split Horizontally") {
                    splitFocusedPane(direction: .horizontal)
                }
                .keyboardShortcut("d", modifiers: [.command])

                Button("Split Vertically") {
                    splitFocusedPane(direction: .vertical)
                }
                .keyboardShortcut("d", modifiers: [.command, .shift])

                Divider()

                Button("Focus Pane Left") {
                    navigatePane(.left)
                }
                .keyboardShortcut(.leftArrow, modifiers: [.command, .option])

                Button("Focus Pane Right") {
                    navigatePane(.right)
                }
                .keyboardShortcut(.rightArrow, modifiers: [.command, .option])

                Button("Focus Pane Up") {
                    navigatePane(.up)
                }
                .keyboardShortcut(.upArrow, modifiers: [.command, .option])

                Button("Focus Pane Down") {
                    navigatePane(.down)
                }
                .keyboardShortcut(.downArrow, modifiers: [.command, .option])

                Divider()

                Button("Close Pane") {
                    closeFocusedPane()
                }
                .keyboardShortcut("w", modifiers: [.command])
            }

            CommandMenu("Espalier") {
                Button("Install CLI Tool...") {
                    installCLI()
                }
            }
        }
    }

    private func startup() {
        terminalManager.initialize()

        try? services.socketServer.start()
        // SocketServer already dispatches onMessage to the main queue.
        let binding = $appState
        let tm = terminalManager
        services.socketServer.onMessage = { message in
            MainActor.assumeIsolated {
                Self.handleNotification(message, appState: binding, terminalManager: tm)
            }
        }

        let bridge = WorktreeMonitorBridge(appState: $appState)
        services.worktreeMonitorBridge = bridge
        services.worktreeMonitor.delegate = bridge
        for repo in appState.repos {
            services.worktreeMonitor.watchWorktreeDirectory(repoPath: repo.path)
            for wt in repo.worktrees {
                services.worktreeMonitor.watchWorktreePath(wt.path)
                services.worktreeMonitor.watchHeadRef(worktreePath: wt.path, repoPath: repo.path)
            }
        }

        reconcileOnLaunch()
        restoreRunningWorktrees()
    }

    private func reconcileOnLaunch() {
        for repoIdx in appState.repos.indices {
            let repoPath = appState.repos[repoIdx].path
            guard let discovered = try? GitWorktreeDiscovery.discover(repoPath: repoPath) else { continue }
            let discoveredPaths = Set(discovered.map(\.path))

            let existingPaths = Set(appState.repos[repoIdx].worktrees.map(\.path))
            for d in discovered where !existingPaths.contains(d.path) {
                appState.repos[repoIdx].worktrees.append(
                    WorktreeEntry(path: d.path, branch: d.branch)
                )
            }

            for wtIdx in appState.repos[repoIdx].worktrees.indices {
                let wt = appState.repos[repoIdx].worktrees[wtIdx]
                if !discoveredPaths.contains(wt.path) && wt.state != .stale {
                    appState.repos[repoIdx].worktrees[wtIdx].state = .stale
                }
            }

            for wtIdx in appState.repos[repoIdx].worktrees.indices {
                if let match = discovered.first(where: { $0.path == appState.repos[repoIdx].worktrees[wtIdx].path }) {
                    appState.repos[repoIdx].worktrees[wtIdx].branch = match.branch
                }
            }
        }
    }

    private func restoreRunningWorktrees() {
        for repoIdx in appState.repos.indices {
            for wtIdx in appState.repos[repoIdx].worktrees.indices {
                let wt = appState.repos[repoIdx].worktrees[wtIdx]
                if wt.state == .running {
                    if wt.splitTree.root == nil {
                        let id = TerminalID()
                        appState.repos[repoIdx].worktrees[wtIdx].splitTree = SplitTree(root: .leaf(id))
                    }
                    _ = terminalManager.createSurfaces(
                        for: appState.repos[repoIdx].worktrees[wtIdx].splitTree,
                        worktreePath: wt.path
                    )
                }
            }
        }
    }

    @MainActor
    private static func handleNotification(
        _ message: NotificationMessage,
        appState: Binding<AppState>,
        terminalManager: TerminalManager
    ) {
        switch message {
        case .notify(let path, let text, let clearAfter):
            for repoIdx in appState.wrappedValue.repos.indices {
                for wtIdx in appState.wrappedValue.repos[repoIdx].worktrees.indices {
                    if appState.wrappedValue.repos[repoIdx].worktrees[wtIdx].path == path {
                        appState.wrappedValue.repos[repoIdx].worktrees[wtIdx].attention = Attention(
                            text: text,
                            timestamp: Date(),
                            clearAfter: clearAfter
                        )

                        if let clearAfter {
                            DispatchQueue.main.asyncAfter(deadline: .now() + clearAfter) {
                                for ri in appState.wrappedValue.repos.indices {
                                    for wi in appState.wrappedValue.repos[ri].worktrees.indices {
                                        if appState.wrappedValue.repos[ri].worktrees[wi].path == path {
                                            appState.wrappedValue.repos[ri].worktrees[wi].attention = nil
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        case .clear(let path):
            for repoIdx in appState.wrappedValue.repos.indices {
                for wtIdx in appState.wrappedValue.repos[repoIdx].worktrees.indices {
                    if appState.wrappedValue.repos[repoIdx].worktrees[wtIdx].path == path {
                        appState.wrappedValue.repos[repoIdx].worktrees[wtIdx].attention = nil
                    }
                }
            }
        }
    }

    private func splitFocusedPane(direction: SplitDirection) {
        guard let path = appState.selectedWorktreePath else { return }
        for repoIdx in appState.repos.indices {
            for wtIdx in appState.repos[repoIdx].worktrees.indices {
                let wt = appState.repos[repoIdx].worktrees[wtIdx]
                if wt.path == path, wt.state == .running,
                   let focused = wt.focusedTerminalID ?? wt.splitTree.allLeaves.first {
                    let newID = TerminalID()
                    appState.repos[repoIdx].worktrees[wtIdx].splitTree =
                        wt.splitTree.inserting(newID, at: focused, direction: direction)
                    _ = terminalManager.createSurface(terminalID: newID, worktreePath: path)
                    appState.repos[repoIdx].worktrees[wtIdx].focusedTerminalID = newID
                    terminalManager.setFocus(newID)
                    return
                }
            }
        }
    }

    private func navigatePane(_ direction: NavigationDirection) {
        guard let path = appState.selectedWorktreePath else { return }
        for repoIdx in appState.repos.indices {
            for wtIdx in appState.repos[repoIdx].worktrees.indices {
                let wt = appState.repos[repoIdx].worktrees[wtIdx]
                if wt.path == path, wt.state == .running {
                    let leaves = wt.splitTree.allLeaves
                    guard leaves.count > 1,
                          let currentIdx = leaves.firstIndex(where: { $0 == wt.focusedTerminalID }) else { return }

                    let nextIdx: Int
                    switch direction {
                    case .left, .up:
                        nextIdx = (currentIdx - 1 + leaves.count) % leaves.count
                    case .right, .down:
                        nextIdx = (currentIdx + 1) % leaves.count
                    }

                    let nextID = leaves[nextIdx]
                    appState.repos[repoIdx].worktrees[wtIdx].focusedTerminalID = nextID
                    terminalManager.setFocus(nextID)
                    return
                }
            }
        }
    }

    private func closeFocusedPane() {
        guard let path = appState.selectedWorktreePath else { return }
        for repoIdx in appState.repos.indices {
            for wtIdx in appState.repos[repoIdx].worktrees.indices {
                let wt = appState.repos[repoIdx].worktrees[wtIdx]
                if wt.path == path, wt.state == .running,
                   let focused = wt.focusedTerminalID {
                    terminalManager.destroySurface(terminalID: focused)
                    let newTree = wt.splitTree.removing(focused)
                    appState.repos[repoIdx].worktrees[wtIdx].splitTree = newTree

                    if newTree.root == nil {
                        appState.repos[repoIdx].worktrees[wtIdx].state = .closed
                    } else {
                        let newFocus = newTree.allLeaves.first
                        appState.repos[repoIdx].worktrees[wtIdx].focusedTerminalID = newFocus
                        if let newFocus { terminalManager.setFocus(newFocus) }
                    }
                    return
                }
            }
        }
    }

    enum NavigationDirection {
        case left, right, up, down
    }

    private func installCLI() {
        let bundleCLI = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Helpers/espalier")
        let symlink = "/usr/local/bin/espalier"

        switch CLIInstaller.plan(source: bundleCLI.path, destination: symlink) {
        case .directSymlink(let source, let destination):
            runDirectSymlink(source: source, destination: destination)
        case .showSudoCommand(let command, let destination):
            showSudoInstallAlert(command: command, destination: destination)
        }
    }

    private func runDirectSymlink(source: String, destination: String) {
        let alert = NSAlert()
        alert.messageText = "Install CLI Tool"
        alert.informativeText = "Create a symlink at \(destination) pointing to the Espalier CLI?"
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
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(command, forType: .string)
        }
    }
}

@MainActor
final class WorktreeMonitorBridge: WorktreeMonitorDelegate {
    let appState: Binding<AppState>

    init(appState: Binding<AppState>) {
        self.appState = appState
    }

    nonisolated func worktreeMonitorDidDetectChange(_ monitor: WorktreeMonitor, repoPath: String) {
        let binding = appState
        Task { @MainActor in
            guard let discovered = try? GitWorktreeDiscovery.discover(repoPath: repoPath) else { return }
            guard let repoIdx = binding.wrappedValue.repos.firstIndex(where: { $0.path == repoPath }) else { return }

            let existing = binding.wrappedValue.repos[repoIdx].worktrees
            let existingPaths = Set(existing.map(\.path))
            let discoveredPaths = Set(discovered.map(\.path))

            for d in discovered where !existingPaths.contains(d.path) {
                let entry = WorktreeEntry(path: d.path, branch: d.branch)
                binding.wrappedValue.repos[repoIdx].worktrees.append(entry)
            }

            for wtIdx in binding.wrappedValue.repos[repoIdx].worktrees.indices {
                let wt = binding.wrappedValue.repos[repoIdx].worktrees[wtIdx]
                if !discoveredPaths.contains(wt.path) && wt.state != .stale {
                    binding.wrappedValue.repos[repoIdx].worktrees[wtIdx].state = .stale
                }
            }
        }
    }

    nonisolated func worktreeMonitorDidDetectDeletion(_ monitor: WorktreeMonitor, worktreePath: String) {
        let binding = appState
        Task { @MainActor in
            for repoIdx in binding.wrappedValue.repos.indices {
                for wtIdx in binding.wrappedValue.repos[repoIdx].worktrees.indices {
                    if binding.wrappedValue.repos[repoIdx].worktrees[wtIdx].path == worktreePath {
                        binding.wrappedValue.repos[repoIdx].worktrees[wtIdx].state = .stale
                    }
                }
            }
        }
    }

    nonisolated func worktreeMonitorDidDetectBranchChange(_ monitor: WorktreeMonitor, worktreePath: String) {
        let binding = appState
        Task { @MainActor in
            for repoIdx in binding.wrappedValue.repos.indices {
                let repoPath = binding.wrappedValue.repos[repoIdx].path
                guard let discovered = try? GitWorktreeDiscovery.discover(repoPath: repoPath) else { continue }
                for wtIdx in binding.wrappedValue.repos[repoIdx].worktrees.indices {
                    if binding.wrappedValue.repos[repoIdx].worktrees[wtIdx].path == worktreePath,
                       let match = discovered.first(where: { $0.path == worktreePath }) {
                        binding.wrappedValue.repos[repoIdx].worktrees[wtIdx].branch = match.branch
                    }
                }
            }
        }
    }
}
