import SwiftUI
import AppKit
import UniformTypeIdentifiers
import GrafttyKit
import GrafttyProtocol

struct SidebarView: View {
    @Binding var appState: AppState
    /// Used to read pane titles. Title change invalidation is deliberately
    /// scoped to `paneTitleInvalidations` below so MainWindow does not
    /// recompute on every shell title/PWD event.
    let terminalManager: TerminalManager
    @ObservedObject var paneTitleInvalidations: PaneTitleInvalidationSource
    let theme: GhosttyTheme
    let statsStore: WorktreeStatsStore
    let prStatusStore: PRStatusStore
    /// Injected by GrafttyApp so each pane row can merge derived claude
    /// busy/idle liveness (notify pings still win) into its attention pill.
    let claudeSessionRegistry: ClaudeSessionRegistry
    let remoteBranchStore: RemoteBranchStore
    /// Teammates' worktrees, keyed by repo path. Rendered as read-only
    /// ambient rows beneath each repo's local worktrees (SYNC-5.1).
    @ObservedObject var presenceStore: TeamPresenceSyncStore
    let onSelect: (String) -> Void
    let onSelectPane: (String, PaneSlotID) -> Void
    let onAddRepo: () -> Void
    let onAddPath: (String) -> Void
    let onRemoveRepo: (RepoEntry) -> Void
    let onInitializeGit: (RepoEntry) -> Void
    let onStopWorktree: (String) -> Void
    let onDeleteWorktree: (String) -> Void
    let onMovePane: (PaneSlotID, String) -> Void
    /// Called when the user submits the add-worktree sheet. Returns nil
    /// on success, or a user-visible error string (typically git's
    /// stderr) on failure so the sheet can display it inline.
    let onAddWorktree: (RepoEntry, String, BranchSelection) async -> String?
    /// Toggles presence sharing for the repo at the given path (SYNC-5.1 /
    /// SYNC-2.3). Wired from MainWindow so the publish/leave side effects
    /// live alongside the other repo handlers.
    let onToggleTeamSharing: (String) -> Void

    /// Injected by GrafttyApp so the pane-row context menu can gate the
    /// "Copy web URL" item on `controller.status == .listening` and read
    /// the listening addresses to compose the URL.
    @EnvironmentObject private var webController: WebServerController

    /// Injected by GrafttyApp so each pane row can render port-binding
    /// chips for ports its process subtree is currently listening on.
    @EnvironmentObject private var portBindings: PortBindingsModel

    /// SwiftUI's environment-provided window-opener. Used by the
    /// worktree-row context menu's *Show Team Activity…* item
    /// (TEAM-7.2) to route to the `TeamActivityLogWindowID`-keyed
    /// `WindowGroup` declared in `GrafttyApp`.
    @Environment(\.openWindow) private var openWindow

    @Binding var pendingAddWorktree: AddWorktreeRequest?

    @AppStorage("agentTeamsEnabled") private var agentTeamsEnabled: Bool = false

    /// Hovered drop-target row during a pane drag (PWD-1.5). Nil otherwise.
    @State private var dropTargetWorktreeID: WorktreeEntry.ID?

    var body: some View {
        // Explicit dependency: the titles live on TerminalManager, while this
        // lightweight observable scopes invalidation to the sidebar.
        let _ = paneTitleInvalidations.generation
        VStack(spacing: 0) {
            List {
                ForEach(appState.repos) { repo in
                    repoSection(repo)
                }
            }
            .listStyle(.sidebar)

            Divider()
                .opacity(0.4)

            Button(action: onAddRepo) {
                Label("Add Repository", systemImage: "plus")
                    .frame(maxWidth: .infinity)
                    .foregroundColor(theme.sidebarPrimaryText(isActive: false))
            }
            .buttonStyle(.plain)
            .padding(8)
        }
        .themedSidebarSurface(theme.core)
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            handleDrop(providers)
        }
        .publishSidebarWidth()
        .sheet(item: $pendingAddWorktree) { request in
            AddWorktreeSheet(
                repoDisplayName: request.repo.displayName,
                initialWorktreeName: request.prefill,
                branchEntries: currentBranchEntries(forRepo: request.repo),
                onSubmit: { worktreeName, branch in
                    let err = await onAddWorktree(request.repo, worktreeName, branch)
                    if err == nil { pendingAddWorktree = nil }
                    return err
                },
                onCancel: { pendingAddWorktree = nil }
            )
        }
    }

    /// Builds the eligible-branch list for the Add Worktree sheet,
    /// merging the latest remote-branch snapshot with the repo's
    /// currently-mounted branches (so the picker can dim/disable them)
    /// and any in-flight PR metadata. `filterText` is "" — the
    /// `BranchPicker` does live-filtering against the full list itself.
    private func currentBranchEntries(forRepo repo: RepoEntry) -> [BranchPickerEntry] {
        let snapshot = remoteBranchStore.branchesByRepo[repo.path] ?? RemoteBranchSnapshot()
        var mounted: [String: String] = [:]
        for wt in repo.worktrees where wt.state.hasOnDiskWorktree {
            mounted[wt.branch] = wt.path
        }
        let prs = prStatusStore.prsByRepoBranch[repo.path] ?? [:]
        return BranchPickerViewModel.entries(
            branchSnapshot: snapshot,
            mountedBranchToPath: mounted,
            prsByBranch: prs,
            filterText: ""
        )
    }

    /// Title + destination for the repo's "Open on <forge>…"
    /// context-menu item, or nil when the origin is unresolved or
    /// unsupported, in which case the menu omits the item
    /// (PROJECT-2.2).
    private func forgeLink(
        for repo: RepoEntry
    ) -> (menuTitle: String, url: URL)? {
        guard let origin = prStatusStore.originByRepo[repo.path],
              let presentation = ForgePresentation(origin: origin),
              let url = origin.webURL else { return nil }
        return (presentation.menuTitle, url)
    }

    @ViewBuilder
    private func repoSection(_ repo: RepoEntry) -> some View {
        let forgeLink = forgeLink(for: repo)
        let resolvedDefaultBranch = remoteBranchStore.resolvedDefaultBranch(
            forRepoAt: repo.path,
            hint: repo.defaultBranchHint
        )
        let worktreeLabels = SidebarWorktreeLabel.texts(
            for: repo.worktrees,
            inRepoAtPath: repo.path,
            defaultBranch: resolvedDefaultBranch
        )
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
                worktreeBlock(
                    worktree,
                    repo: repo,
                    displayName: worktreeLabels[worktree.id] ?? SidebarWorktreeLabel.text(
                        for: worktree,
                        inRepoAtPath: repo.path,
                        siblingPaths: repo.worktrees.map(\.path),
                        defaultBranch: resolvedDefaultBranch
                    )
                )
                    // Outdent the worktree rows so each row's state
                    // indicator lines up under the parent repo's folder
                    // icon rather than sitting further right than the
                    // repo's disclosure label. -20pt counters the
                    // DisclosureGroup child indent minus the leading
                    // width of the icon column on the repo header.
                    .listRowInsets(EdgeInsets(top: 0, leading: -20, bottom: 0, trailing: 0))
            }
            .onMove { fromOffsets, toOffset in
                guard fromOffsets.allSatisfy({ repo.worktrees.indices.contains($0) }) else { return }
                appState.moveWorktrees(
                    inRepoID: repo.id,
                    movingWorktreeIDs: fromOffsets.map { repo.worktrees[$0].id },
                    toIndex: toOffset
                )
            }

            // SYNC-5.1: teammates' worktrees, read-only and ambient,
            // rendered after the local worktrees. No Button/action, no
            // drag/drop, no context menu, no selection highlight.
            ForEach(presenceStore.remoteWorktrees[repo.path] ?? []) { remote in
                RemoteWorktreeRow(presence: remote, theme: theme)
                    // Match the local rows' outdent so the person icon
                    // lines up under the repo header's leading column.
                    .listRowInsets(EdgeInsets(top: 0, leading: -20, bottom: 0, trailing: 0))
            }
        } label: {
            // No leading glyph — the top level is always projects, so
            // a folder icon would be tautological noise, and even an
            // informative forge logo proved to be repeated clutter in
            // practice (the "Open on GitHub…" affordance lives in the
            // context menu instead). The disclosure arrow and semibold
            // weight carry the "expandable heading" cues on their own.
            // Trailing "+" opens the add-worktree sheet;
            // .buttonStyle(.plain) keeps its tap from toggling the
            // enclosing disclosure.
            HStack(spacing: 6) {
                Text(repo.displayName)
                    .foregroundColor(theme.foreground)
                    .fontWeight(.semibold)
                Spacer()
                if SidebarMenuVisibility.showsAddWorktree(repo: repo) {
                    Button {
                        // Kick off fresh branch + PR data so the
                        // BranchPicker renders something current as
                        // the sheet appears, even if the polling
                        // cadence is in a long-backoff.
                        remoteBranchStore.pulse()
                        prStatusStore.pulse()
                        pendingAddWorktree = AddWorktreeRequest(repo: repo, prefill: "")
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(theme.sidebarDimIcon)
                            .frame(width: 18, height: 18)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Add worktree to \(repo.displayName)")
                }
            }
            .contextMenu {
                if !repo.isGitTracked {
                    Button("Initialize Git Repository") {
                        onInitializeGit(repo)
                    }
                }
                // PROJECT-2.3: context-menu forge link.
                if let forge = forgeLink {
                    Button(forge.menuTitle) {
                        NSWorkspace.shared.open(forge.url)
                    }
                }
                // SYNC-5.1: opt-in presence sharing. Git-tracked repos
                // only — non-git projects have no origin to publish a
                // presence ref to.
                if repo.isGitTracked {
                    Button(
                        repo.presenceSharingEnabled
                            ? "Stop Sharing Worktrees with Team"
                            : "Share Worktrees with Team"
                    ) {
                        onToggleTeamSharing(repo.path)
                    }
                }
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
    private func worktreeBlock(
        _ worktree: WorktreeEntry,
        repo: RepoEntry,
        displayName: String
    ) -> some View {
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
                    displayName: displayName,
                    isMainCheckout: worktree.path == repo.path,
                    theme: theme,
                    stats: statsStore.stats[worktree.path],
                    baseRef: statsStore.baseRef(
                        worktreePath: worktree.path,
                        repoPath: repo.path
                    ),
                    prBadge: prStatusStore.infos[worktree.path].map {
                        PRBadge(
                            number: $0.number,
                            state: $0.state,
                            checks: $0.checks,
                            mergeable: $0.mergeable,
                            url: $0.url
                        )
                    },
                    attentionStyle: attention.worktreeCapsule
                )
            }
            .buttonStyle(.plain)
            // PWD-1.4: same-repo drop target. Sources are sidebar pane
            // rows wrapped in `TransferablePaneSlotID`. Cross-repo drops
            // are rejected so a user can't accidentally hop a pane
            // across repos (out of scope, matches PWD-1.3).
            .dropDestination(for: TransferablePaneSlotID.self) { items, _ in
                guard let item = items.first else { return false }
                let sourceID = PaneSlotID(id: item.id)
                // In-flight rows are about to materialize or vanish —
                // a drop here would land on a worktree that won't exist
                // (or might revert) by the time the move completes.
                guard !worktree.state.isInFlight else { return false }
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
                    let sessionName = worktree.paneSessions[terminalID]
                        .map(ZmxLauncher.sessionName(for:))
                    Button {
                        onSelectPane(worktree.path, terminalID)
                    } label: {
                        PaneTitleRow(
                            title: terminalManager.displayTitle(for: terminalID),
                            isActiveWorktree: isActive,
                            isFocusedPane: isActive
                                && worktree.focusedPaneSlotID == terminalID,
                            isBusy: AgentLivenessMerge.isPaneBusy(
                                sessionName: sessionName,
                                liveness: claudeSessionRegistry.livenessBySession),
                            theme: theme,
                            // The pane-scoped capsule (agent-stop icon, or
                            // notify/✓! text) renders directly; busy/idle no
                            // longer feed it.
                            attentionStyle: attention.paneCapsules[terminalID],
                            portBindings: portBindings.bindings[terminalID] ?? []
                        )
                    }
                    .buttonStyle(.plain)
                    // PWD-1.4: pane rows are drag sources. The payload
                    // is a typed wrapper around the pane's UUID so
                    // SwiftUI's Transferable matching keeps unrelated
                    // drops from being mis-decoded as panes.
                    .draggable(TransferablePaneSlotID(id: terminalID.id))
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
        // PWD-1.5: drop-target highlight. Stroked so it composes with
        // the active-worktree background fill above when the dragged-
        // onto row is also the active one.
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(theme.foreground.opacity(isDropTarget ? 0.5 : 0), lineWidth: 1.5)
        )
    }

    /// Worktree row's right-click menu. Built as `NSMenu` (not a
    /// SwiftUI `.contextMenu`) for the List-row hoisting reason
    /// `.rightClickMenu` documents.
    private func buildWorktreeMenu(_ worktree: WorktreeEntry, repo: RepoEntry) -> NSMenu {
        let menu = NSMenu()
        // In-flight rows have nothing the menu actions can act on
        // safely — Open-in-Finder, Stop, and Delete-Worktree would all
        // either error or race the flow that owns the placeholder.
        if worktree.state.isInFlight {
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
        if SidebarMenuVisibility.showsDeleteWorktree(worktree: worktree, repo: repo)
            && worktree.state != .stale {
            menu.addItem(ClosureMenuItem(title: "Delete Worktree") { [self] in
                onDeleteWorktree(worktree.path)
            })
        }
        // TEAM-7.2: team-aware items appear when the worktree is in a
        // team-enabled repo with ≥2 worktrees.
        if agentTeamsEnabled,
           let team = TeamView.team(for: worktree, in: appState.repos, teamsEnabled: true) {
            menu.addItem(.separator())
            // TEAM-7.2: opens the activity-log window for this team.
            let teamID = TeamLookup.id(of: team)
            let teamName = team.repoDisplayName
            let openWindow = self.openWindow
            menu.addItem(ClosureMenuItem(title: "Show Team Activity…") {
                openWindow(
                    id: TeamActivityLogWindowID.windowGroupID,
                    value: TeamActivityLogWindowID(teamID: teamID, teamName: teamName)
                )
            })
        }
        return menu
    }

    /// AppKit-side pane right-click menu (PWD-1.1 / PWD-1.3 / LAYOUT-2.7
    /// / TERM-8.10). The Move section is shared with the terminal-surface
    /// menu via `PaneMoveMenuBuilder`; the Copy-web-URL item is sidebar-
    /// only because the surface has no worktree-context-free way to know
    /// its session name without going through this same view tree.
    private func buildPaneMenu(terminalID: PaneSlotID) -> NSMenu {
        let menu = NSMenu()
        let defaultBranches = PaneMoveMenuContext.defaultBranches(
            for: appState.repos,
            using: remoteBranchStore
        )
        if let context = PaneMoveMenuContext.resolve(
            terminalID: terminalID,
            appState: appState,
            shellCwd: terminalManager.shellCwd(for: terminalID),
            defaultBranchesByRepoPath: defaultBranches
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
           let host = webController.serverHostname,
           let indices = appState.indicesOfWorktreeContaining(terminalID: terminalID),
           let sessionID = appState.repos[indices.repo].worktrees[indices.worktree].paneSessions[terminalID] {
            menu.addItem(.separator())
            menu.addItem(ClosureMenuItem(title: "Copy web URL") {
                Pasteboard.copy(WebURLComposer.url(
                    session: ZmxLauncher.sessionName(for: sessionID),
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
