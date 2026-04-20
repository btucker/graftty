import SwiftUI
import AppKit
import UniformTypeIdentifiers
import EspalierKit

struct SidebarView: View {
    @Binding var appState: AppState
    /// Observed so pane-title changes (libghostty `SET_TITLE`) repaint the
    /// sidebar immediately. The manager's `titles` map is the source of
    /// truth for per-pane labels.
    @ObservedObject var terminalManager: TerminalManager
    let theme: GhosttyTheme
    let statsStore: WorktreeStatsStore
    let prStatusStore: PRStatusStore
    let onSelect: (String) -> Void
    let onSelectPane: (String, TerminalID) -> Void
    let onAddRepo: () -> Void
    let onAddPath: (String) -> Void
    let onStopWorktree: (String) -> Void
    let onDeleteWorktree: (String) -> Void
    let onMovePane: (TerminalID, String) -> Void
    /// Called when the user submits the add-worktree sheet. Returns nil
    /// on success, or a user-visible error string (typically git's
    /// stderr) on failure so the sheet can display it inline.
    let onAddWorktree: (RepoEntry, String, String) async -> String?

    /// Injected by EspalierApp so the pane-row context menu can gate the
    /// "Copy web URL" item on `controller.status == .listening` and read
    /// the listening addresses to compose the URL.
    @EnvironmentObject private var webController: WebServerController

    @State private var addingWorktreeTo: RepoEntry?

    var body: some View {
        VStack(spacing: 0) {
            List {
                ForEach(appState.repos) { repo in
                    repoSection(repo)
                }
            }
            .listStyle(.sidebar)
            // Remove the default sidebar material so the ghostty background
            // shows through. The scrollContentBackground hide is what lets
            // the List render transparently on top of our theme color.
            .scrollContentBackground(.hidden)

            Divider()
                .opacity(0.4)

            Button(action: onAddRepo) {
                Label("Add Repository", systemImage: "plus")
                    .frame(maxWidth: .infinity)
                    .foregroundColor(theme.foreground.opacity(0.8))
            }
            .buttonStyle(.plain)
            .padding(8)
        }
        .background(theme.sidebarBackground)
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            handleDrop(providers)
        }
        .publishSidebarWidth()
        .sheet(item: $addingWorktreeTo) { repo in
            AddWorktreeSheet(
                repoDisplayName: repo.displayName,
                onSubmit: { worktreeName, branchName in
                    let err = await onAddWorktree(repo, worktreeName, branchName)
                    if err == nil { addingWorktreeTo = nil }
                    return err
                },
                onCancel: { addingWorktreeTo = nil }
            )
        }
    }

    @ViewBuilder
    private func repoSection(_ repo: RepoEntry) -> some View {
        DisclosureGroup(
            isExpanded: Binding(
                get: { !repo.isCollapsed },
                set: { expanded in
                    if let idx = appState.repos.firstIndex(where: { $0.id == repo.id }) {
                        appState.repos[idx].isCollapsed = !expanded
                    }
                }
            )
        ) {
            ForEach(repo.worktrees) { worktree in
                worktreeBlock(worktree, repo: repo)
                    // Outdent the worktree rows so each row's state
                    // indicator lines up under the parent repo's folder
                    // icon rather than sitting further right than the
                    // repo's disclosure label. -20pt counters the
                    // DisclosureGroup child indent minus the leading
                    // width of the icon column on the repo header.
                    .listRowInsets(EdgeInsets(top: 0, leading: -20, bottom: 0, trailing: 0))
            }
        } label: {
            // No leading glyph — the top level is always projects, so
            // a folder icon would be tautological noise. The disclosure
            // arrow and semibold weight carry the "expandable heading"
            // cues on their own. Trailing "+" opens the add-worktree
            // sheet; .buttonStyle(.plain) keeps its tap from toggling
            // the enclosing disclosure.
            HStack(spacing: 6) {
                Text(repo.displayName)
                    .foregroundColor(theme.foreground)
                    .fontWeight(.semibold)
                Spacer()
                Button {
                    addingWorktreeTo = repo
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(theme.foreground.opacity(0.6))
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Add worktree to \(repo.displayName)")
            }
        }
    }

    /// Renders a worktree and its pane children as one visually-unified
    /// block. When the worktree is active, the whole block (worktree row +
    /// every pane row underneath) gets a single rounded highlight — the
    /// user can see at a glance which worktree they're "in" even when
    /// multiple panes are listed. Inside the highlighted block, the
    /// focused pane is distinguished by text emphasis rather than a
    /// second background.
    @ViewBuilder
    private func worktreeBlock(_ worktree: WorktreeEntry, repo: RepoEntry) -> some View {
        let isActive = appState.selectedWorktreePath == worktree.path
        VStack(spacing: 0) {
            Button {
                onSelect(worktree.path)
            } label: {
                WorktreeRow(
                    entry: worktree,
                    isActive: isActive,
                    displayName: label(for: worktree, in: repo),
                    isMainCheckout: worktree.path == repo.path,
                    theme: theme,
                    stats: statsStore.stats[worktree.path],
                    baseRef: statsStore.baseRef(
                        worktreePath: worktree.path,
                        repoPath: repo.path
                    ),
                    prBadge: prStatusStore.infos[worktree.path].map {
                        PRBadge(number: $0.number, state: $0.state, url: $0.url)
                    }
                )
            }
            .buttonStyle(.plain)
            .contextMenu {
                worktreeContextMenu(worktree, repo: repo)
            }

            if worktree.state == .running {
                ForEach(worktree.splitTree.allLeaves, id: \.self) { terminalID in
                    Button {
                        onSelectPane(worktree.path, terminalID)
                    } label: {
                        PaneTitleRow(
                            title: terminalManager.displayTitle(for: terminalID),
                            isActiveWorktree: isActive,
                            isFocusedPane: isActive
                                && worktree.focusedTerminalID == terminalID,
                            theme: theme,
                            attentionText: worktree.paneAttention[terminalID]?.text
                                ?? worktree.attention?.text
                        )
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        paneContextMenu(
                            terminalID: terminalID,
                            currentWorktree: worktree,
                            currentRepo: repo
                        )
                    }
                }
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isActive ? theme.foreground.opacity(0.16) : .clear)
        )
    }

    /// The sidebar label for a worktree, special-cased so the main checkout
    /// shows just its branch name (no disambiguation noise — the sidebar
    /// icon differentiates it from linked worktrees), while linked
    /// worktrees show their collision-aware directory name.
    private func label(for worktree: WorktreeEntry, in repo: RepoEntry) -> String {
        if worktree.path == repo.path {
            return worktree.branch
        }
        return worktree.displayName(amongSiblingPaths: repo.worktrees.map(\.path))
    }

    @ViewBuilder
    private func worktreeContextMenu(_ worktree: WorktreeEntry, repo: RepoEntry) -> some View {
        if worktree.state != .stale {
            Button("Open Worktree in Finder...") {
                NSWorkspace.shared.open(URL(fileURLWithPath: worktree.path))
            }
            Divider()
        }
        if worktree.state == .running {
            Button("Stop") {
                stopWorktree(worktree, in: repo)
            }
        }
        if worktree.state == .stale {
            Button("Dismiss") {
                dismissWorktree(worktree, in: repo)
            }
        }
        // git refuses to remove the main checkout, so hiding the item
        // there avoids a guaranteed error path.
        if worktree.path != repo.path && worktree.state != .stale {
            Button("Delete Worktree") {
                onDeleteWorktree(worktree.path)
            }
        }
    }

    /// Per-pane right-click menu (PWD-1.1 / 1.3, LAYOUT-2.7).
    @ViewBuilder
    private func paneContextMenu(
        terminalID: TerminalID,
        currentWorktree: WorktreeEntry,
        currentRepo: RepoEntry
    ) -> some View {
        moveToCurrentWorktreeButton(
            terminalID: terminalID,
            currentWorktree: currentWorktree
        )
        moveToWorktreeMenu(
            terminalID: terminalID,
            currentWorktree: currentWorktree,
            currentRepo: currentRepo
        )
        if case let .listening(addresses, port) = webController.status,
           let host = WebURLComposer.chooseHost(
               from: addresses.filter { $0 != "127.0.0.1" }
           ) {
            Divider()
            Button("Copy web URL") {
                let url = WebURLComposer.url(
                    session: ZmxLauncher.sessionName(for: terminalID.id),
                    host: host,
                    port: port
                )
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(url, forType: .string)
            }
        }
    }

    @ViewBuilder
    private func moveToCurrentWorktreeButton(
        terminalID: TerminalID,
        currentWorktree: WorktreeEntry
    ) -> some View {
        let cwd = terminalManager.shellCwd(for: terminalID)
        let indices = cwd.flatMap { appState.worktreeIndicesMatching(path: $0) }
        if let indices,
           appState.repos[indices.repo].worktrees[indices.worktree].id != currentWorktree.id {
            let matchedRepo = appState.repos[indices.repo]
            let matchedWt = matchedRepo.worktrees[indices.worktree]
            Button("Move to \(label(for: matchedWt, in: matchedRepo))") {
                onMovePane(terminalID, matchedWt.path)
            }
        } else {
            Button("Move to current worktree") {}
                .disabled(true)
                .help("Shell cwd is not under another known worktree")
        }
    }

    /// Same-repo only; cross-repo moves would surprise the user. Stale
    /// worktrees are kept in the list because moving a pane there
    /// reactivates the worktree (same effect as opening it manually).
    @ViewBuilder
    private func moveToWorktreeMenu(
        terminalID: TerminalID,
        currentWorktree: WorktreeEntry,
        currentRepo: RepoEntry
    ) -> some View {
        let siblings = currentRepo.worktrees.filter { $0.id != currentWorktree.id }
        if !siblings.isEmpty {
            Menu("Move to worktree") {
                ForEach(siblings) { sibling in
                    Button(label(for: sibling, in: currentRepo)) {
                        onMovePane(terminalID, sibling.path)
                    }
                }
            }
        }
    }

    private func stopWorktree(_ worktree: WorktreeEntry, in repo: RepoEntry) {
        onStopWorktree(worktree.path)
    }

    private func dismissWorktree(_ worktree: WorktreeEntry, in repo: RepoEntry) {
        guard let repoIdx = appState.repos.firstIndex(where: { $0.id == repo.id }) else { return }
        guard let wtIdx = appState.repos[repoIdx].worktrees
            .firstIndex(where: { $0.id == worktree.id }) else { return }
        let path = worktree.path

        // GIT-3.10: tear down surfaces kept alive by GIT-3.4
        // (stale-while-running). Without this, a Dismiss on such an
        // entry leaves render/io/kqueue threads running forever — the
        // same orphan-surfaces shape that SIGKILL'd the app via
        // libghostty's os_unfair_lock pre-GIT-3.9. `prepareForDismissal`
        // returns the leaves and atomically clears the entry's model
        // state so silently-leak shape is no longer spellable.
        let orphan = appState.repos[repoIdx].worktrees[wtIdx].prepareForDismissal()
        if !orphan.isEmpty {
            terminalManager.destroySurfaces(terminalIDs: orphan)
        }

        // Drop cached per-path state in the observable stores before
        // removing the entry from the model. If we reverse the order the
        // stores' caches become orphan entries keyed by a path nobody
        // iterates anymore — a slow memory leak over a long session
        // where a user Dismisses many stale worktrees. Calling `clear`
        // on both is idempotent for the never-cached case, so this is
        // safe to run unconditionally.
        prStatusStore.clear(worktreePath: path)
        statsStore.clear(worktreePath: path)
        // If the dismissed worktree was the selected one, clear selection
        // so the detail pane shows the "No Worktree Selected" placeholder
        // rather than binding to a now-nonexistent entry.
        if appState.selectedWorktreePath == path {
            appState.selectedWorktreePath = nil
        }
        appState.repos[repoIdx].worktrees.removeAll { $0.id == worktree.id }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        for provider in providers {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { data, _ in
                guard let data = data as? Data,
                      let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                let path = url.path
                DispatchQueue.main.async {
                    onAddPath(path)
                }
            }
        }
        return true
    }
}
