import SwiftUI
import AppKit
import EspalierKit

struct MainWindow: View {
    @Binding var appState: AppState
    @ObservedObject var terminalManager: TerminalManager

    var body: some View {
        NavigationSplitView(
            columnVisibility: .constant(.all)
        ) {
            SidebarView(
                appState: $appState,
                onSelect: selectWorktree,
                onAddRepo: addRepository,
                onAddPath: addPath,
                onStopWorktree: stopWorktreeWithConfirmation
            )
            .navigationSplitViewColumnWidth(
                min: 180,
                ideal: appState.sidebarWidth,
                max: 400
            )
        } detail: {
            VStack(spacing: 0) {
                BreadcrumbBar(
                    repoName: selectedRepo?.displayName,
                    branchName: selectedWorktree?.branch,
                    path: selectedWorktree?.path
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
                } else {
                    ContentUnavailableView(
                        "No Worktree Selected",
                        systemImage: "terminal",
                        description: Text("Select a worktree from the sidebar or add a repository.")
                    )
                }
            }
        }
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
