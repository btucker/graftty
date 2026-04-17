import SwiftUI
import AppKit
import EspalierKit

/// Holds long-lived non-SwiftUI services for the app. Retained for the lifetime of
/// `EspalierApp` so weak delegates (e.g. `WorktreeMonitor.delegate`) stay alive.
@MainActor
final class AppServices {
    let socketServer: SocketServer
    let worktreeMonitor: WorktreeMonitor
    let statsStore: WorktreeStatsStore
    var worktreeMonitorBridge: WorktreeMonitorBridge?
    var statsPollTimer: Timer?

    init(socketPath: String) {
        self.socketServer = SocketServer(socketPath: socketPath)
        self.worktreeMonitor = WorktreeMonitor()
        self.statsStore = WorktreeStatsStore()
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
            MainWindow(
                appState: $appState,
                terminalManager: terminalManager,
                statsStore: services.statsStore,
                worktreeMonitor: services.worktreeMonitor
            )
                .onAppear { startup() }
                .onChange(of: appState) { _, newState in
                    try? newState.save(to: AppState.defaultDirectory)
                }
        }
        // Hide the macOS title bar so the breadcrumb row sits directly
        // under the traffic lights — Andy wanted a terminal-multiplexer
        // look, not a generic Cocoa app frame. Content can flow under
        // the title bar area; MainWindow leaves ~72pt of leading space
        // on the breadcrumb for the traffic lights.
        .windowStyle(.hiddenTitleBar)
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

        // Route context-menu split requests through the same insertion code
        // path that Cmd+D uses, but targeting the *menu's* surface rather
        // than the currently-focused one — the two can differ if the user
        // right-clicks an unfocused pane.
        terminalManager.onSplitRequest = { [appState = $appState, tm = terminalManager] terminalID, direction in
            MainActor.assumeIsolated {
                Self.splitPane(
                    appState: appState,
                    terminalManager: tm,
                    targetID: terminalID,
                    split: direction
                )
            }
        }

        // Shell-exit (or libghostty-initiated close) → remove the pane from
        // the tree and free the surface. Same logic Cmd+W uses, but keyed
        // on an arbitrary terminalID rather than the currently-focused one.
        terminalManager.onCloseRequest = { [appState = $appState, tm = terminalManager] terminalID in
            MainActor.assumeIsolated {
                Self.closePane(
                    appState: appState,
                    terminalManager: tm,
                    targetID: terminalID
                )
            }
        }

        // Shell reported a new PWD (OSC 7) → if it now sits inside a
        // different known worktree, re-home the pane under that worktree
        // in the sidebar. Common trigger: Claude Code or `cd` into a
        // worktree directory, and the pane should "follow" visually.
        terminalManager.onPWDChange = { [appState = $appState, tm = terminalManager] terminalID, pwd in
            MainActor.assumeIsolated {
                Self.reassignPaneByPWD(
                    appState: appState,
                    terminalManager: tm,
                    terminalID: terminalID,
                    newPWD: pwd
                )
            }
        }

        // Shell integration semantic pings → sidebar attention badge on
        // the owning worktree. The badge is auto-clearing (3s) so it
        // behaves like a "ping", not a permanent state the user has to
        // dismiss. Non-zero exit codes get a longer (8s) dwell so the
        // user has a chance to notice errors across a worktree they're
        // not currently viewing.
        terminalManager.onCommandFinished = { [appState = $appState] terminalID, exitCode, _ in
            MainActor.assumeIsolated {
                Self.setAttentionForTerminal(
                    appState: appState,
                    terminalID: terminalID,
                    text: exitCode == 0 ? "✓" : "!",
                    clearAfter: exitCode == 0 ? 3 : 8
                )
            }
        }
        // PROGRESS_REPORT intentionally unhandled — shell-integration
        // progress pings (OSC 9;4 from tools emitting indeterminate or
        // percent status) were too loud relative to the urgency they
        // convey. The underlying plumbing in TerminalManager stays
        // wired; we can revisit with a dedicated, less-aggressive
        // visual if the need comes back.

        try? services.socketServer.start()
        // SocketServer already dispatches onMessage to the main queue.
        let binding = $appState
        let tm = terminalManager
        services.socketServer.onMessage = { message in
            MainActor.assumeIsolated {
                Self.handleNotification(message, appState: binding, terminalManager: tm)
            }
        }

        let bridge = WorktreeMonitorBridge(
            appState: $appState,
            statsStore: services.statsStore
        )
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
        for repo in appState.repos {
            for wt in repo.worktrees where wt.state != .stale {
                services.statsStore.refresh(worktreePath: wt.path, repoPath: repo.path)
            }
        }

        // 60s poll catches origin/<default> drift from external `git fetch`
        // invocations — WorktreeMonitor's HEAD watcher only fires when this
        // worktree's HEAD moves, not when the remote ref does.
        let statsBinding = $appState
        let statsStore = services.statsStore
        services.statsPollTimer = Timer.scheduledTimer(
            withTimeInterval: 60,
            repeats: true
        ) { _ in
            MainActor.assumeIsolated {
                for repo in statsBinding.wrappedValue.repos {
                    for wt in repo.worktrees where wt.state != .stale {
                        statsStore.refresh(worktreePath: wt.path, repoPath: repo.path)
                    }
                }
            }
        }

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

        // Tell libghostty which pane is active for the currently-selected
        // worktree, so the cursor blinks in the right place on launch.
        // AppKit first-responder follows via `SurfaceNSView.viewDidMoveToWindow`
        // once SwiftUI attaches the view.
        if let path = appState.selectedWorktreePath,
           let wt = appState.worktree(forPath: path),
           wt.state == .running,
           let target = wt.focusedTerminalID ?? wt.splitTree.allLeaves.first {
            terminalManager.setFocus(target)
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
                    // Cmd+D = "Split Horizontally" = new pane to the right;
                    // Cmd+Shift+D = "Split Vertically" = new pane below. Map
                    // to `PaneSplit` so we reuse the same insertion logic as
                    // the context menu.
                    let split: PaneSplit = direction == .horizontal ? .right : .down
                    Self.splitPane(
                        appState: $appState,
                        terminalManager: terminalManager,
                        targetID: focused,
                        split: split
                    )
                    return
                }
            }
        }
    }

    /// Shared split implementation used by both the menu shortcuts and the
    /// right-click context menu. Finds the worktree that currently owns the
    /// target terminal, inserts a new leaf adjacent to it, spawns a surface,
    /// and moves focus to the new pane.
    @MainActor
    fileprivate static func splitPane(
        appState: Binding<AppState>,
        terminalManager: TerminalManager,
        targetID: TerminalID,
        split: PaneSplit
    ) {
        for repoIdx in appState.wrappedValue.repos.indices {
            for wtIdx in appState.wrappedValue.repos[repoIdx].worktrees.indices {
                let wt = appState.wrappedValue.repos[repoIdx].worktrees[wtIdx]
                guard wt.state == .running, wt.splitTree.allLeaves.contains(targetID) else { continue }

                let direction: SplitDirection = (split == .right || split == .left) ? .horizontal : .vertical
                let newID = TerminalID()
                let newTree: SplitTree
                switch split {
                case .right, .down:
                    newTree = wt.splitTree.inserting(newID, at: targetID, direction: direction)
                case .left, .up:
                    newTree = wt.splitTree.insertingBefore(newID, at: targetID, direction: direction)
                }
                appState.wrappedValue.repos[repoIdx].worktrees[wtIdx].splitTree = newTree
                _ = terminalManager.createSurface(terminalID: newID, worktreePath: wt.path)
                appState.wrappedValue.repos[repoIdx].worktrees[wtIdx].focusedTerminalID = newID
                terminalManager.setFocus(newID)
                return
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
                    Self.closePane(
                        appState: $appState,
                        terminalManager: terminalManager,
                        targetID: focused
                    )
                    return
                }
            }
        }
    }

    /// Find the worktree that owns `terminalID` and set its attention
    /// badge. No-op if the terminal isn't in any worktree (e.g., because
    /// it was just destroyed). Auto-clears after `clearAfter` seconds.
    @MainActor
    fileprivate static func setAttentionForTerminal(
        appState: Binding<AppState>,
        terminalID: TerminalID,
        text: String,
        clearAfter: TimeInterval
    ) {
        for repoIdx in appState.wrappedValue.repos.indices {
            for wtIdx in appState.wrappedValue.repos[repoIdx].worktrees.indices {
                if appState.wrappedValue.repos[repoIdx].worktrees[wtIdx]
                    .splitTree.allLeaves.contains(terminalID) {
                    appState.wrappedValue.repos[repoIdx].worktrees[wtIdx].attention = Attention(
                        text: text,
                        timestamp: Date(),
                        clearAfter: clearAfter
                    )
                    let path = appState.wrappedValue.repos[repoIdx].worktrees[wtIdx].path
                    DispatchQueue.main.asyncAfter(deadline: .now() + clearAfter) {
                        for ri in appState.wrappedValue.repos.indices {
                            for wi in appState.wrappedValue.repos[ri].worktrees.indices {
                                if appState.wrappedValue.repos[ri].worktrees[wi].path == path {
                                    appState.wrappedValue.repos[ri].worktrees[wi].attention = nil
                                }
                            }
                        }
                    }
                    return
                }
            }
        }
    }

    /// When a pane reports a new working directory via OSC 7, check whether
    /// it now lives inside a different worktree than where it's currently
    /// parented in the sidebar — and if so, move it. Matching is
    /// longest-prefix so nested worktrees (e.g., main checkout at `/r` and
    /// a linked worktree at `/r/wt/feature`) resolve to the more specific
    /// path. A PWD outside every known worktree leaves the pane where it
    /// was — we don't invent a new sidebar entry just because a shell
    /// wandered off.
    @MainActor
    fileprivate static func reassignPaneByPWD(
        appState: Binding<AppState>,
        terminalManager: TerminalManager,
        terminalID: TerminalID,
        newPWD: String
    ) {
        // Find the currently-hosting worktree (by scanning splitTrees) so
        // we can compare against the target worktree and short-circuit if
        // nothing has changed.
        var currentRepoIdx: Int?
        var currentWorktreeIdx: Int?
        for (ri, repo) in appState.wrappedValue.repos.enumerated() {
            for (wi, wt) in repo.worktrees.enumerated() where wt.splitTree.allLeaves.contains(terminalID) {
                currentRepoIdx = ri
                currentWorktreeIdx = wi
            }
        }
        guard let currentRepoIdx, let currentWorktreeIdx else { return }

        // Longest-prefix match across all worktrees of all repos. `bestLen`
        // ensures a nested worktree beats a containing repo's main checkout.
        var bestRepoIdx: Int?
        var bestWorktreeIdx: Int?
        var bestLen = 0
        let normalizedPWD = Self.withTrailingSlash(newPWD)
        for (ri, repo) in appState.wrappedValue.repos.enumerated() {
            for (wi, wt) in repo.worktrees.enumerated() {
                let candidate = Self.withTrailingSlash(wt.path)
                if normalizedPWD.hasPrefix(candidate), candidate.count > bestLen {
                    bestLen = candidate.count
                    bestRepoIdx = ri
                    bestWorktreeIdx = wi
                }
            }
        }

        guard let targetRepoIdx = bestRepoIdx,
              let targetWorktreeIdx = bestWorktreeIdx,
              (targetRepoIdx, targetWorktreeIdx) != (currentRepoIdx, currentWorktreeIdx)
        else { return }

        // Remember where this pane was sitting in the source tree *before*
        // we remove it, so a later return trip can land it in (roughly)
        // the same spot.
        let sourceWt = appState.wrappedValue.repos[currentRepoIdx].worktrees[currentWorktreeIdx]
        terminalManager.rememberPosition(
            terminalID: terminalID,
            worktreePath: sourceWt.path,
            in: sourceWt.splitTree
        )

        // Remove from source tree; if the source becomes empty, transition
        // its worktree back to .closed so the sidebar reflects that no
        // panes live there anymore.
        let sourceTree = sourceWt.splitTree.removing(terminalID)
        appState.wrappedValue.repos[currentRepoIdx].worktrees[currentWorktreeIdx].splitTree = sourceTree
        if sourceTree.root == nil {
            appState.wrappedValue.repos[currentRepoIdx].worktrees[currentWorktreeIdx].state = .closed
            appState.wrappedValue.repos[currentRepoIdx].worktrees[currentWorktreeIdx].focusedTerminalID = nil
        } else if sourceWt.focusedTerminalID == terminalID {
            appState.wrappedValue.repos[currentRepoIdx].worktrees[currentWorktreeIdx].focusedTerminalID =
                sourceTree.allLeaves.first
        }

        // Graft onto the target tree. Prefer a previously-remembered
        // position (pane is returning to a worktree it once occupied); if
        // the anchor from that memory is still present, reinsert there so
        // the layout feels like the pane "came back to its seat." Fall
        // back to inserting at an arbitrary leaf when no usable
        // breadcrumb exists.
        let targetWt = appState.wrappedValue.repos[targetRepoIdx].worktrees[targetWorktreeIdx]
        let targetTree: SplitTree
        let remembered = terminalManager.rememberedPosition(
            terminalID: terminalID,
            worktreePath: targetWt.path
        )
        if let remembered, targetWt.splitTree.allLeaves.contains(remembered.anchorID) {
            switch remembered.placement {
            case .before:
                targetTree = targetWt.splitTree.insertingBefore(
                    terminalID,
                    at: remembered.anchorID,
                    direction: remembered.direction
                )
            case .after:
                targetTree = targetWt.splitTree.inserting(
                    terminalID,
                    at: remembered.anchorID,
                    direction: remembered.direction
                )
            }
            terminalManager.forgetPosition(terminalID: terminalID, worktreePath: targetWt.path)
        } else if let anchor = targetWt.splitTree.allLeaves.first {
            targetTree = targetWt.splitTree.inserting(terminalID, at: anchor, direction: .horizontal)
        } else {
            targetTree = SplitTree(root: .leaf(terminalID))
        }
        appState.wrappedValue.repos[targetRepoIdx].worktrees[targetWorktreeIdx].splitTree = targetTree
        appState.wrappedValue.repos[targetRepoIdx].worktrees[targetWorktreeIdx].state = .running
        appState.wrappedValue.repos[targetRepoIdx].worktrees[targetWorktreeIdx].focusedTerminalID = terminalID

        // Follow the pane with the UI: switch the selected worktree to the
        // one the terminal just moved into, and re-establish libghostty +
        // AppKit focus so typing continues to route to this pane without
        // the user having to click. The previous sidebar highlight (on the
        // source worktree) naturally moves with `selectedWorktreePath`.
        let targetPath = appState.wrappedValue.repos[targetRepoIdx].worktrees[targetWorktreeIdx].path
        appState.wrappedValue.selectedWorktreePath = targetPath
        terminalManager.setFocus(terminalID)
    }

    /// Ensure a path ends with `/` so prefix matching can't falsely match
    /// `/r/feat` against `/r/feature`. We normalize both sides.
    private static func withTrailingSlash(_ path: String) -> String {
        path.hasSuffix("/") ? path : path + "/"
    }

    /// Shared close-pane implementation used by Cmd+W and libghostty's
    /// `close_surface_cb` (shell exit). Removes the pane from its worktree's
    /// split tree, destroys the surface, promotes focus to a sibling, and
    /// transitions the worktree to `.closed` when the last pane goes away.
    /// Idempotent: no-op if the terminal isn't in any tree.
    @MainActor
    fileprivate static func closePane(
        appState: Binding<AppState>,
        terminalManager: TerminalManager,
        targetID: TerminalID
    ) {
        for repoIdx in appState.wrappedValue.repos.indices {
            for wtIdx in appState.wrappedValue.repos[repoIdx].worktrees.indices {
                let wt = appState.wrappedValue.repos[repoIdx].worktrees[wtIdx]
                guard wt.splitTree.allLeaves.contains(targetID) else { continue }

                terminalManager.destroySurface(terminalID: targetID)
                let newTree = wt.splitTree.removing(targetID)
                appState.wrappedValue.repos[repoIdx].worktrees[wtIdx].splitTree = newTree

                if newTree.root == nil {
                    appState.wrappedValue.repos[repoIdx].worktrees[wtIdx].state = .closed
                    appState.wrappedValue.repos[repoIdx].worktrees[wtIdx].focusedTerminalID = nil
                } else {
                    let newFocus = newTree.allLeaves.first
                    appState.wrappedValue.repos[repoIdx].worktrees[wtIdx].focusedTerminalID = newFocus
                    if let newFocus { terminalManager.setFocus(newFocus) }
                }
                return
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
    let statsStore: WorktreeStatsStore

    init(appState: Binding<AppState>, statsStore: WorktreeStatsStore) {
        self.appState = appState
        self.statsStore = statsStore
    }

    /// Called when `.git/worktrees/` changes (new worktree added, existing
    /// one removed externally). After reconciling appState, refresh stats
    /// for every non-stale worktree in the repo — new worktrees need their
    /// initial stats, removed ones will be marked stale (and stats cleared
    /// by `worktreeMonitorDidDetectDeletion`).
    nonisolated func worktreeMonitorDidDetectChange(_ monitor: WorktreeMonitor, repoPath: String) {
        let binding = appState
        let store = statsStore
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

            // Register FS watches for every known worktree in this repo.
            // watchWorktreePath / watchHeadRef are idempotent, but this
            // catches newly-discovered worktrees (from external CLI
            // `git worktree add`) that otherwise wouldn't get HEAD
            // tracking until the app restarted.
            for wt in binding.wrappedValue.repos[repoIdx].worktrees where wt.state != .stale {
                monitor.watchWorktreePath(wt.path)
                monitor.watchHeadRef(worktreePath: wt.path, repoPath: repoPath)
            }

            // Refresh stats for all non-stale worktrees in this repo.
            for wt in binding.wrappedValue.repos[repoIdx].worktrees where wt.state != .stale {
                store.refresh(worktreePath: wt.path, repoPath: repoPath)
            }
        }
    }

    nonisolated func worktreeMonitorDidDetectDeletion(_ monitor: WorktreeMonitor, worktreePath: String) {
        let binding = appState
        let store = statsStore
        Task { @MainActor in
            for repoIdx in binding.wrappedValue.repos.indices {
                for wtIdx in binding.wrappedValue.repos[repoIdx].worktrees.indices {
                    if binding.wrappedValue.repos[repoIdx].worktrees[wtIdx].path == worktreePath {
                        binding.wrappedValue.repos[repoIdx].worktrees[wtIdx].state = .stale
                    }
                }
            }
            store.clear(worktreePath: worktreePath)
        }
    }

    nonisolated func worktreeMonitorDidDetectBranchChange(_ monitor: WorktreeMonitor, worktreePath: String) {
        let binding = appState
        let store = statsStore
        Task { @MainActor in
            for repoIdx in binding.wrappedValue.repos.indices {
                let repoPath = binding.wrappedValue.repos[repoIdx].path
                guard let discovered = try? GitWorktreeDiscovery.discover(repoPath: repoPath) else { continue }
                for wtIdx in binding.wrappedValue.repos[repoIdx].worktrees.indices {
                    if binding.wrappedValue.repos[repoIdx].worktrees[wtIdx].path == worktreePath,
                       let match = discovered.first(where: { $0.path == worktreePath }) {
                        binding.wrappedValue.repos[repoIdx].worktrees[wtIdx].branch = match.branch
                        // HEAD moved — recompute stats for this worktree.
                        store.refresh(worktreePath: worktreePath, repoPath: repoPath)
                    }
                }
            }
        }
    }
}
