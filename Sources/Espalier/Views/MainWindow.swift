import SwiftUI
import AppKit
import EspalierKit

struct MainWindow: View {
    @Binding var appState: AppState
    @ObservedObject var terminalManager: TerminalManager
    let statsStore: WorktreeStatsStore
    let worktreeMonitor: WorktreeMonitor

    /// Debounces writes of `sidebarWidth` to AppState so a drag doesn't
    /// generate hundreds of save-to-disk events.
    @State private var pendingSidebarWidthTask: Task<Void, Never>?

    /// Column visibility state — must be a real `@State` rather than a
    /// `.constant(...)` so the toolbar toggle button actually toggles.
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        NavigationSplitView(
            columnVisibility: $columnVisibility
        ) {
            SidebarView(
                appState: $appState,
                terminalManager: terminalManager,
                theme: terminalManager.theme,
                statsStore: statsStore,
                onSelect: selectWorktree,
                onSelectPane: selectPane,
                onAddRepo: addRepository,
                onAddPath: addPath,
                onStopWorktree: stopWorktreeWithConfirmation,
                onAddWorktree: addWorktree
            )
            .navigationSplitViewColumnWidth(
                min: 180,
                ideal: appState.sidebarWidth,
                max: 400
            )
            // Deliberately do NOT call ignoresSafeArea here. The sidebar
            // respects the title-bar safe area so its content begins below
            // the traffic lights rather than colliding with them. The
            // detail column opts out so the breadcrumb sits alongside the
            // traffic lights.
        } detail: {
            VStack(spacing: 0) {
                BreadcrumbBar(
                    repoName: selectedRepo?.displayName,
                    branchName: selectedWorktree?.branch,
                    path: selectedWorktree?.path,
                    theme: terminalManager.theme
                )

                if let worktree = selectedWorktreeBinding {
                    TerminalContentView(
                        terminalManager: terminalManager,
                        splitTree: Binding(
                            get: { worktree.wrappedValue.splitTree },
                            set: { worktree.wrappedValue.splitTree = $0 }
                        ),
                        onFocusTerminal: { terminalID in
                            terminalManager.setFocus(terminalID)
                        }
                    )
                    // A hair of breathing room so terminal text doesn't
                    // slam into the sidebar divider.
                    .padding(.leading, 6)
                } else {
                    ContentUnavailableView(
                        "No Worktree Selected",
                        systemImage: "terminal",
                        description: Text("Select a worktree from the sidebar or add a repository.")
                    )
                }
            }
            .ignoresSafeArea(.container, edges: .top)
        }
        // Tint the NSWindow to match the terminal theme: background color,
        // transparent titlebar + full-size content view, and NSAppearance
        // matching the theme's dark/light-ness so system chrome (traffic
        // lights, context menus, alerts) renders with correct contrast.
        .windowBackgroundTint(theme: terminalManager.theme)
        // Force the SwiftUI color scheme from the theme so SwiftUI-rendered
        // chrome — the NavigationSplitView sidebar toggle in particular —
        // picks the right icon shade. NSWindow.appearance covers AppKit
        // controls (traffic lights, alerts, context menus), but SwiftUI
        // toolbar items resolve through ColorScheme, not NSAppearance.
        .preferredColorScheme(terminalManager.theme.isDark ? .dark : .light)
        .trackWindowFrame(
            initialFrame: initialWindowRect
        ) { [$appState] frame in
            let newFrame = WindowFrame(
                x: frame.origin.x,
                y: frame.origin.y,
                width: frame.size.width,
                height: frame.size.height
            )
            if $appState.wrappedValue.windowFrame != newFrame {
                $appState.wrappedValue.windowFrame = newFrame
            }
        }
        .onPreferenceChange(SidebarWidthKey.self) { [$appState, $pendingSidebarWidthTask] width in
            // Debounce by 250ms so a drag doesn't write on every layout
            // pass. Only writes if the value actually changed (value-equality
            // check prevents feedback loops with the onChange save handler).
            $pendingSidebarWidthTask.wrappedValue?.cancel()
            $pendingSidebarWidthTask.wrappedValue = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(250))
                if Task.isCancelled { return }
                if $appState.wrappedValue.sidebarWidth != width {
                    $appState.wrappedValue.sidebarWidth = width
                }
            }
        }
    }

    /// The initial window rect to apply on first attach.
    ///
    /// Always returns a non-nil value: SwiftUI's `.defaultSize(width:height:)`
    /// on the scene is ignored when NavigationSplitView's detail content has
    /// an intrinsic size (e.g. `ContentUnavailableView`), so the window comes
    /// up at the content's minimum — roughly 472×312 on macOS 14 — which is
    /// way too small to be usable. Forcing the frame via `NSWindow.setFrame`
    /// in `WindowFrameTracker` is the only reliable way.
    ///
    /// Priority:
    /// 1. Saved non-default frame, if it overlaps a connected screen → apply as-is.
    /// 2. Otherwise → center the default size (from `WindowFrame()`) on the
    ///    primary screen's visible frame. This covers both first launch and
    ///    the "user unplugged the external monitor the window was parked on"
    ///    case.
    private var initialWindowRect: CGRect? {
        let savedFrame = appState.windowFrame
        let defaultFrame = WindowFrame()
        if savedFrame != defaultFrame {
            let rect = CGRect(x: savedFrame.x, y: savedFrame.y,
                              width: savedFrame.width, height: savedFrame.height)
            if WindowFrameTracker.Coordinator.frameIsVisibleOnAnyScreen(rect) {
                return rect
            }
        }
        let screen = NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let originX = screen.minX + (screen.width - defaultFrame.width) / 2
        let originY = screen.minY + (screen.height - defaultFrame.height) / 2
        return CGRect(x: originX, y: originY,
                      width: defaultFrame.width, height: defaultFrame.height)
    }

    private var selectedRepo: RepoEntry? {
        guard let path = appState.selectedWorktreePath else { return nil }
        return appState.repo(forWorktreePath: path)
    }

    private var selectedWorktree: WorktreeEntry? {
        guard let path = appState.selectedWorktreePath else { return nil }
        return appState.worktree(forPath: path)
    }

    private var selectedWorktreeBinding: Binding<WorktreeEntry>? {
        guard let path = appState.selectedWorktreePath else { return nil }
        for repoIdx in appState.repos.indices {
            for wtIdx in appState.repos[repoIdx].worktrees.indices {
                if appState.repos[repoIdx].worktrees[wtIdx].path == path {
                    return $appState.repos[repoIdx].worktrees[wtIdx]
                }
            }
        }
        return nil
    }

    /// Selects a worktree *and* focuses a specific pane within it. Used by
    /// the sidebar's per-pane title rows so clicking "claude" under a
    /// worktree both activates that worktree and focuses Claude's pane.
    private func selectPane(_ worktreePath: String, _ terminalID: TerminalID) {
        selectWorktree(worktreePath)
        for repoIdx in appState.repos.indices {
            for wtIdx in appState.repos[repoIdx].worktrees.indices {
                if appState.repos[repoIdx].worktrees[wtIdx].path == worktreePath {
                    appState.repos[repoIdx].worktrees[wtIdx].focusedTerminalID = terminalID
                }
            }
        }
        terminalManager.setFocus(terminalID)
        makePaneFirstResponder(terminalID)
    }

    private func selectWorktree(_ path: String) {
        appState.selectedWorktreePath = path

        for repoIdx in appState.repos.indices {
            for wtIdx in appState.repos[repoIdx].worktrees.indices {
                if appState.repos[repoIdx].worktrees[wtIdx].path == path
                    && appState.repos[repoIdx].worktrees[wtIdx].state == .closed {

                    if appState.repos[repoIdx].worktrees[wtIdx].splitTree.root == nil {
                        let id = TerminalID()
                        appState.repos[repoIdx].worktrees[wtIdx].splitTree = SplitTree(root: .leaf(id))
                    }

                    let splitTree = appState.repos[repoIdx].worktrees[wtIdx].splitTree
                    _ = terminalManager.createSurfaces(for: splitTree, worktreePath: path)

                    appState.repos[repoIdx].worktrees[wtIdx].state = .running
                }
            }
        }

        for repoIdx in appState.repos.indices {
            for wtIdx in appState.repos[repoIdx].worktrees.indices {
                if appState.repos[repoIdx].worktrees[wtIdx].path == path {
                    appState.repos[repoIdx].worktrees[wtIdx].attention = nil
                }
            }
        }

        // Route keyboard to the worktree's currently-focused pane (or the
        // first leaf if nothing was focused yet) so the user can start
        // typing immediately after a sidebar click without having to also
        // click into the terminal.
        if let wt = appState.worktree(forPath: path),
           let target = wt.focusedTerminalID ?? wt.splitTree.allLeaves.first {
            makePaneFirstResponder(target)
        }
    }

    /// Promote the terminal's backing `NSView` to the window's first
    /// responder so keyDown events route to libghostty. Dispatched async
    /// because the view may have just been created by `createSurfaces` and
    /// SwiftUI hasn't attached it to the window hierarchy yet — you can't
    /// `makeFirstResponder` a view that isn't in a window.
    private func makePaneFirstResponder(_ terminalID: TerminalID) {
        let tm = terminalManager
        DispatchQueue.main.async {
            guard let view = tm.view(for: terminalID),
                  let window = view.window else { return }
            window.makeFirstResponder(view)
        }
    }

    /// Creates a new worktree at `<repo>/.worktrees/<name>` with a fresh
    /// branch checked out. Starts from the repo's resolved default branch
    /// so new feature worktrees branch off main (vs. whatever the main
    /// checkout happens to have checked out right now). Returns nil on
    /// success or the stderr message on failure, for the sheet to display.
    ///
    /// On success, discovers the new worktree synchronously, registers
    /// its FSEvents watches, kicks its divergence stats, and selects
    /// it. The existing `.git/worktrees/` watcher will also fire
    /// `worktreeMonitorDidDetectChange` asynchronously — that path is
    /// idempotent, so duplicate discovery is a no-op.
    private func addWorktree(
        repo: RepoEntry,
        worktreeName: String,
        branchName: String
    ) async -> String? {
        let repoPath = repo.path
        let worktreePath = repoPath + "/.worktrees/" + worktreeName

        let gitError = await Task.detached {
            let startPoint = (try? GitOriginDefaultBranch.resolve(repoPath: repoPath)) ?? nil
            do {
                try GitWorktreeAdd.add(
                    repoPath: repoPath,
                    worktreePath: worktreePath,
                    branchName: branchName,
                    startPoint: startPoint
                )
                return nil as String?
            } catch GitWorktreeAdd.Error.gitFailed(_, let stderr) {
                return stderr.isEmpty ? "git worktree add failed" : stderr
            } catch {
                return "\(error)"
            }
        }.value
        if let gitError { return gitError }

        // Run discovery now rather than waiting for FSEvents so the new
        // entry is in appState by the time we call selectWorktree below
        // — otherwise selectWorktree's terminal-launch logic sees no
        // matching entry and no-ops.
        if let discovered = try? GitWorktreeDiscovery.discover(repoPath: repoPath),
           let repoIdx = appState.repos.firstIndex(where: { $0.path == repoPath }) {
            let existingPaths = Set(appState.repos[repoIdx].worktrees.map(\.path))
            for d in discovered where !existingPaths.contains(d.path) {
                let entry = WorktreeEntry(path: d.path, branch: d.branch)
                appState.repos[repoIdx].worktrees.append(entry)
                worktreeMonitor.watchWorktreePath(entry.path)
                worktreeMonitor.watchHeadRef(worktreePath: entry.path, repoPath: repoPath)
                statsStore.refresh(worktreePath: entry.path, repoPath: repoPath)
            }
        }

        // Switching to the new worktree also starts its terminal
        // surface since selectWorktree transitions a closed entry into
        // running.
        selectWorktree(worktreePath)
        return nil
    }

    private func addRepository() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "Select a git repository or worktree directory"

        guard panel.runModal() == .OK, let url = panel.url else { return }
        addPath(url.path)
    }

    func addPath(_ path: String) {
        guard let detection = try? GitRepoDetector.detect(path: path) else { return }

        switch detection {
        case .repoRoot(let repoPath):
            addRepoFromPath(repoPath, selectWorktree: nil)
        case .worktree(let worktreePath, let repoPath):
            addRepoFromPath(repoPath, selectWorktree: worktreePath)
        case .notARepo:
            let alert = NSAlert()
            alert.messageText = "Not a Git Repository"
            alert.informativeText = "\(path) is not a git repository or worktree."
            alert.alertStyle = .warning
            alert.runModal()
        }
    }

    private func stopWorktreeWithConfirmation(_ worktreePath: String) {
        for repoIdx in appState.repos.indices {
            for wtIdx in appState.repos[repoIdx].worktrees.indices {
                let wt = appState.repos[repoIdx].worktrees[wtIdx]
                if wt.path == worktreePath && wt.state == .running {
                    let terminalIDs = wt.splitTree.allLeaves
                    if terminalManager.needsConfirmQuit(terminalIDs: terminalIDs) {
                        let alert = NSAlert()
                        alert.messageText = "Stop Worktree?"
                        alert.informativeText = "There are running processes in \(wt.branch). Stop all terminals?"
                        alert.addButton(withTitle: "Stop")
                        alert.addButton(withTitle: "Cancel")
                        guard alert.runModal() == .alertFirstButtonReturn else { return }
                    }
                    terminalManager.destroySurfaces(terminalIDs: terminalIDs)
                    appState.repos[repoIdx].worktrees[wtIdx].state = .closed
                    return
                }
            }
        }
    }

    private func addRepoFromPath(_ repoPath: String, selectWorktree: String?) {
        guard !appState.repos.contains(where: { $0.path == repoPath }) else {
            if let wt = selectWorktree {
                appState.selectedWorktreePath = wt
            }
            return
        }

        guard let discovered = try? GitWorktreeDiscovery.discover(repoPath: repoPath) else { return }

        let worktrees = discovered.map { WorktreeEntry(path: $0.path, branch: $0.branch) }
        let displayName = URL(fileURLWithPath: repoPath).lastPathComponent
        let repo = RepoEntry(path: repoPath, displayName: displayName, worktrees: worktrees)
        appState.addRepo(repo)

        if let wt = selectWorktree {
            self.selectWorktree(wt)
        } else if let first = worktrees.first {
            self.selectWorktree(first.path)
        }
    }
}
