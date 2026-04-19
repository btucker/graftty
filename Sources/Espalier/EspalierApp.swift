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
    let prStatusStore: PRStatusStore
    var worktreeMonitorBridge: WorktreeMonitorBridge?

    init(socketPath: String) {
        self.socketServer = SocketServer(socketPath: socketPath)
        self.worktreeMonitor = WorktreeMonitor()
        self.statsStore = WorktreeStatsStore()
        self.prStatusStore = PRStatusStore()
    }
}

@main
struct EspalierApp: App {
    @State private var appState: AppState
    @StateObject private var terminalManager: TerminalManager
    @StateObject private var webController: WebServerController
    private let services: AppServices

    init() {
        // Espalier is single-instance: the state.json, the espalier.sock
        // listener, and (most visibly) the per-pane zmx session names are
        // shared-global resources keyed off paths that don't vary between
        // app instances. Two Espaliers both attached to the same zmx
        // session will both echo the shell's output and both forward
        // keystrokes into the same PTY. Rather than isolate those three
        // resources per-instance (large refactor), we enforce one-at-a-time
        // here. Launch Services already dedupes normal Dock/Spotlight
        // opens; this guard catches `open -n` and same-bundle-id dev
        // relaunches.
        Self.terminateIfAnotherInstanceIsRunning()

        let loaded = AppState.loadOrFreshBackingUpCorruption(from: AppState.defaultDirectory)
        _appState = State(initialValue: loaded)

        let socketPath = AppState.defaultDirectory.appendingPathComponent("espalier.sock").path
        _terminalManager = StateObject(wrappedValue: TerminalManager(socketPath: socketPath))
        services = AppServices(socketPath: socketPath)

        // Web access server — reconstruct the same zmx paths that `startup()`
        // computes so the WebServerController's child `zmx attach` invocations
        // hit the same ZMX_DIR as panes spawned from the app UI. Keeping the
        // path derivation here (rather than routing it through AppServices)
        // keeps the controller's lifetime tied to the SwiftUI App via
        // @StateObject, which is what Settings scene re-entry expects.
        let appSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let zmxDir = appSupport
            .appendingPathComponent("Espalier", isDirectory: true)
            .appendingPathComponent("zmx", isDirectory: true)
        let zmxExe = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Helpers/zmx")
        _webController = StateObject(wrappedValue: WebServerController(
            settings: WebAccessSettings.shared,
            zmxExecutable: zmxExe,
            zmxDir: zmxDir
        ))
    }

    /// If another Espalier process with our `CFBundleIdentifier` is
    /// already running, bring it to the front and exit our own process
    /// before any state, sockets, or zmx clients are created. Uses
    /// `exit(0)` instead of `NSApp.terminate` because we run before
    /// NSApplication has an app delegate, and because we have no
    /// allocated resources that need graceful teardown yet.
    private static func terminateIfAnotherInstanceIsRunning() {
        let myBundleID = Bundle.main.bundleIdentifier ?? "com.espalier.app"
        let myPID = ProcessInfo.processInfo.processIdentifier
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: myBundleID)
            .filter { $0.processIdentifier != myPID }
        guard let existing = others.first else { return }
        existing.activate()
        exit(0)
    }

    var body: some Scene {
        WindowGroup {
            MainWindow(
                appState: $appState,
                terminalManager: terminalManager,
                statsStore: services.statsStore,
                prStatusStore: services.prStatusStore,
                worktreeMonitor: services.worktreeMonitor
            )
                .environmentObject(webController)
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
                // "Add Repository..." keeps its hardcoded Cmd+Shift+O —
                // it's an Espalier-specific action with no Ghostty equivalent.
                Button("Add Repository...") {
                    // MainWindow handles the file picker via its own button.
                    // This menu item is a placeholder for the standard shortcut.
                }
                .keyboardShortcut("o", modifiers: [.command, .shift])

                Divider()

                bridgedButton("Split Right", action: .newSplitRight) { handleSplit(.right) }
                bridgedButton("Split Left",  action: .newSplitLeft)  { handleSplit(.left) }
                bridgedButton("Split Down",  action: .newSplitDown)  { handleSplit(.down) }
                bridgedButton("Split Up",    action: .newSplitUp)    { handleSplit(.up) }

                Divider()

                bridgedButton("Focus Pane Left",  action: .gotoSplitLeft)   { handleNavigate(.left) }
                bridgedButton("Focus Pane Right", action: .gotoSplitRight)  { handleNavigate(.right) }
                bridgedButton("Focus Pane Up",    action: .gotoSplitUp)     { handleNavigate(.up) }
                bridgedButton("Focus Pane Down",  action: .gotoSplitDown)   { handleNavigate(.down) }
                bridgedButton("Previous Pane",    action: .gotoSplitPrevious) { handleNavigateTreeOrder(forward: false) }
                bridgedButton("Next Pane",        action: .gotoSplitNext)     { handleNavigateTreeOrder(forward: true) }

                Divider()

                bridgedButton("Zoom Split",      action: .toggleSplitZoom) { handleToggleZoom() }
                bridgedButton("Equalize Splits", action: .equalizeSplits)  { handleEqualizeSplits() }

                Divider()

                bridgedButton("Close Pane", action: .closeSurface) { handleClosePane() }
            }

            CommandGroup(after: .appInfo) {
                Button("Install CLI Tool...") {
                    installCLI()
                }
                bridgedButton("Reload Ghostty Config", action: .reloadConfig) { handleReloadConfig() }
            }
        }

        // Settings scene — existing General pane plus the Phase 2 Web Access
        // pane. WebServerController is injected so WebSettingsPane can read
        // `.status` / `.currentURL`, and so toggling `WebAccessSettings.isEnabled`
        // triggers the controller's `reconcile()` via its Combine subscription.
        Settings {
            TabView {
                SettingsView()
                    .tabItem { Label("General", systemImage: "gear") }
                WebSettingsPane()
                    .environmentObject(webController)
                    .tabItem { Label("Web Access", systemImage: "network") }
            }
        }
    }

    private func startup() {
        let zmxBinary = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Helpers/zmx")
        let appSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let zmxDir = appSupport
            .appendingPathComponent("Espalier", isDirectory: true)
            .appendingPathComponent("zmx", isDirectory: true)
        try? FileManager.default.createDirectory(at: zmxDir, withIntermediateDirectories: true)
        let zmxLauncher = ZmxLauncher(executable: zmxBinary, zmxDir: zmxDir)
        terminalManager.zmxLauncher = zmxLauncher

        if !zmxLauncher.isAvailable {
            DispatchQueue.main.async {
                ZmxFallbackBanner.presentIfNeeded()
            }
        }

        terminalManager.initialize()

        // Route context-menu split requests through the same insertion code
        // path that Cmd+D uses, but targeting the *menu's* surface rather
        // than the currently-focused one — the two can differ if the user
        // right-clicks an unfocused pane.
        terminalManager.onSplitRequest = { [appState = $appState, tm = terminalManager] terminalID, direction in
            MainActor.assumeIsolated {
                _ = Self.splitPane(
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
                // ZMX-7.2: if Espalier didn't initiate this close and the
                // daemon is gone, rebuild in place rather than destroying.
                if !tm.claimIntentionalClose(terminalID),
                   tm.isSessionMissing(for: terminalID) {
                    tm.restartSurface(for: terminalID)
                } else {
                    Self.closePane(
                        appState: appState,
                        terminalManager: tm,
                        targetID: terminalID
                    )
                }
            }
        }

        terminalManager.onGotoSplit = { [appState = $appState, tm = terminalManager] terminalID, direction in
            MainActor.assumeIsolated {
                Self.navigatePane(
                    appState: appState,
                    terminalManager: tm,
                    from: terminalID,
                    direction: direction
                )
            }
        }

        terminalManager.onGotoSplitOrder = { [appState = $appState, tm = terminalManager] terminalID, forward in
            MainActor.assumeIsolated {
                Self.navigatePaneInTreeOrder(
                    appState: appState,
                    terminalManager: tm,
                    from: terminalID,
                    forward: forward
                )
            }
        }

        terminalManager.onToggleZoom = { [appState = $appState] terminalID in
            MainActor.assumeIsolated {
                Self.toggleZoom(appState: appState, on: terminalID)
            }
        }

        terminalManager.onResizeSplit = { [appState = $appState] terminalID, direction, amount in
            MainActor.assumeIsolated {
                Self.resizeSplit(
                    appState: appState,
                    target: terminalID,
                    direction: direction,
                    pixels: amount
                )
            }
        }

        terminalManager.onEqualizeSplits = { [appState = $appState] terminalID in
            MainActor.assumeIsolated {
                Self.equalizeSplits(appState: appState, around: terminalID)
            }
        }

        // libghostty-spm doesn't expose a reload C API — rebuild the bridge
        // from the live config object so menu shortcuts stay consistent.
        terminalManager.onReloadConfig = { [tm = terminalManager] in
            MainActor.assumeIsolated {
                tm.rebuildKeybindBridge()
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

        // First prompt on a newly-ready pane → maybe type the user's
        // default command. `maybeRunDefaultCommand` consults UserDefaults
        // and the TerminalManager's first-pane / rehydration markers to
        // decide; most of the time it's a no-op.
        terminalManager.onShellReady = { [tm = terminalManager] terminalID in
            MainActor.assumeIsolated {
                Self.maybeRunDefaultCommand(
                    terminalManager: tm,
                    terminalID: terminalID
                )
            }
        }

        try? services.socketServer.start()
        // SocketServer already dispatches onMessage to the main queue.
        let binding = $appState
        let tm = terminalManager
        services.socketServer.onMessage = { message in
            MainActor.assumeIsolated {
                Self.handleNotification(message, appState: binding, terminalManager: tm)
            }
        }
        services.socketServer.onRequest = { message in
            MainActor.assumeIsolated {
                Self.handlePaneRequest(message, appState: binding, terminalManager: tm)
            }
        }

        let bridge = WorktreeMonitorBridge(
            appState: $appState,
            statsStore: services.statsStore,
            prStatusStore: services.prStatusStore
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

        // Start the stats poller: a 5s ticker that, per-repo, periodically
        // `git fetch`es the default branch and recomputes divergence stats
        // for every non-stale worktree. Replaces the legacy 60s Timer and
        // additionally surfaces origin-side drift that WorktreeMonitor's
        // per-worktree HEAD watcher can't see.
        services.statsStore.startPolling(appState: appState)

        let prTicker = PollingTicker(
            interval: .seconds(5),
            pauseWhenInactive: { [prStatusStore = services.prStatusStore] in
                // Keep polling when at least one tracked PR has pending CI, so the
                // "green light" arrives even while the user is in another app.
                !prStatusStore.infos.values.contains(where: { $0.checks == .pending })
            }
        )
        services.prStatusStore.start(
            ticker: prTicker,
            getRepos: { binding.wrappedValue.repos }
        )

        restoreRunningWorktrees()
    }

    private func reconcileOnLaunch() {
        let binding = $appState
        let statsStore = services.statsStore
        Task {
            for repoIdx in binding.wrappedValue.repos.indices {
                let repoPath = binding.wrappedValue.repos[repoIdx].path
                guard let discovered = try? await GitWorktreeDiscovery.discover(repoPath: repoPath) else { continue }
                let discoveredPaths = Set(discovered.map(\.path))

                let existingPaths = Set(binding.wrappedValue.repos[repoIdx].worktrees.map(\.path))
                for d in discovered where !existingPaths.contains(d.path) {
                    binding.wrappedValue.repos[repoIdx].worktrees.append(
                        WorktreeEntry(path: d.path, branch: d.branch)
                    )
                }

                for wtIdx in binding.wrappedValue.repos[repoIdx].worktrees.indices {
                    let wt = binding.wrappedValue.repos[repoIdx].worktrees[wtIdx]
                    if !discoveredPaths.contains(wt.path) && wt.state != .stale {
                        binding.wrappedValue.repos[repoIdx].worktrees[wtIdx].state = .stale
                    } else if discoveredPaths.contains(wt.path) && wt.state == .stale {
                        // Stale entry is back in git's view — resurrect
                        // to .closed per GIT-3.7. Same rule as the
                        // `.git/worktrees/`-tick reconcile path.
                        binding.wrappedValue.repos[repoIdx].worktrees[wtIdx].state = .closed
                    }
                }

                for wtIdx in binding.wrappedValue.repos[repoIdx].worktrees.indices {
                    if let match = discovered.first(where: {
                        $0.path == binding.wrappedValue.repos[repoIdx].worktrees[wtIdx].path
                    }) {
                        binding.wrappedValue.repos[repoIdx].worktrees[wtIdx].branch = match.branch
                    }
                }

                // Kick initial stats refresh for this repo's non-stale
                // worktrees, after reconciliation has populated new entries
                // and marked externally-deleted ones stale. This preserves
                // the pre-migration "reconcile, then refresh" ordering
                // without blocking startup.
                for wt in binding.wrappedValue.repos[repoIdx].worktrees where wt.state != .stale {
                    statsStore.refresh(worktreePath: wt.path, repoPath: repoPath)
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
                    // Mark every restored leaf as rehydrated *before*
                    // surface creation so the first-PWD event (which
                    // triggers onShellReady) finds wasRehydrated == true
                    // and short-circuits command injection. Without this
                    // guard, relaunching Espalier would type the default
                    // command on top of whatever process is already
                    // running inside the persisted zmx session.
                    for leafID in appState.repos[repoIdx].worktrees[wtIdx].splitTree.allLeaves {
                        terminalManager.markRehydrated(leafID)
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
            // Defense-in-depth behind the CLI's ATTN-1.7 guard: reject
            // empty / whitespace-only text silently so a raw socket
            // client (`nc -U`, custom script, web surface) can't write
            // an invisible red capsule Andy can't read or dismiss.
            guard Attention.isValidText(text) else { return }
            // Normalize the requested auto-clear duration against the
            // server's contract: ≤0 → nil (STATE-2.8), >24h → clamped
            // to 24h (STATE-2.9). A non-CLI socket client can still
            // send ridiculous values; `effectiveClearAfter` makes the
            // server a single source of truth for what actually
            // schedules.
            let effectiveClearAfter = Attention.effectiveClearAfter(clearAfter)
            // Pin the timestamp the attention carries AND the auto-clear
            // timer closes over, so the timer can verify it's still OUR
            // notification when it fires (cf. WorktreeEntry.clearAttentionIfTimestamp).
            let stamp = Date()
            for repoIdx in appState.wrappedValue.repos.indices {
                for wtIdx in appState.wrappedValue.repos[repoIdx].worktrees.indices {
                    if appState.wrappedValue.repos[repoIdx].worktrees[wtIdx].path == path {
                        appState.wrappedValue.repos[repoIdx].worktrees[wtIdx].attention = Attention(
                            text: text,
                            timestamp: stamp,
                            clearAfter: effectiveClearAfter
                        )

                        if let effectiveClearAfter {
                            DispatchQueue.main.asyncAfter(deadline: .now() + effectiveClearAfter) {
                                for ri in appState.wrappedValue.repos.indices {
                                    for wi in appState.wrappedValue.repos[ri].worktrees.indices {
                                        if appState.wrappedValue.repos[ri].worktrees[wi].path == path {
                                            appState.wrappedValue.repos[ri].worktrees[wi].clearAttentionIfTimestamp(stamp)
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
        case .listPanes, .addPane, .closePane:
            // Request-style messages are handled by handlePaneRequest via
            // the SocketServer.onRequest callback; they are no-ops on the
            // fire-and-forget onMessage path.
            break
        }
    }

    /// Dispatcher for request-style messages from the CLI. Returns a
    /// `ResponseMessage` the server writes back to the client. Must run
    /// on the main actor because it touches `appState` and `terminalManager`.
    @MainActor
    fileprivate static func handlePaneRequest(
        _ message: NotificationMessage,
        appState: Binding<AppState>,
        terminalManager: TerminalManager
    ) -> ResponseMessage? {
        switch message {
        case .listPanes(let path):
            return listPanes(path: path, appState: appState, terminalManager: terminalManager)
        case .addPane(let path, let direction, let command):
            return addPane(path: path, direction: direction, command: command,
                           appState: appState, terminalManager: terminalManager)
        case .closePane(let path, let index):
            return closePaneByIndex(path: path, index: index,
                                    appState: appState, terminalManager: terminalManager)
        case .notify, .clear:
            // Fire-and-forget cases — no response. `onMessage` already handled them.
            return nil
        }
    }

    @MainActor
    private static func listPanes(
        path: String,
        appState: Binding<AppState>,
        terminalManager: TerminalManager
    ) -> ResponseMessage {
        guard let wt = appState.wrappedValue.worktree(forPath: path) else {
            return .error("not tracked")
        }
        let leaves = wt.splitTree.allLeaves
        let panes = leaves.enumerated().map { (i, terminalID) -> PaneInfo in
            // Use the derived label (title → PWD basename → nil) so the
            // CLI sees the same fallback chain the sidebar renders. Map
            // the view-level empty sentinel back to nil for the CLI
            // contract "title is nil when unknown".
            let display = terminalManager.displayTitle(for: terminalID)
            return PaneInfo(
                id: i + 1,
                title: display.isEmpty ? nil : display,
                focused: terminalID == wt.focusedTerminalID
            )
        }
        return .paneList(panes)
    }

    @MainActor
    private static func addPane(
        path: String,
        direction: PaneSplit,
        command: String?,
        appState: Binding<AppState>,
        terminalManager: TerminalManager
    ) -> ResponseMessage {
        guard let wt = appState.wrappedValue.worktree(forPath: path) else {
            return .error("not tracked")
        }
        guard wt.state == .running else {
            return .error("worktree not running")
        }
        guard let targetID = wt.focusedTerminalID ?? wt.splitTree.allLeaves.first else {
            return .error("no panes to split")
        }
        guard let newID = splitPane(
            appState: appState,
            terminalManager: terminalManager,
            targetID: targetID,
            split: direction
        ) else {
            return .error("split failed")
        }
        if let command, !command.isEmpty {
            terminalManager.handle(for: newID)?.typeText(command + "\r")
        }
        return .ok
    }

    @MainActor
    private static func closePaneByIndex(
        path: String,
        index: Int,
        appState: Binding<AppState>,
        terminalManager: TerminalManager
    ) -> ResponseMessage {
        guard let wt = appState.wrappedValue.worktree(forPath: path) else {
            return .error("not tracked")
        }
        guard let targetID = wt.splitTree.leaf(atPaneID: index) else {
            return .error("no pane with id \(index) in this worktree")
        }
        closePane(appState: appState, terminalManager: terminalManager, targetID: targetID)
        return .ok
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
    @discardableResult
    fileprivate static func splitPane(
        appState: Binding<AppState>,
        terminalManager: TerminalManager,
        targetID: TerminalID,
        split: PaneSplit
    ) -> TerminalID? {
        for repoIdx in appState.wrappedValue.repos.indices {
            for wtIdx in appState.wrappedValue.repos[repoIdx].worktrees.indices {
                let wt = appState.wrappedValue.repos[repoIdx].worktrees[wtIdx]
                guard wt.state == .running, wt.splitTree.containsLeaf(targetID) else { continue }

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
                return newID
            }
        }
        return nil
    }

    /// Find the worktree that owns `terminalID` and set the attention
    /// badge on *that specific pane*. The shell-integration event that
    /// drives this callback (`COMMAND_FINISHED`) is emitted by one
    /// concrete pane, so the badge belongs on its row and nobody else's —
    /// writing to the worktree-level `attention` slot would light up
    /// every sibling pane in the sidebar. No-op if the terminal isn't
    /// in any worktree (e.g., it was just destroyed). Auto-clears after
    /// `clearAfter` seconds.
    @MainActor
    fileprivate static func setAttentionForTerminal(
        appState: Binding<AppState>,
        terminalID: TerminalID,
        text: String,
        clearAfter: TimeInterval
    ) {
        // Pin a single Date so the stored attention AND the closure
        // share the same generation token (same shape as the
        // worktree-scoped fix in handleNotification). The closure
        // checks current timestamp == captured before clearing, so a
        // newer ping or an explicit clear that lands between the
        // schedule and the fire can't be wiped.
        let stamp = Date()
        for repoIdx in appState.wrappedValue.repos.indices {
            for wtIdx in appState.wrappedValue.repos[repoIdx].worktrees.indices {
                if appState.wrappedValue.repos[repoIdx].worktrees[wtIdx]
                    .splitTree.containsLeaf(terminalID) {
                    appState.wrappedValue.repos[repoIdx].worktrees[wtIdx]
                        .paneAttention[terminalID] = Attention(
                            text: text,
                            timestamp: stamp,
                            clearAfter: clearAfter
                        )
                    let path = appState.wrappedValue.repos[repoIdx].worktrees[wtIdx].path
                    DispatchQueue.main.asyncAfter(deadline: .now() + clearAfter) {
                        for ri in appState.wrappedValue.repos.indices {
                            for wi in appState.wrappedValue.repos[ri].worktrees.indices {
                                if appState.wrappedValue.repos[ri].worktrees[wi].path == path {
                                    appState.wrappedValue.repos[ri].worktrees[wi]
                                        .clearPaneAttentionIfTimestamp(stamp, for: terminalID)
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
            for (wi, wt) in repo.worktrees.enumerated() where wt.splitTree.containsLeaf(terminalID) {
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
        // Drop any pane-scoped attention badge attached to the moving
        // pane. The ping was tied to the source-worktree context; the
        // target worktree has its own separate attention state.
        appState.wrappedValue.repos[currentRepoIdx].worktrees[currentWorktreeIdx]
            .paneAttention[terminalID] = nil
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
        if let remembered, targetWt.splitTree.containsLeaf(remembered.anchorID) {
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

    /// Static navigate used by the `onGotoSplit` callback (triggered from
    /// libghostty keybinds). Spatial direction is mapped to previous/next
    /// in leaf order — we don't yet have geometry to do true spatial nav.
    @MainActor
    fileprivate static func navigatePane(
        appState: Binding<AppState>,
        terminalManager: TerminalManager,
        from terminalID: TerminalID,
        direction: NavigationDirection
    ) {
        for repoIdx in appState.wrappedValue.repos.indices {
            for wtIdx in appState.wrappedValue.repos[repoIdx].worktrees.indices {
                let wt = appState.wrappedValue.repos[repoIdx].worktrees[wtIdx]
                let leaves = wt.splitTree.allLeaves
                guard let currentIdx = leaves.firstIndex(of: terminalID) else { continue }
                guard leaves.count > 1 else { return }
                let nextIdx: Int
                switch direction {
                case .left, .up:
                    nextIdx = (currentIdx - 1 + leaves.count) % leaves.count
                case .right, .down:
                    nextIdx = (currentIdx + 1) % leaves.count
                }
                let nextID = leaves[nextIdx]
                // Zoom preservation: Ghostty 1.3 `split-preserve-zoom = navigation` opt-in.
                if wt.splitTree.zoomed != nil {
                    let newTree = terminalManager.splitPreserveZoomOnNavigation
                        ? wt.splitTree.withZoom(nextID)
                        : wt.splitTree.withZoom(nil)
                    appState.wrappedValue.repos[repoIdx].worktrees[wtIdx].splitTree = newTree
                }
                appState.wrappedValue.repos[repoIdx].worktrees[wtIdx].focusedTerminalID = nextID
                terminalManager.setFocus(nextID)
                return
            }
        }
    }

    @MainActor
    fileprivate static func navigatePaneInTreeOrder(
        appState: Binding<AppState>,
        terminalManager: TerminalManager,
        from terminalID: TerminalID,
        forward: Bool
    ) {
        navigatePane(
            appState: appState,
            terminalManager: terminalManager,
            from: terminalID,
            direction: forward ? .right : .left
        )
    }

    @MainActor
    fileprivate static func toggleZoom(appState: Binding<AppState>, on terminalID: TerminalID) {
        mutateWorktreeContaining(appState: appState, leaf: terminalID) { wt in
            var copy = wt
            copy.splitTree = wt.splitTree.togglingZoom(at: terminalID)
            return copy
        }
    }

    @MainActor
    fileprivate static func equalizeSplits(appState: Binding<AppState>, around terminalID: TerminalID) {
        mutateWorktreeContaining(appState: appState, leaf: terminalID) { wt in
            var copy = wt
            copy.splitTree = wt.splitTree.equalizing()
            return copy
        }
    }

    @MainActor
    fileprivate static func resizeSplit(
        appState: Binding<AppState>,
        target: TerminalID,
        direction: ResizeDirection,
        pixels: UInt16
    ) {
        // MVP: use the key window's content-area bounds as a proxy for the
        // ancestor split bounds. Accurate for single-split layouts; for nested
        // splits the delta will be slightly off. A follow-up can capture
        // per-split bounds via SwiftUI preference keys.
        // TODO: plumb per-split GeometryReader bounds for multi-level accuracy.
        let bounds = NSApp.keyWindow?.contentView?.bounds
            ?? CGRect(x: 0, y: 0, width: 1200, height: 800)
        mutateWorktreeContaining(appState: appState, leaf: target) { wt in
            var copy = wt
            do {
                copy.splitTree = try wt.splitTree.resizing(
                    target: target,
                    direction: direction,
                    pixels: pixels,
                    ancestorBounds: bounds
                )
            } catch {
                // No matching orientation ancestor — silent no-op, matches Ghostty.
            }
            return copy
        }
    }

    /// Find the worktree that owns `leaf` and apply `transform` to it.
    /// Idempotent and safe for callers that don't know which worktree owns a pane.
    @MainActor
    private static func mutateWorktreeContaining(
        appState: Binding<AppState>,
        leaf: TerminalID,
        transform: (WorktreeEntry) -> WorktreeEntry
    ) {
        for repoIdx in appState.wrappedValue.repos.indices {
            for wtIdx in appState.wrappedValue.repos[repoIdx].worktrees.indices {
                if appState.wrappedValue.repos[repoIdx].worktrees[wtIdx].splitTree.containsLeaf(leaf) {
                    let wt = appState.wrappedValue.repos[repoIdx].worktrees[wtIdx]
                    appState.wrappedValue.repos[repoIdx].worktrees[wtIdx] = transform(wt)
                    return
                }
            }
        }
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
                guard wt.splitTree.containsLeaf(targetID) else { continue }

                terminalManager.destroySurface(terminalID: targetID)
                let newTree = wt.splitTree.removing(targetID)
                appState.wrappedValue.repos[repoIdx].worktrees[wtIdx].splitTree = newTree
                // Drop any lingering per-pane attention so a destroyed
                // terminal doesn't leak a badge entry into the model.
                appState.wrappedValue.repos[repoIdx].worktrees[wtIdx]
                    .paneAttention[targetID] = nil

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

    /// Called on the first `onShellReady` signal for a pane. Reads the
    /// user's default-command preferences from UserDefaults, consults the
    /// pure decision function in EspalierKit, and — if the decision is
    /// `.type(command)` — types the command into the pane via
    /// `SurfaceHandle.typeText` followed by `\r` to trigger execution.
    @MainActor
    fileprivate static func maybeRunDefaultCommand(
        terminalManager: TerminalManager,
        terminalID: TerminalID
    ) {
        let defaults = UserDefaults.standard
        let command = defaults.string(forKey: "defaultCommand") ?? ""
        // `@AppStorage` defaults apply only in the SwiftUI view; when
        // read directly from UserDefaults the key returns nil on
        // first run. Treat nil as `true` to match the SettingsView default.
        let firstPaneOnly = defaults.object(forKey: "defaultCommandFirstPaneOnly") as? Bool ?? true

        let decision = defaultCommandDecision(
            defaultCommand: command,
            firstPaneOnly: firstPaneOnly,
            isFirstPane: terminalManager.isFirstPane(terminalID),
            wasRehydrated: terminalManager.wasRehydrated(terminalID)
        )

        switch decision {
        case .skip:
            return
        case .type(let trimmedCommand):
            terminalManager.handle(for: terminalID)?.typeText(trimmedCommand + "\r")
        }
    }

    // MARK: - Focused-pane helpers for menu actions

    /// The terminal currently holding focus in the selected worktree.
    private var focusedTerminalID: TerminalID? {
        guard let path = appState.selectedWorktreePath else { return nil }
        for repo in appState.repos {
            for wt in repo.worktrees where wt.path == path && wt.state == .running {
                return wt.focusedTerminalID ?? wt.splitTree.allLeaves.first
            }
        }
        return nil
    }

    private func handleSplit(_ split: PaneSplit) {
        guard let id = focusedTerminalID else { return }
        _ = Self.splitPane(appState: $appState, terminalManager: terminalManager, targetID: id, split: split)
    }

    private func handleNavigate(_ dir: NavigationDirection) {
        guard let id = focusedTerminalID else { return }
        Self.navigatePane(appState: $appState, terminalManager: terminalManager, from: id, direction: dir)
    }

    private func handleNavigateTreeOrder(forward: Bool) {
        guard let id = focusedTerminalID else { return }
        Self.navigatePaneInTreeOrder(appState: $appState, terminalManager: terminalManager, from: id, forward: forward)
    }

    private func handleToggleZoom() {
        guard let id = focusedTerminalID else { return }
        Self.toggleZoom(appState: $appState, on: id)
    }

    private func handleEqualizeSplits() {
        guard let id = focusedTerminalID else { return }
        Self.equalizeSplits(appState: $appState, around: id)
    }

    private func handleClosePane() {
        guard let id = focusedTerminalID else { return }
        Self.closePane(appState: $appState, terminalManager: terminalManager, targetID: id)
    }

    private func handleReloadConfig() {
        terminalManager.rebuildKeybindBridge()
    }

    // MARK: - View builder for bridge-shortcutted menu buttons

    /// Wraps a menu button so its keyboard shortcut is derived from the
    /// keybind bridge at runtime, not hardcoded. If the action has no
    /// configured binding (or the key can't be translated to a
    /// `KeyboardShortcut`), the button renders without a shortcut hint.
    @MainActor
    @ViewBuilder
    private func bridgedButton(
        _ label: LocalizedStringKey,
        action: GhosttyAction,
        onTap: @escaping () -> Void
    ) -> some View {
        if let chord = terminalManager.keybindBridge[action],
           let shortcut = KeyboardShortcutFromChord.shortcut(from: chord) {
            Button(label, action: onTap).keyboardShortcut(shortcut)
        } else {
            Button(label, action: onTap)
        }
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
    let prStatusStore: PRStatusStore

    init(
        appState: Binding<AppState>,
        statsStore: WorktreeStatsStore,
        prStatusStore: PRStatusStore
    ) {
        self.appState = appState
        self.statsStore = statsStore
        self.prStatusStore = prStatusStore
    }

    /// Called when `.git/worktrees/` changes (new worktree added, existing
    /// one removed externally). After reconciling appState, refresh stats
    /// for every non-stale worktree in the repo — new worktrees need their
    /// initial stats, removed ones will be marked stale (and stats cleared
    /// by `worktreeMonitorDidDetectDeletion`).
    nonisolated func worktreeMonitorDidDetectChange(_ monitor: WorktreeMonitor, repoPath: String) {
        let binding = appState
        let store = statsStore
        // `git worktree list --porcelain` is a subprocess wait. Awaiting the
        // now-async `GitWorktreeDiscovery.discover` yields the main actor
        // during the wait so ghostty keystrokes aren't delayed (prior
        // manifestation: intermittent ~1s input/render hangs under fs/
        // indexing pressure).
        Task { @MainActor in
            guard let discovered = try? await GitWorktreeDiscovery.discover(repoPath: repoPath) else { return }
            guard let repoIdx = binding.wrappedValue.repos.firstIndex(where: { $0.path == repoPath }) else { return }

            let existing = binding.wrappedValue.repos[repoIdx].worktrees
            let existingPaths = Set(existing.map(\.path))
            let discoveredPaths = Set(discovered.map(\.path))
            let newlyAdded = discovered.filter { !existingPaths.contains($0.path) }
            let newlyStale = existing.filter { !discoveredPaths.contains($0.path) && $0.state != .stale }

            for d in newlyAdded {
                let entry = WorktreeEntry(path: d.path, branch: d.branch)
                binding.wrappedValue.repos[repoIdx].worktrees.append(entry)
            }
            for wtIdx in binding.wrappedValue.repos[repoIdx].worktrees.indices {
                let wt = binding.wrappedValue.repos[repoIdx].worktrees[wtIdx]
                if !discoveredPaths.contains(wt.path) && wt.state != .stale {
                    binding.wrappedValue.repos[repoIdx].worktrees[wtIdx].state = .stale
                } else if discoveredPaths.contains(wt.path) && wt.state == .stale {
                    // Worktree was marked stale but is now back in git's
                    // view (e.g., a momentary FSEvents delete glitch, a
                    // `git worktree repair`, or a force-remove+re-add).
                    // Resurrect to `.closed`; user can click to start
                    // terminals again per TERM-1.1 / TERM-1.2.
                    binding.wrappedValue.repos[repoIdx].worktrees[wtIdx].state = .closed
                }
            }

            // watchWorktreePath / watchHeadRef are idempotent, so registering
            // for the whole repo is cheap; this is how newly-discovered
            // worktrees (external `git worktree add`) start getting HEAD
            // tracking without an app restart. Includes resurrected entries.
            for wt in binding.wrappedValue.repos[repoIdx].worktrees where wt.state != .stale {
                monitor.watchWorktreePath(wt.path)
                monitor.watchHeadRef(worktreePath: wt.path, repoPath: repoPath)
            }

            // Existing worktrees' stats are driven by their own HEAD
            // callbacks and the polling loop, so a `.git/worktrees/`
            // directory tick only needs to seed stats for new entries and
            // drop stats for newly-stale ones.
            for d in newlyAdded {
                store.refresh(worktreePath: d.path, repoPath: repoPath)
            }
            for wt in newlyStale {
                store.clear(worktreePath: wt.path)
            }
        }
    }

    nonisolated func worktreeMonitorDidDetectDeletion(_ monitor: WorktreeMonitor, worktreePath: String) {
        let binding = appState
        let store = statsStore
        let prStore = prStatusStore
        Task { @MainActor in
            for repoIdx in binding.wrappedValue.repos.indices {
                for wtIdx in binding.wrappedValue.repos[repoIdx].worktrees.indices {
                    if binding.wrappedValue.repos[repoIdx].worktrees[wtIdx].path == worktreePath {
                        binding.wrappedValue.repos[repoIdx].worktrees[wtIdx].state = .stale
                    }
                }
            }
            store.clear(worktreePath: worktreePath)
            prStore.clear(worktreePath: worktreePath)
        }
    }

    nonisolated func worktreeMonitorDidDetectBranchChange(_ monitor: WorktreeMonitor, worktreePath: String) {
        let binding = appState
        let store = statsStore
        let prStore = prStatusStore
        // Branch changes fire in bursts (rebase, interactive checkout), so
        // `GitWorktreeDiscovery.discover`'s subprocess wait must yield the
        // main actor — the async version does that naturally. Scope the
        // discover call to the owning repo only, not every tracked repo.
        Task { @MainActor in
            guard let repoPath = binding.wrappedValue.repos.first(where: { repo in
                repo.worktrees.contains(where: { $0.path == worktreePath })
            })?.path else { return }
            guard let discovered = try? await GitWorktreeDiscovery.discover(repoPath: repoPath),
                  let match = discovered.first(where: { $0.path == worktreePath }) else { return }
            guard let repoIdx = binding.wrappedValue.repos.firstIndex(where: { $0.path == repoPath }),
                  let wtIdx = binding.wrappedValue.repos[repoIdx].worktrees.firstIndex(where: { $0.path == worktreePath }) else { return }
            binding.wrappedValue.repos[repoIdx].worktrees[wtIdx].branch = match.branch
            store.refresh(worktreePath: worktreePath, repoPath: repoPath)
            prStore.branchDidChange(worktreePath: worktreePath, repoPath: repoPath, branch: match.branch)
        }
    }
}
