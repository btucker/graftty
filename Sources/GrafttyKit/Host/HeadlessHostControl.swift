import Foundation
import GrafttyProtocol

public extension HeadlessHostRuntime {
    func control(_ request: PaneControlRequest) async -> PaneControlResponse {
        do {
            switch request {
            case .split(let target, let direction):
                return .splitCreated(sessionName: try await splitPane(target: target, direction: direction))
            case .close(let target): try await closePane(target: target)
            case .equalize(let target):
                let (path, _) = try resolve(target)
                guard !busyPaths.contains(path) else { throw HostRuntimeError.busy("worktree operation in progress") }
                let index = try indices(path)
                state.repos[index.repo].worktrees[index.worktree].splitTree = state.repos[index.repo].worktrees[index.worktree].splitTree.equalizing()
                try save()
            case .resize(let target, let direction, let amount, let extent):
                let (path, slot) = try resolve(target)
                guard !busyPaths.contains(path) else { throw HostRuntimeError.busy("worktree operation in progress") }
                guard let extent, extent > 0 else { throw HostRuntimeError.invalid("viewport extent is required") }
                let index = try indices(path)
                let resizeDirection: ResizeDirection
                switch direction { case .left: resizeDirection = .left; case .right: resizeDirection = .right
                case .up: resizeDirection = .up; case .down: resizeDirection = .down }
                state.repos[index.repo].worktrees[index.worktree].splitTree = try state.repos[index.repo].worktrees[index.worktree].splitTree.resizing(
                    target: slot, direction: resizeDirection, pixels: amount,
                    ancestorBounds: CGRect(x: 0, y: 0, width: Int(extent), height: Int(extent)))
                try save()
            case .swap: throw HostRuntimeError.invalid("pane swap is unsupported")
            }
            return .ok
        } catch { return .error(code: "host_operation_failed", message: String(describing: error)) }
    }

    func manage(_ request: WorktreeManagementRequest) async -> WorktreeManagementResponse {
        do {
            switch request {
            case .agentCompletions:
                return .agentCompletions(AgentCompletionCatalog.local(repos: state.repos,
                    records: (try? presence.listAll()) ?? [], isReachable: TeamAgentReachability.isReachable))
            case .worktreeAgentCompletions(let worktreeID):
                let candidates = AgentCompletionCatalog.local(repos: state.repos,
                    records: (try? presence.listAll()) ?? [], isReachable: TeamAgentReachability.isReachable)
                return .agentCompletions(AgentCompletionCatalog.contextualized(candidates, worktreePath: worktreeID, repos: state.repos))
            case .listRepositories:
                return .repositories(await repositoryInfo())
            case .create(let repository, let name, let branch, let source):
                let result = try await createWorktree(repository: repository, name: name, branch: branch,
                    existing: source != nil, remoteOnly: source == .remoteOnly)
                return .created(worktreeID: result.path, paneID: result.session)
            case .open(let path): _ = try await openWorktree(path)
            case .delete(let path, let force):
                do { try await deleteWorktree(path, force: force); return .deleted(dismissed: false) }
                catch let GitWorktreeRemove.Error.gitFailed(_, stderr) {
                    let status = try? await GitRunner.run(args: ["status", "--short"], at: path)
                    return .error(code: "git_failed", message: stderr, forceAllowed: !force, shortStatus: status)
                }
            case .acknowledge(let path, let pane):
                let index = try indices(path)
                if let pane {
                    guard let slot = state.repos[index.repo].worktrees[index.worktree].paneSlot(forSessionName: pane) else { throw HostRuntimeError.notFound("pane not found") }
                    state.repos[index.repo].worktrees[index.worktree].acknowledgePaneAttention(slot)
                } else { state.repos[index.repo].worktrees[index.worktree].acknowledgeAttention() }
                try save()
            case .acknowledgeOccurrence(let path, let pane, let occurrence):
                _ = SidebarHostNavigation.acknowledge(in: &state, worktreeID: path, paneID: pane, occurrence: occurrence)
                try save()
            case .hostPresentation:
                return .hostPresentation(RemoteHostPresentation(ghosttyConfig: "", keybindings: .init(bindings: [:])))
            case .setWorktreeOrder(let repositoryID, let mode):
                var candidate = state
                guard SidebarHostNavigation.setWorktreeOrder(mode, in: &candidate, repositoryID: repositoryID) else {
                    return .error(code: "repository-unavailable", message: "The repository is no longer available for sorting.", forceAllowed: false, shortStatus: nil)
                }
                try candidate.save(to: configuration.stateDirectory)
                state = candidate
            case .moveWorktree(let repo, let path, let relative, let after):
                _ = SidebarHostNavigation.moveWorktree(in: &state, repositoryID: repo, worktreeID: path, relativeTo: relative, after: after)
                try save()
            case .pullDefaultBranch(let path):
                guard let repo = state.repos.first(where: { $0.path == path }), let branch = repo.defaultBranchHint else {
                    throw HostRuntimeError.notFound("repository default branch is unknown")
                }
                try acquire(path)
                defer { busyPaths.remove(path) }
                try await GitDefaultBranchPull.pull(repoPath: path, branchName: branch)
            case .listRemoteMacConnections: return .remoteMacConnections([])
            case .projectIcon(let repositoryID, let revision):
                guard let repo = state.repos.first(where: { $0.path == repositoryID }),
                      let icon = currentProjectIcon(for: repo), icon.revision == revision else { return .icon(nil) }
                return .icon(icon.data)
            default: return .error(code: "unsupported", message: "operation is unavailable on this host", forceAllowed: false, shortStatus: nil)
            }
            return .ok
        } catch { return .error(code: "host_operation_failed", message: String(describing: error), forceAllowed: false, shortStatus: nil) }
    }

    /// Control-socket entry point. Attention, recap, and team messages go
    /// through the dispatcher shared with the Mac app; the rest reach
    /// `hostRequest`.
    func handle(_ message: NotificationMessage) async -> ResponseMessage {
        if ControlRequestCore.handleMessage(message, platform: controlPlatform) { return .ok }
        return await ControlRequestCore.handleRequest(message, platform: controlPlatform) ?? .ok
    }

    internal func hostRequest(_ message: NotificationMessage, creationOrigin: WorktreeHistory.Origin? = nil) async -> ResponseMessage {
        do {
            switch message {
            case .listPanes(let path):
                let worktree = try requireWorktree(path)
                return .paneList(worktree.splitTree.allLeaves.enumerated().map { offset, slot in
                    PaneInfo(id: offset + 1, title: worktree.paneTitleMetadata[slot]?.title, focused: worktree.focusedPaneSlotID == slot)
                })
            case .addPane(let request):
                // The CLI probes `.paneAgentCapability` first, which this
                // host does not advertise; refuse rather than run a plain split.
                guard request.agentRuntime == nil, request.agentPrompt == nil else { throw HostRuntimeError.invalid("pane add --agent is not supported on this host") }
                let worktree = try requireWorktree(request.path)
                if let slot = worktree.focusedPaneSlotID ?? worktree.splitTree.allLeaves.first, let session = worktree.paneSessions[slot] {
                    _ = try await splitPane(target: launcher.sessionName(for: session), direction: PaneControlRequest.SplitDirection(rawValue: request.direction.rawValue) ?? .right, command: request.command)
                } else { _ = try await openWorktree(request.path, command: request.command) }
                return .ok
            case .closePane(let path, let index): try await closePane(target: paneSession(path, index: index))
            case .sendPane(let path, let index, let text, let enter):
                try await terminals.send(text + (enter ? "\r" : ""), to: paneSession(path, index: index))
            case .showPane(let path, let index, let lines):
                return .paneShow(try await terminals.show(paneSession(path, index: index), lines: lines))
            case .agentPromptStagingCapability, .worktreeBaseCapability, .worktreeCreateIdempotencyCapability,
                 .worktreeRemoveCapability, .worktreePinnedRemovalCapability, .worktreePinCapability: return .ok
            case .createWorktree(let request):
                guard let repo = state.repo(forWorktreePath: request.callerWorktree) else { throw HostRuntimeError.notFound("caller is not registered") }
                let id = request.operationID ?? UUID().uuidString
                if let operation = creations[id] { return .worktreeCreate(operation) }
                let path = URL(fileURLWithPath: repo.path).appendingPathComponent(".worktrees").appendingPathComponent(request.worktreeName).path
                let pending = WorktreeCreateStatus(operationID: id, state: .pending, worktreePath: path, messageAddress: path)
                creations[id] = pending
                Task {
                    do {
                        let exactCommand = WorktreeAgentLaunchCommand.shouldStagePrompt(
                            agent: request.agentRuntime, command: request.command, prompt: request.agentPrompt) ? nil : request.command
                        let result = try await createWorktree(repository: repo.path, name: request.worktreeName,
                            branch: request.branchName, existing: request.existing, base: request.base, command: exactCommand,
                            agent: request.agentRuntime, prompt: request.agentPrompt, callerPath: request.callerWorktree,
                            creationOrigin: creationOrigin)
                        creations[id] = WorktreeCreateStatus(operationID: id, state: .ready, worktreePath: result.path, messageAddress: result.path)
                    } catch {
                        creations[id] = WorktreeCreateStatus(operationID: id, state: .failed, worktreePath: path, messageAddress: path, error: String(describing: error))
                    }
                }
                return .worktreeCreate(pending)
            case .worktreeCreateStatus(let id):
                guard let operation = creations[id] else { throw HostRuntimeError.notFound("unknown creation operation") }
                return .worktreeCreate(operation)
            case .removeWorktree(let path, let force, let pinned):
                let worktree = try requireWorktree(path)
                guard !worktree.isPinned || pinned else { throw HostRuntimeError.invalid("unpin the worktree before deleting it") }
                let id = UUID().uuidString
                let pending = WorktreeRemoveStatus(operationID: id, state: .pending, worktreePath: path)
                removals[id] = pending
                Task {
                    do {
                        try await deleteWorktree(path, force: force, allowPinned: pinned)
                        removals[id] = WorktreeRemoveStatus(operationID: id, state: .removed, worktreePath: path)
                    } catch {
                        removals[id] = WorktreeRemoveStatus(operationID: id, state: .failed, worktreePath: path,
                            error: String(describing: error), forceAllowed: !force && !worktree.isPinned)
                    }
                }
                return .worktreeRemove(pending)
            case .worktreeRemoveStatus(let id):
                guard let operation = removals[id] else { throw HostRuntimeError.notFound("unknown removal operation") }
                return .worktreeRemove(operation)
            case .setWorktreePinned(let path, let pinned):
                let index = try indices(path)
                state.repos[index.repo].worktrees[index.worktree].isPinned = pinned
                try save()
            default: return .error("operation is unavailable on this host")
            }
            return .ok
        } catch { return .error(String(describing: error)) }
    }

    func remoteTeam(_ request: RemoteTeamRequest, deviceID: RemoteDeviceID) async -> RemoteTeamResponse {
        if case .worktree(let operation) = request {
            do {
                switch operation {
                case .status(let id):
                    guard let status = creations[id] else { return .error("unknown creation operation") }
                    return .worktreeCreate(status)
                case .create(let creation):
                    let repo = try await creation.destinationRepository(in: state.repos)
                    let response = await hostRequest(.createWorktree(callerWorktree: repo.path, worktreeName: creation.worktreeName,
                        branchName: creation.branchName, existing: creation.existing, base: creation.base,
                        command: creation.command, agentRuntime: creation.agentRuntime, agentPrompt: creation.agentPrompt,
                        operationID: creation.operationID), creationOrigin: creation.historyOrigin())
                    if case .worktreeCreate(let status) = response { return .worktreeCreate(status) }
                    if case .error(let error) = response { return .error(error) }
                    return .error("unexpected creation response")
                }
            } catch { return .error(String(describing: error)) }
        }
        let presence = presence
        return RemoteTeamService(inbox: inbox, agentRecords: { (try? presence.listAll()) ?? [] },
            agentReachability: { TeamAgentReachability.isReachable($0) })
            .handle(request, from: deviceID, repos: state.repos, teamsEnabled: true)
    }
}

extension HeadlessHostRuntime {
    func requireWorktree(_ path: String) throws -> WorktreeEntry {
        guard let worktree = state.worktree(forPath: path) else { throw HostRuntimeError.notFound("worktree is not registered") }
        return worktree
    }

    func paneSession(_ path: String, index: Int) throws -> String {
        let worktree = try requireWorktree(path)
        guard let slot = worktree.splitTree.leaf(atPaneID: index), let session = worktree.paneSessions[slot] else {
            throw HostRuntimeError.notFound("pane index is out of range")
        }
        return launcher.sessionName(for: session)
    }
}
