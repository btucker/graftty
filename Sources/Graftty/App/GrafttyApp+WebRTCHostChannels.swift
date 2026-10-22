import SwiftUI
import AppKit
import CryptoKit
import GrafttyCommandUI
import GrafttyHostAgent
import GrafttyKit
import GrafttyProtocol
import GrafttyRemoteClient

 extension PaneControlRequest {
    fileprivate
    var primaryTarget: String? {
        switch self {
        case .split(let target, _), .close(let target),
             .equalize(let target), .resize(let target, _, _, _):
            return target
        case .swap(let source, _):
            return source
        }
    }
}

 extension WorktreeManagementRequest {
    fileprivate
    var targetsRelayedResource: Bool {
        switch self {
        case .agentCompletions, .hostPresentation, .listRepositories, .moveProject,
             .listRemoteMacConnections, .connectRemoteMac:
            return false
        case .create(let repositoryID, _, _, _),
             .pullDefaultBranch(let repositoryID), .projectIcon(let repositoryID, _),
             .moveWorktree(let repositoryID, _, _, _), .setWorktreeOrder(let repositoryID, _):
            return repositoryID.hasPrefix("relay-repository-")
        case .worktreeAgentCompletions(let worktreeID), .openResource(let worktreeID, _), .open(let worktreeID),
             .delete(let worktreeID, _),
             .acknowledge(let worktreeID, _), .acknowledgeOccurrence(let worktreeID, _, _):
            return worktreeID.hasPrefix("relay-worktree-")
        }
    }
}

extension GrafttyApp {
    /// Builds the paired-device `PaneControlChannelHandler` mutator. Relayed
    /// panes forward to their owning Mac; local targets map session names to
    /// `PaneSlotID`s and drive the same pane-layout statics as the sidebar.
    private static func makePaneControlMutator(
        appState appStateBinding: Binding<AppState>,
        terminalManager: TerminalManager,
        services: AppServices
    ) -> PaneControlChannelHandler.Mutator {
        let paneControlMutator: PaneControlChannelHandler.Mutator = { request in
            if let target = request.primaryTarget,
               target.hasPrefix("relay-pane-") {
                return await services.remoteMacsModel.sendRelayedPaneControl(request)
                    ?? .error(
                        code: "not-found",
                        message: "unknown or disconnected relayed pane"
                    )
            }
            return await MainActor.run { () -> PaneControlResponse in
                switch request {
                case .split(let target, let direction):
                    guard let paneID = terminalManager.paneID(forSessionName: target) else {
                        return .error(
                            code: "not-found",
                            message: "no pane with session name '\(target)'"
                        )
                    }
                    let split: PaneSplit
                    switch direction {
                    case .right:
                        split = .right
                    case .down:
                        split = .down
                    case .left:
                        split = .left
                    case .up:
                        split = .up
                    }
                    let slot = PaneSlotID(id: paneID)
                    let targetWorktreePath =
                        appStateBinding.wrappedValue.repos.lazy
                        .flatMap(\.worktrees)
                        .first(where: {
                            $0.splitTree.containsLeaf(slot)
                        })?.path
                    let targetIsVisible =
                        !NSApp.isHidden
                        && terminalManager.view(for: slot)?
                            .window?.isVisible == true
                        && appStateBinding.wrappedValue
                            .selectedWorktreePath.flatMap {
                                appStateBinding.wrappedValue
                                    .worktree(forPath: $0)
                            }?.splitTree.containsLeaf(slot) == true
                    guard let newID = PaneCommands.splitPane(
                        appState: appStateBinding,
                        terminalManager: terminalManager,
                        targetID: slot,
                        split: split,
                        activateNewPane: false,
                        preserveZoom: true
                    ) else {
                        return .error(
                            code: "conflict",
                            message: "split rejected (target not in a running worktree, or surface creation failed)"
                        )
                    }
                    if !targetIsVisible {
                        terminalManager.setVisible(false, for: newID)
                    }
                    if let targetWorktreePath {
                        terminalManager.surfaceBudget.noteCreated(
                            worktreePath: targetWorktreePath,
                            splitTreesByPath: appStateBinding.wrappedValue
                                .runningSplitTreesByPath()
                        )
                    }
                    guard let sessionName = terminalManager
                        .zmxSessionName(for: newID) else {
                        return .error(
                            code: "conflict",
                            message: "split succeeded without a pane session"
                        )
                    }
                    return .splitCreated(sessionName: sessionName)
                case .close(let target):
                    guard let paneID = terminalManager.paneID(forSessionName: target) else {
                        return .error(
                            code: "not-found",
                            message: "no pane with session name '\(target)'"
                        )
                    }
                    let slot = PaneSlotID(id: paneID)
                    let targetIsVisible =
                        !NSApp.isHidden
                        && terminalManager.view(for: slot)?
                            .window?.isVisible == true
                        && appStateBinding.wrappedValue
                            .selectedWorktreePath.flatMap {
                                appStateBinding.wrappedValue
                                    .worktree(forPath: $0)
                            }?.splitTree.containsLeaf(slot) == true
                    PaneCommands.closePane(
                        appState: appStateBinding,
                        terminalManager: terminalManager,
                        targetID: slot,
                        userInitiated: true,
                        activateReplacement: targetIsVisible
                    )
                    return .ok
                case .swap:
                    // No `swapPanes` exists on the desktop side yet —
                    // the AppState splittree API doesn't expose a swap
                    // primitive, and adding one is out of scope for R5
                    // per the plan's "don't refactor AppState" guidance.
                    // Follow-up: REMOTE-7.x swap support.
                    return .error(
                        code: "unsupported",
                        message: "swap is not implemented on this host yet"
                    )
                case .equalize(let target):
                    guard let paneID = terminalManager.paneID(
                        forSessionName: target
                    ) else {
                        return .error(
                            code: "not-found",
                            message: "no pane with session name '\(target)'"
                        )
                    }
                    PaneCommands.equalizeSplits(
                        appState: appStateBinding,
                        around: PaneSlotID(id: paneID),
                        preserveZoom: true
                    )
                    return .ok
                case let .resize(
                    target,
                    direction,
                    amount,
                    viewportExtent
                ):
                    guard let paneID = terminalManager.paneID(
                        forSessionName: target
                    ) else {
                        return .error(
                            code: "not-found",
                            message: "no pane with session name '\(target)'"
                        )
                    }
                    let resizeDirection: ResizeDirection
                    switch direction {
                    case .right:
                        resizeDirection = .right
                    case .down:
                        resizeDirection = .down
                    case .left:
                        resizeDirection = .left
                    case .up:
                        resizeDirection = .up
                    }
                    let viewerBounds = viewportExtent.map { extent in
                        switch direction {
                        case .left, .right:
                            return CGRect(
                                x: 0,
                                y: 0,
                                width: CGFloat(extent),
                                height: 1
                            )
                        case .up, .down:
                            return CGRect(
                                x: 0,
                                y: 0,
                                width: 1,
                                height: CGFloat(extent)
                            )
                        }
                    }
                    guard PaneCommands.resizeSplit(
                        appState: appStateBinding,
                        target: PaneSlotID(id: paneID),
                        direction: resizeDirection,
                        pixels: amount,
                        ancestorBounds: viewerBounds,
                        preserveZoom: true
                    ) else {
                        return .error(
                            code: "no-matching-split",
                            message: "no split in that direction can be resized"
                        )
                    }
                    return .ok
                }
            }
        }
        return paneControlMutator
    }

    /// Builds the paired-device `WorktreeManagementChannelHandler` mutator.
    /// Relayed resources forward to their owning Mac; local requests run
    /// against `appState` and the shared worktree flows.
    private static func makeWorktreeManagementMutator(
        appState appStateBinding: Binding<AppState>,
        terminalManager: TerminalManager,
        services: AppServices,
        portScanner panesPortScanner: PortScanner,
        localWorktreeOrigin: WorktreeOrigin
    ) -> WorktreeManagementChannelHandler.Mutator {
        let worktreeMonitor = services.worktreeMonitor
        let statsStore = services.statsStore
        let dispatcherForWeb = services.teamEventDispatcher
        let panesRemoteBranchStore = services.remoteBranchStore
        let localRepositorySnapshot: @MainActor () -> [RemoteRepositoryInfo] = {
            appStateBinding.wrappedValue.repos.map { repo in
                let snapshot = panesRemoteBranchStore.branchesByRepo[repo.path]
                    ?? RemoteBranchSnapshot()
                var mounted: [String: String] = [:]
                for worktree in repo.worktrees
                where worktree.state.hasOnDiskWorktree {
                    mounted[worktree.branch] = worktree.path
                }
                let pullRequests = services.prStatusStore.prsByRepoBranch[
                    repo.path
                ] ?? [:]
                let branches = BranchPickerViewModel.entries(
                    branchSnapshot: snapshot,
                    mountedBranchToPath: mounted,
                    prsByBranch: pullRequests,
                    filterText: ""
                ).map { branch in
                    RemoteRepositoryInfo.Branch(
                        name: branch.name,
                        source: branch.source == .local
                            ? .local
                            : .remoteOnly,
                        lastCommitDate: branch.lastCommitDate,
                        mountedWorktreeID: branch.mountedWorktreePath,
                        pullRequest: branch.pr.map {
                            .init(number: $0.number, title: $0.title)
                        }
                    )
                }
                let status = defaultBranchStatus(
                    for: repo,
                    stats: statsStore.stats[repo.path]
                )
                return RemoteRepositoryInfo(
                    id: repo.path,
                    displayName: repo.displayName,
                    origin: localWorktreeOrigin,
                    defaultBranchStatus: status.map {
                        .init(
                            branchName: $0.branchName,
                            remoteRef: $0.remoteRef,
                            behindCount: $0.behindCount
                        )
                    },
                    branches: branches
                )
            }
        }

        let worktreeManagementMutator:
            WorktreeManagementChannelHandler.Mutator = { request in
            if request.targetsRelayedResource {
                return await services.remoteMacsModel
                    .sendRelayedWorktreeManagement(request)
                    ?? .error(
                        code: "not-found",
                        message: "unknown or disconnected relayed resource",
                        forceAllowed: false,
                        shortStatus: nil
                    )
            }

            switch request {
            case .agentCompletions:
                return .agentCompletions(await terminalManager.agentCompletionLoader?(nil, nil) ?? [])
            case .worktreeAgentCompletions(let worktreeID):
                return .agentCompletions(await terminalManager.agentCompletionLoader?(worktreeID, nil) ?? [])
            case let .openResource(worktreeID, request):
                do {
                    switch request {
                    case .list:
                        return .openResource(.offers(await RemoteOpenStore.shared.list(worktree: worktreeID)))
                    case .authenticate(let url):
                        guard let authentication = WorktreeAuthenticationURL(url: url) else {
                            return .error(code: "invalid-authentication", message: "This link has no supported local sign-in callback.", forceAllowed: false, shortStatus: nil)
                        }
                        let paneIDs = await MainActor.run { () -> [PaneSlotID] in
                            guard let worktree = appStateBinding.wrappedValue.worktree(forPath: worktreeID),
                                  worktree.state == .running else { return [] }
                            return worktree.splitTree.allLeaves
                        }
                        let bindings = await panesPortScanner.refreshedBindings(for: paneIDs)
                        let listeners = bindings.map {
                            WorktreePort(port: $0.port, scope: $0.scope == .lan ? .lan : .loopback,
                                         processName: $0.processName, host: $0.host)
                        }
                        return await MainActor.run {
                            guard let worktree = appStateBinding.wrappedValue.worktree(forPath: worktreeID),
                                  worktree.state == .running, worktree.splitTree.allLeaves == paneIDs,
                                  let callbackHost = authentication.resolveCallbackHost(in: listeners) else {
                                return .error(code: "authentication-unavailable", message: "The sign-in callback is no longer listening in this worktree. Start re-auth again.", forceAllowed: false, shortStatus: nil)
                            }
                            return .openResource(.authentication(url: url, callbackHost: callbackHost))
                        }
                    case .port(let port):
                        let paneIDs = await MainActor.run { () -> [PaneSlotID] in
                            guard let worktree = appStateBinding.wrappedValue.worktree(forPath: worktreeID),
                                  worktree.state == .running else { return [] }
                            return worktree.splitTree.allLeaves
                        }
                        let listeners = await panesPortScanner.refreshedPorts(for: paneIDs)
                        return await MainActor.run {
                            guard let worktree = appStateBinding.wrappedValue.worktree(forPath: worktreeID),
                                  worktree.state == .running, worktree.splitTree.allLeaves == paneIDs,
                                  let url = listeners.first(where: { $0.port == port })?.url else {
                                return .error(code: "port-unavailable", message: "This port is no longer listening in this worktree.", forceAllowed: false, shortStatus: nil)
                            }
                            return .openResource(.url(url))
                        }
                    case let .read(id, offset):
                        return .openResource(.chunk(try await RemoteOpenStore.shared.read(id: id, worktree: worktreeID, offset: offset)))
                    }
                } catch {
                    return .error(code: "file-preview", message: error.localizedDescription, forceAllowed: false, shortStatus: nil)
                }

            case let .moveProject(id, relativeTo, after):
                return await MainActor.run {
                    var navigation = appStateBinding.wrappedValue.sidebarNavigation ?? .init()
                    navigation.order.discover(SidebarHostController.shared.localProjects(appStateBinding.wrappedValue.repos, owner: localWorktreeOrigin).map(\.id))
                    guard navigation.order.move(id, relativeTo: relativeTo, after: after) else {
                        return .error(code: "invalid-move", message: "Project order changed; refresh and try again.", forceAllowed: false, shortStatus: nil)
                    }
                    appStateBinding.wrappedValue.sidebarNavigation = navigation
                    return .ok
                }
            case let .setWorktreeOrder(repositoryID, mode):
                return await MainActor.run {
                    var candidate = appStateBinding.wrappedValue
                    guard SidebarHostNavigation.setWorktreeOrder(mode, in: &candidate, repositoryID: repositoryID) else {
                        return .error(code: "repository-unavailable", message: "The repository is no longer available for sorting.", forceAllowed: false, shortStatus: nil)
                    }
                    do {
                        try candidate.save(to: AppState.defaultDirectory)
                        appStateBinding.wrappedValue = candidate
                        return .ok
                    } catch {
                        return .error(code: "persistence-failed", message: error.localizedDescription, forceAllowed: false, shortStatus: nil)
                    }
                }
            case let .moveWorktree(repositoryID, worktreeID, relativeTo, after):
                return await MainActor.run {
                    guard SidebarHostNavigation.moveWorktree(in: &appStateBinding.wrappedValue, repositoryID: repositoryID, worktreeID: worktreeID, relativeTo: relativeTo, after: after) else {
                        return .error(code: "invalid-move", message: "Move worktrees within their folder, after the main checkout, while the repository uses manual order.", forceAllowed: false, shortStatus: nil)
                    }
                    return .ok
                }
            case let .projectIcon(repositoryID, revision):
                return await MainActor.run {
                    guard let repo = appStateBinding.wrappedValue.repos.first(where: { $0.path == repositoryID }),
                          let data = SidebarHostController.shared.icons[repo.id.uuidString],
                          ProjectIconDiscovery.revision(data) == revision else { return .icon(nil) }
                    return .icon(data)
                }
            case let .acknowledgeOccurrence(worktreeID, paneID, occurrence):
                return await MainActor.run {
                    guard SidebarHostNavigation.acknowledge(in: &appStateBinding.wrappedValue, worktreeID: worktreeID, paneID: paneID, occurrence: occurrence) else {
                        return .error(code: "occurrence-changed", message: "This request has changed or already cleared.", forceAllowed: false, shortStatus: nil)
                    }
                    return .ok
                }
            case .hostPresentation:
                let presentation = await MainActor.run {
                    RemoteHostPresentation(
                        ghosttyConfig:
                            terminalManager.mobilePresentationConfig(),
                        keybindings: GhosttyKeybindingsResponse(
                            chords: terminalManager.keybindBridge.allChords
                        )
                    )
                }
                return .hostPresentation(presentation)

            case .listRepositories:
                let local = await MainActor.run {
                    localRepositorySnapshot()
                }
                let remote = await services.remoteMacsModel
                    .promotedRepositoriesForRelay()
                return .repositories(local + remote)

            case .listRemoteMacConnections:
                return .remoteMacConnections(
                    await services.remoteMacsModel
                        .remoteMacConnectionSummaries()
                )

            case let .connectRemoteMac(deviceID, fingerprint):
                return await services.remoteMacsModel.reconnectRemoteMac(
                    deviceID: deviceID,
                    fingerprint: fingerprint
                )

            case let .create(
                repositoryID,
                worktreeName,
                branchName,
                existingSource
            ):
                let branch: BranchSelection
                if let existingSource {
                    let resolvedSource:
                        BranchSelection.ExistingSource?
                    switch existingSource {
                    case .local:
                        resolvedSource = .local
                    case .remoteOnly:
                        resolvedSource = .remoteOnly
                    case .automatic:
                        resolvedSource = try? await
                            GitExistingBranchSource.resolve(
                                repoPath: repositoryID,
                                branchName: branchName
                            )
                    }
                    guard let resolvedSource else {
                        return .error(
                            code: "branch-not-found",
                            message:
                                "No local or origin branch named "
                                + branchName + " exists.",
                            forceAllowed: false,
                            shortStatus: nil
                        )
                    }
                    branch = .useExisting(
                        name: branchName,
                        source: resolvedSource
                    )
                } else {
                    branch = .createNew(name: branchName)
                }
                let result = await AddWorktreeFlow.add(
                    repoPath: repositoryID,
                    worktreeName: worktreeName,
                    branch: branch,
                    appState: appStateBinding,
                    worktreeMonitor: worktreeMonitor,
                    statsStore: statsStore,
                    terminalManager: terminalManager,
                    teamEventDispatcher: dispatcherForWeb,
                    entryPoint: .pairedClient
                )
                switch result {
                case .success(let outcome):
                    return .created(
                        worktreeID: outcome.worktreePath,
                        paneID: outcome.sessionName
                    )
                case .failure(let error):
                    return .error(
                        code: "create-failed",
                        message: error.userMessage
                            ?? "could not create worktree",
                        forceAllowed: false,
                        shortStatus: nil
                    )
                }

            case .pullDefaultBranch(let repositoryID):
                let status = await MainActor.run {
                    () -> WebServer.RepoInfo.DefaultBranchStatus? in
                    guard let target = appStateBinding.wrappedValue.repos
                        .first(where: { $0.path == repositoryID }) else {
                        return nil
                    }
                    return defaultBranchStatus(
                        for: target,
                        stats: statsStore.stats[target.path]
                    )
                }
                guard let status else {
                    return .error(
                        code: "invalid",
                        message: "default checkout is not behind origin",
                        forceAllowed: false,
                        shortStatus: nil
                    )
                }
                do {
                    try await GitDefaultBranchPull.pull(
                        repoPath: repositoryID,
                        branchName: status.branchName
                    )
                    return .ok
                } catch {
                    return .error(
                        code: "pull-failed",
                        message: String(describing: error),
                        forceAllowed: false,
                        shortStatus: nil
                    )
                }

            case .open(let worktreeID):
                return await MainActor.run {
                    let result = PaneCommands.startWorktree(
                        path: worktreeID,
                        appState: appStateBinding,
                        terminalManager: terminalManager,
                        startSurfacesInBackground: true
                    )
                    let targetIsVisible =
                        !NSApp.isHidden
                        && NSApp.mainWindow?.isVisible == true
                        && appStateBinding.wrappedValue
                            .selectedWorktreePath == worktreeID
                    if result == .started || result == .alreadyRunning {
                        let splitTrees = appStateBinding.wrappedValue
                            .runningSplitTreesByPath()
                        if targetIsVisible {
                            terminalManager.surfaceBudget.noteSelected(
                                worktreePath: worktreeID,
                                splitTreesByPath: splitTrees
                            )
                        } else {
                            terminalManager.surfaceBudget.noteCreated(
                                worktreePath: worktreeID,
                                splitTreesByPath: splitTrees
                            )
                        }
                    }
                    if result == .started,
                       !targetIsVisible,
                       let worktree = appStateBinding.wrappedValue
                           .worktree(forPath: worktreeID) {
                        for terminalID in worktree.splitTree.allLeaves {
                            terminalManager.setVisible(
                                false,
                                for: terminalID
                            )
                        }
                    }
                    switch result {
                    case .started, .alreadyRunning:
                        return .ok
                    case .notFound:
                        return .error(
                            code: "not-found",
                            message: "unknown worktree",
                            forceAllowed: false,
                            shortStatus: nil
                        )
                    case .unavailable:
                        return .error(
                            code: "unavailable",
                            message: "worktree cannot be opened in its current state",
                            forceAllowed: false,
                            shortStatus: nil
                        )
                    }
                }

            case let .delete(worktreeID, force):
                let result = await DeleteWorktreeFlow.delete(
                    worktreePath: worktreeID,
                    force: force,
                    appState: appStateBinding,
                    terminalManager: terminalManager,
                    statsStore: statsStore,
                    prStatusStore: services.prStatusStore,
                    teamEventDispatcher: dispatcherForWeb
                )
                switch result {
                case .success(let outcome):
                    return .deleted(dismissed: outcome.dismissed)
                case .failure(.notFound):
                    return .error(
                        code: "not-found",
                        message: "unknown worktree",
                        forceAllowed: false,
                        shortStatus: nil
                    )
                case .failure(.mainCheckoutRejected):
                    return .error(
                        code: "invalid",
                        message: "cannot delete the main checkout",
                        forceAllowed: false,
                        shortStatus: nil
                    )
                case .failure(.gitFailedForceable(let stderr, let status)):
                    return .error(
                        code: "git-failed",
                        message: stderr,
                        forceAllowed: true,
                        shortStatus: status
                    )
                case .failure(.gitFailedFinal(let message)):
                    return .error(
                        code: "git-failed",
                        message: message,
                        forceAllowed: false,
                        shortStatus: nil
                    )
                }

            case let .acknowledge(worktreeID, paneID):
                return await MainActor.run {
                    for repoIndex in appStateBinding.wrappedValue.repos.indices {
                        for worktreeIndex in appStateBinding.wrappedValue
                            .repos[repoIndex].worktrees.indices
                        where appStateBinding.wrappedValue.repos[repoIndex]
                            .worktrees[worktreeIndex].path == worktreeID {
                            if let paneID {
                                guard let slot = appStateBinding.wrappedValue
                                    .repos[repoIndex].worktrees[worktreeIndex]
                                    .paneSlot(forSessionName: paneID) else {
                                    return .error(
                                        code: "not-found",
                                        message: "unknown pane in worktree",
                                        forceAllowed: false,
                                        shortStatus: nil
                                    )
                                }
                                appStateBinding.wrappedValue.repos[repoIndex]
                                    .worktrees[worktreeIndex]
                                    .acknowledgePaneAttention(slot)
                            } else {
                                appStateBinding.wrappedValue.repos[repoIndex]
                                    .worktrees[worktreeIndex]
                                    .acknowledgeAttention()
                            }
                            return .ok
                        }
                    }
                    return .error(
                        code: "not-found",
                        message: "unknown worktree",
                        forceAllowed: false,
                        shortStatus: nil
                    )
                }
            }
        }
        return worktreeManagementMutator
    }
}

extension GrafttyApp {
    /// Builds the paired-device `WebRTCHostAgentPool` and the channel
    /// callbacks every agent in it shares: panes-state subscriptions, pane
    /// control, worktree management, and the Chrome tab broker.
    ///
    /// `panesStateSubscribe`: emits initial snapshot, then polls
    /// `buildWorktreePanesSnapshot` on a 1Hz cadence and re-emits when
    /// the snapshot differs from the previously-sent one. Polling
    /// (rather than a pub-sub source) is intentional — AppState is a
    /// SwiftUI `@State` value type with no Combine/AsyncStream publisher,
    /// and the `/ws` HTTP path the desktop sidebar/web client uses is
    /// itself poll-based, so the SSH transport doesn't promise tighter
    /// freshness than the HTTP transport already provides. A pub-sub
    /// hook is left as a post-R6 follow-up.
    ///
    /// `paneControlMutator`: maps session-name targets to `PaneSlotID`
    /// via `TerminalManager.paneID(forSessionName:)` and dispatches to
    /// the same `splitPane` / `closePane` static methods the Mac sidebar
    /// context menu drives. `swap` returns `unsupported` — no native
    /// implementation exists yet; tracked as a post-R5 follow-up.
    static func makeHostAgentPool(
        hostKey: Curve25519.Signing.PrivateKey,
        appState appStateBinding: Binding<AppState>,
        terminalManager: TerminalManager,
        services: AppServices,
        buildWorktreePanesSnapshot: @escaping @Sendable @MainActor () -> [WorktreePanes],
        localWorktreeOrigin: WorktreeOrigin,
        portScanner panesPortScanner: PortScanner,
        zmxBinary: URL,
        zmxDir: URL
    ) -> WebRTCHostAgentPool {
        let trustedPeerStore = services.trustedPeerStore
        let sshConnectionRegistry = services.sshConnectionRegistry
        let panesStateSubscribe: PanesStateChannelHandler.Subscribe = { onChange in
            // Initial snapshot fires synchronously so the first frame
            // hits the wire before the polling loop's first sleep.
            let snapshot: @MainActor () -> PanesStateMessage = {
                let projects = SidebarHostController.shared.localProjects(appStateBinding.wrappedValue.repos, owner: localWorktreeOrigin)
                let navigation = SidebarSnapshot(projects: (appStateBinding.wrappedValue.sidebarNavigation?.order ?? .init()).sorted(projects))
                return .snapshot(buildWorktreePanesSnapshot(), sidebar: navigation)
            }
            let initial = await MainActor.run { snapshot() }
            await onChange(initial)

            let task = Task {
                var last = initial
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(1))
                    if Task.isCancelled { return }
                    let next = await MainActor.run { snapshot() }
                    if next != last {
                        last = next
                        await onChange(next)
                    }
                }
            }
            return PanesStateChannelHandler.Cancellable {
                task.cancel()
            }
        }

        let panesStateV2Subscribe: PanesStateChannelHandler.Subscribe = {
            onChange in
            let snapshot: @MainActor () async -> PanesStateMessage = {
                let remote = await services.remoteMacsModel.sidebarRelaySnapshot()
                let navigation = SidebarHostController.shared.snapshot(state: appStateBinding, owner: localWorktreeOrigin, remote: remote.projects,
                    authoritativeRemoteOwners: remote.authoritativeOwnerIDs, savedRemoteOwners: Set(services.remoteMacsModel.savedRemoteMacs.map(\.id)))
                let worktrees = buildWorktreePanesSnapshot() + remote.worktrees
                let order = Dictionary(navigation.projects.enumerated().map { ($1.id, $0) }, uniquingKeysWith: min)
                let sorted = worktrees.enumerated().sorted {
                    let a = order[SidebarProjection.projectID($0.element), default: .max]
                    let b = order[SidebarProjection.projectID($1.element), default: .max]
                    return a == b ? $0.offset < $1.offset : a < b
                }.map(\.element)
                return .snapshot(sorted, sidebar: navigation)
            }
            let initial = await snapshot()
            await onChange(initial)

            let task = Task {
                var last = initial
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(1))
                    if Task.isCancelled { return }
                    let next = await snapshot()
                    if next != last {
                        last = next
                        await onChange(next)
                    }
                }
            }
            return PanesStateChannelHandler.Cancellable {
                task.cancel()
            }
        }

        let paneControlMutator: PaneControlChannelHandler.Mutator = Self.makePaneControlMutator(
            appState: appStateBinding,
            terminalManager: terminalManager,
            services: services
        )
        let worktreeManagementMutator: WorktreeManagementChannelHandler.Mutator =
            Self.makeWorktreeManagementMutator(
                appState: appStateBinding,
                terminalManager: terminalManager,
                services: services,
                portScanner: panesPortScanner,
                localWorktreeOrigin: localWorktreeOrigin
            )

        // Explicit phone launch opts into an isolated worktree profile.
        let chromeBroker = ChromeTabBroker(authorize: { target, peerID in
            await MainActor.run {
                guard let peer = try? trustedPeerStore.get(id: RemoteDeviceID(value: peerID)),
                      peer.capabilities.terminalControl == .allowed,
                      peer.capabilities.worktreeManagement == .allowed,
                      terminalManager.paneID(forSessionName: target) != nil,
                      let path = terminalManager.worktreePath(forSessionName: target),
                      ChromeTabBroker.ownsDisplay(clientID: services.displayOwnershipStore.snapshot(sessionName: target).ownerClientID?.rawValue, peerID: peerID) else { return nil }
                return path
            }
        }, makeBackend: { DedicatedChromeBackend(worktreePath: $0) })
        let chromeTabMutator: ChromeTabChannelHandler.Mutator = { request, peer, viewer in
            await chromeBroker.handle(request, peerID: peer.value, viewerID: viewer)
        }
        let chromeTabOnDisconnect: ChromeTabChannelHandler.OnDisconnect = { viewer in
            await chromeBroker.disconnect(viewerID: viewer)
        }

        // Every device gets a fully configured connection agent. Shared
        // registries keep revocation and routing consistent across devices.
        let activeRemotePeers = ActiveRemotePeerRegistry()
        let hostAgentPool = WebRTCHostAgentPool(makeAgent: {
            [hostKey, trustedPeerStore, sshConnectionRegistry,
             terminalManager = terminalManager,
             registry = services.remoteAttachmentRegistry,
             remoteMacsModel = services.remoteMacsModel,
             remoteTeamRouter = services.remoteTeamRouter,
             displayOwnershipStore = services.displayOwnershipStore,
             activeRemotePeers, panesStateSubscribe, panesStateV2Subscribe,
             paneControlMutator, worktreeManagementMutator, chromeTabMutator, chromeTabOnDisconnect,
             zmxExe = zmxBinary, zmxDir] in
            let hostAgent = WebRTCHostAgent(
                hostKey: hostKey,
                trustedPeerStore: trustedPeerStore,
                activeRemotePeers: activeRemotePeers,
                streamFactory: {
                    [registry, terminalManager, remoteMacsModel, zmxExe, zmxDir] sessionName in
                    if sessionName.hasPrefix("relay-pane-") {
                        return try await remoteMacsModel.openRelayedTerminal(
                            alias: sessionName
                        )
                    }
                    let (workingDirectoryPath, spawnConfiguration) = await MainActor.run {
                        (terminalManager.worktreePath(forSessionName: sessionName),
                         terminalManager.remoteSpawnConfiguration(forSessionName: sessionName))
                    }
                    let workingDirectory = workingDirectoryPath.map {
                        URL(fileURLWithPath: $0, isDirectory: true)
                    }
                    let engine = ZmxAttachEngine(config: ZmxAttachEngine.Config(
                        zmxExecutable: zmxExe,
                        zmxDir: zmxDir,
                        sessionName: sessionName,
                        workingDirectory: workingDirectory,
                        spawnConfiguration: spawnConfiguration
                    ))
                    engine.attachmentRegistry = registry
                    try engine.start()
                    return engine
                },
                pagedFactory: { [registry, terminalManager, remoteMacsModel, zmxExe, zmxDir] sessionName in
                    if sessionName.hasPrefix("relay-pane-") {
                        return try await remoteMacsModel.openRelayedPagedTerminal(alias: sessionName)
                    }
                    let (path, spawnConfiguration) = await MainActor.run {
                        (terminalManager.worktreePath(forSessionName: sessionName),
                         terminalManager.remoteSpawnConfiguration(forSessionName: sessionName))
                    }
                    // Paging attaches only to existing daemons. A newly
                    // created mobile pane must first spawn its shell.
                    var bootstrap: ZmxAttachEngine?
                    defer { bootstrap?.close() }
                    let socket = zmxDir.appendingPathComponent(sessionName).path
                    if !FileManager.default.fileExists(atPath: socket) {
                        let session = ZmxAttachEngine(config: .init(
                            zmxExecutable: zmxExe, zmxDir: zmxDir, sessionName: sessionName,
                            workingDirectory: path.map { URL(fileURLWithPath: $0, isDirectory: true) },
                            spawnConfiguration: spawnConfiguration
                        ))
                        // Discard bootstrap output. The paged channel will
                        // obtain its own checkpoint once the daemon exists.
                        session.onPTYData = { _ in }
                        bootstrap = session
                        try session.start()
                        let deadline = ContinuousClock.now + .seconds(5)
                        while !FileManager.default.fileExists(atPath: socket), ContinuousClock.now < deadline {
                            try await Task.sleep(for: .milliseconds(20))
                        }
                    }
                    let engine = PagedZmxAttachEngine(config: .init(
                        zmxExecutable: zmxExe, zmxDir: zmxDir, sessionName: sessionName,
                        workingDirectory: path.map { URL(fileURLWithPath: $0, isDirectory: true) }
                    ))
                    engine.attachmentRegistry = registry
                    try await engine.start()
                    return engine
                },
                panesStateSubscribe: panesStateSubscribe,
                panesStateV2Subscribe: panesStateV2Subscribe,
                paneControlMutator: paneControlMutator,
                worktreeManagementMutator: worktreeManagementMutator,
                chromeTabMutator: chromeTabMutator, chromeTabOnDisconnect: chromeTabOnDisconnect,
                displayOwnershipStore: displayOwnershipStore,
                sshConnectionRegistry: sshConnectionRegistry
            )
            await hostAgent.setTeamMessaging(
                handler: { deviceID, data in
                    await remoteTeamRouter.receive(from: deviceID, data: data)
                },
                onConnect: { deviceID, session in
                    let label = (try? trustedPeerStore.get(id: deviceID))?.displayName ?? deviceID.value
                    await remoteTeamRouter.register(
                        deviceID: deviceID,
                        connectionID: session.id,
                        label: label,
                        closeForReconnect: { await session.close() }
                    ) { data in try await session.send(data) }
                },
                onDisconnect: { deviceID, connectionID in
                    await remoteTeamRouter.unregister(deviceID: deviceID, connectionID: connectionID)
                }
            )
            return hostAgent
        })
        return hostAgentPool
    }
}
