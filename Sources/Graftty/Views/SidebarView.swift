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
    @ObservedObject var remoteMacsModel: RemoteMacsModel
    let selectedRemoteIdentity: RemoteMacIdentity?
    let selectedRemoteWorktreePath: String?
    let selectedRemotePaneSessionName: String?
    let onSelect: (String) -> Void
    let onSelectPane: (String, PaneSlotID) -> Void
    let onSelectRemoteMac: (RemoteMac) -> Void
    let onSelectRemoteWorktree: (RemoteMac, String) -> Void
    let onSelectRemotePane: (RemoteMac, String, String) -> Void
    let onAddRemoteWorktree: (RemoteMac, RemoteRepositoryInfo) -> Void
    let onDeleteRemoteWorktree: (RemoteMac, WorktreePanes) -> Void
    let onAddRemoteMac: () -> Void
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
                RemoteMacsSection(
                    model: remoteMacsModel,
                    worktreePanesByRemote: remoteMacsModel.worktreePanesByRemote,
                    selectedRemoteIdentity: selectedRemoteIdentity,
                    selectedRemoteWorktreePath: selectedRemoteWorktreePath,
                    selectedRemotePaneSessionName: selectedRemotePaneSessionName,
                    theme: theme,
                    onSelectRemoteMac: onSelectRemoteMac,
                    onSelectRemoteWorktree: onSelectRemoteWorktree,
                    onSelectRemotePane: onSelectRemotePane,
                    onAddRemoteWorktree: onAddRemoteWorktree,
                    onDeleteRemoteWorktree: onDeleteRemoteWorktree,
                    onAddRemoteMac: onAddRemoteMac
                )
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
                defaultBranchStatus: defaultBranchStatus(
                    for: request.repo,
                    stats: statsStore.stats[request.repo.path]
                ),
                onPullDefaultBranch: {
                    await pullDefaultBranch(for: request.repo)
                },
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

    private func pullDefaultBranch(for repo: RepoEntry) async -> String? {
        guard let status = defaultBranchStatus(
            for: repo,
            stats: statsStore.stats[repo.path]
        ) else {
            return nil
        }
        do {
            try await GitDefaultBranchPull.pull(repoPath: repo.path, branchName: status.branchName)
        } catch GitDefaultBranchPull.Error.gitFailed(_, let stderr) {
            return stderr
        } catch {
            return "\(error)"
        }
        let branch = repo.worktrees.first(where: { $0.path == repo.path })?.branch ?? ""
        statsStore.refresh(worktreePath: repo.path, repoPath: repo.path, branch: branch)
        return nil
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
        let worktreeNodes = SidebarWorktreeHierarchy.nodes(
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
            OutlineGroup(worktreeNodes, children: \.children) { node in
                worktreeNode(node, repo: repo)
            }
            // Outdent the hierarchy roots so their state indicator or
            // folder icon lines up beneath the repository label. OutlineGroup
            // adds its own relative indentation for descendants, so nested
            // worktrees still sit one level beneath their virtual folder.
            .listRowInsets(EdgeInsets(top: 0, leading: -20, bottom: 0, trailing: 0))
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
                Button("Remove Repository") {
                    onRemoveRepo(repo)
                }
            }
        }
    }

    @ViewBuilder
    private func worktreeNode(
        _ node: SidebarWorktreeNode,
        repo: RepoEntry
    ) -> some View {
        switch node {
        case .worktree(let worktree, let displayName):
            worktreeBlock(
                worktree,
                repo: repo,
                displayName: displayName
            )
        case .folder(_, let name, _):
            HStack(spacing: 6) {
                Image(systemName: "folder")
                    .font(.system(size: 12))
                    .foregroundColor(theme.sidebarDimIcon)
                Text(name)
                    .lineLimit(1)
                    .foregroundColor(theme.sidebarPrimaryText(isActive: false))
            }
            .contentShape(Rectangle())
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
        let isActive = appState.selectedWorktreePath == worktree.path && selectedRemoteIdentity == nil
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
            .worktreeReorderTarget(
                repoID: repo.id,
                worktreeID: worktree.id,
                appState: $appState
            )
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
                dismissWorktree(worktree)
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

    private func dismissWorktree(_ worktree: WorktreeEntry) {
        StaleWorktreeDismissal.dismiss(
            worktreeID: worktree.id,
            appState: $appState,
            destroySurfaces: {
                terminalManager.destroySurfaces(terminalIDs: $0)
            },
            clearPRStatus: {
                prStatusStore.clear(worktreePath: $0)
            },
            clearStats: {
                statsStore.clear(worktreePath: $0)
            }
        )
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
