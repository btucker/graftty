import SwiftUI
import AppKit
import UniformTypeIdentifiers
import GrafttyKit

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
    let onRemoveRepo: (RepoEntry) -> Void
    let onStopWorktree: (String) -> Void
    let onDeleteWorktree: (String) -> Void
    let onMovePane: (TerminalID, String) -> Void
    /// Called when the user submits the add-worktree sheet. Returns nil
    /// on success, or a user-visible error string (typically git's
    /// stderr) on failure so the sheet can display it inline.
    let onAddWorktree: (RepoEntry, String, String) async -> String?

    /// Injected by GrafttyApp so the pane-row context menu can gate the
    /// "Copy web URL" item on `controller.status == .listening` and read
    /// the listening addresses to compose the URL.
    @EnvironmentObject private var webController: WebServerController

    @Binding var pendingAddWorktree: AddWorktreeRequest?

    @AppStorage("agentTeamsEnabled") private var agentTeamsEnabled: Bool = false

    /// Worktree path whose "Show Team Members…" popover is currently presented.
    @State private var teamPopoverWorktreePath: String? = nil

    /// Hovered drop-target row during a pane drag (PWD-1.5). Nil otherwise.
    @State private var dropTargetWorktreeID: WorktreeEntry.ID?

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
        .sheet(item: $pendingAddWorktree) { request in
            AddWorktreeSheet(
                repoDisplayName: request.repo.displayName,
                initialWorktreeName: request.prefill,
                onSubmit: { worktreeName, branchName in
                    let err = await onAddWorktree(request.repo, worktreeName, branchName)
                    if err == nil { pendingAddWorktree = nil }
                    return err
                },
                onCancel: { pendingAddWorktree = nil }
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
                if agentTeamsEnabled && repo.worktrees.count >= 2 {
                    TeamRepoBadge(repoPath: repo.path)
                        .font(.system(size: 11))
                }
                Spacer()
                Button {
                    pendingAddWorktree = AddWorktreeRequest(repo: repo, prefill: "")
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
            .contextMenu {
                Button("Remove Repository") {
                    onRemoveRepo(repo)
                }
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
        let attention = SidebarAttentionLayout.layout(for: worktree)
        let isDropTarget = dropTargetWorktreeID == worktree.id
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
                        PRBadge(number: $0.number, state: $0.state, checks: $0.checks, url: $0.url)
                    },
                    attentionText: attention.worktreeCapsule
                )
            }
            .buttonStyle(.plain)
            // PWD-1.4: same-repo drop target. Sources are sidebar pane
            // rows wrapped in `TransferableTerminalID`. Cross-repo drops
            // are rejected so a user can't accidentally hop a pane
            // across repos (out of scope, matches PWD-1.3).
            .dropDestination(for: TransferableTerminalID.self) { items, _ in
                guard let item = items.first else { return false }
                let sourceID = TerminalID(id: item.id)
                // `.creating` placeholders have no on-disk directory
                // and no terminal surfaces yet — moving a pane onto one
                // would either fail in zmx attach or silently land on
                // a worktree that's about to disappear if git fails.
                guard worktree.state != .creating else { return false }
                guard let indices =
                        appState.indicesOfWorktreeContaining(terminalID: sourceID),
                      appState.repos[indices.repo].id == repo.id
                else { return false }
                onMovePane(sourceID, worktree.path)
                return true
            } isTargeted: { targeted in
                // PWD-1.5: `isTargeted` can't see the payload, so cross-
                // repo rejection happens at drop time and every hovered
                // row highlights optimistically.
                if targeted {
                    dropTargetWorktreeID = worktree.id
                } else if dropTargetWorktreeID == worktree.id {
                    dropTargetWorktreeID = nil
                }
            }
            .rightClickMenu {
                buildWorktreeMenu(worktree, repo: repo)
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
                            attentionText: attention.paneCapsules[terminalID]
                        )
                    }
                    .buttonStyle(.plain)
                    // PWD-1.4: pane rows are drag sources. The payload
                    // is a typed wrapper around the pane's UUID so
                    // SwiftUI's Transferable matching keeps unrelated
                    // drops from being mis-decoded as panes.
                    .draggable(TransferableTerminalID(id: terminalID.id))
                    .rightClickMenu {
                        buildPaneMenu(terminalID: terminalID)
                    }
                }
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isActive ? theme.foreground.opacity(0.16) : .clear)
        )
        // TEAM-6.2: "Show Team Members…" popover
        .popover(isPresented: Binding(
            get: { teamPopoverWorktreePath == worktree.path },
            set: { shown in if !shown { teamPopoverWorktreePath = nil } }
        )) {
            TeamMembersPopover(
                worktree: worktree,
                repos: appState.repos,
                teamsEnabled: agentTeamsEnabled
            )
        }
        // PWD-1.5: drop-target highlight. Stroked so it composes with
        // the active-worktree background fill above when the dragged-
        // onto row is also the active one.
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(theme.foreground.opacity(isDropTarget ? 0.5 : 0), lineWidth: 1.5)
        )
    }

    private func label(for worktree: WorktreeEntry, in repo: RepoEntry) -> String {
        SidebarWorktreeLabel.text(
            for: worktree,
            inRepoAtPath: repo.path,
            siblingPaths: repo.worktrees.map(\.path)
        )
    }

    /// Worktree row's right-click menu. Built as `NSMenu` (not a
    /// SwiftUI `.contextMenu`) for the List-row hoisting reason
    /// `.rightClickMenu` documents.
    private func buildWorktreeMenu(_ worktree: WorktreeEntry, repo: RepoEntry) -> NSMenu {
        let menu = NSMenu()
        // While an entry is in `.creating`, the on-disk worktree may
        // not exist yet (`git worktree add` is still running, possibly
        // blocked on hooks). Open-in-Finder, Stop, and Delete-Worktree
        // would all either error or race the in-flight create — so the
        // menu is empty until the placeholder transitions out.
        if worktree.state == .creating {
            return menu
        }
        if worktree.state != .stale {
            menu.addItem(ClosureMenuItem(title: "Open Worktree in Finder...") {
                NSWorkspace.shared.open(URL(fileURLWithPath: worktree.path))
            })
            menu.addItem(.separator())
        }
        if worktree.state == .running {
            menu.addItem(ClosureMenuItem(title: "Stop") { [self] in
                onStopWorktree(worktree.path)
            })
        }
        if worktree.state == .stale {
            menu.addItem(ClosureMenuItem(title: "Dismiss") {
                dismissWorktree(worktree, in: repo)
            })
        }
        // git refuses to remove the main checkout, so hiding the item
        // there avoids a guaranteed error path.
        if worktree.path != repo.path && worktree.state != .stale {
            menu.addItem(ClosureMenuItem(title: "Delete Worktree") { [self] in
                onDeleteWorktree(worktree.path)
            })
        }
        // TEAM-6.2: "Show Team Members…" opens a popover listing team members.
        if agentTeamsEnabled,
           TeamView.team(for: worktree, in: appState.repos, teamsEnabled: true) != nil {
            menu.addItem(.separator())
            menu.addItem(ClosureMenuItem(title: "Show Team Members…") {
                teamPopoverWorktreePath = worktree.path
            })
        }
        return menu
    }

    /// AppKit-side pane right-click menu (PWD-1.1 / PWD-1.3 / LAYOUT-2.7
    /// / TERM-8.10). The Move section is shared with the terminal-surface
    /// menu via `PaneMoveMenuBuilder`; the Copy-web-URL item is sidebar-
    /// only because the surface has no worktree-context-free way to know
    /// its session name without going through this same view tree.
    private func buildPaneMenu(terminalID: TerminalID) -> NSMenu {
        let menu = NSMenu()
        if let context = PaneMoveMenuContext.resolve(
            terminalID: terminalID,
            appState: appState,
            shellCwd: terminalManager.shellCwd(for: terminalID)
        ) {
            for item in PaneMoveMenuBuilder.items(
                terminalID: terminalID,
                context: context,
                onMove: onMovePane
            ) {
                menu.addItem(item)
            }
        }
        if case let .listening(_, port) = webController.status,
           let host = webController.serverHostname {
            menu.addItem(.separator())
            menu.addItem(ClosureMenuItem(title: "Copy web URL") {
                Pasteboard.copy(WebURLComposer.url(
                    session: ZmxLauncher.sessionName(for: terminalID.id),
                    host: host,
                    port: port
                ))
            })
        }
        return menu
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

// MARK: - Team Members Popover (TEAM-6.2)

/// Inline popover listing all members of the team that contains `worktree`.
/// Presented from the "Show Team Members…" context-menu item.
private struct TeamMembersPopover: View {
    let worktree: WorktreeEntry
    let repos: [RepoEntry]
    let teamsEnabled: Bool

    var body: some View {
        let team = TeamView.team(for: worktree, in: repos, teamsEnabled: teamsEnabled)
        VStack(alignment: .leading, spacing: 0) {
            if let team {
                Text("Team — \(team.repoDisplayName)")
                    .font(.headline)
                    .padding(.bottom, 8)
                Divider()
                ForEach(team.members, id: \.worktreePath) { member in
                    HStack(spacing: 8) {
                        Image(systemName: member.role == .lead ? "star.fill" : "person.fill")
                            .foregroundStyle(member.role == .lead ? Color.yellow : Color.secondary)
                            .frame(width: 16)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(member.name)
                                .fontWeight(member.role == .lead ? .semibold : .regular)
                            Text(member.branch)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Circle()
                            .fill(member.isRunning ? Color.green : Color.secondary.opacity(0.4))
                            .frame(width: 8, height: 8)
                    }
                    .padding(.vertical, 4)
                    Divider().opacity(0.4)
                }
            } else {
                Text("No team")
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .frame(minWidth: 220, maxWidth: 320)
    }
}
