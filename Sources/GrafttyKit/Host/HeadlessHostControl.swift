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
            case .listRepositories:
                return .repositories(state.repos.map { RemoteRepositoryInfo(id: $0.path, displayName: $0.displayName, origin: nil, defaultBranchStatus: nil, branches: []) })
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
            case .projectIcon: return .icon(nil)
            default: return .error(code: "unsupported", message: "operation is unavailable on this host", forceAllowed: false, shortStatus: nil)
            }
            return .ok
        } catch { return .error(code: "host_operation_failed", message: String(describing: error), forceAllowed: false, shortStatus: nil) }
    }

    func handle(_ message: NotificationMessage) async -> ResponseMessage {
        do {
            switch message {
            case .listPanes(let path):
                let worktree = try requireWorktree(path)
                return .paneList(worktree.splitTree.allLeaves.enumerated().map { offset, slot in
                    PaneInfo(id: offset + 1, title: worktree.paneTitleMetadata[slot]?.title, focused: worktree.focusedPaneSlotID == slot)
                })
            case .addPane(let path, let direction, let command):
                let worktree = try requireWorktree(path)
                if let slot = worktree.focusedPaneSlotID ?? worktree.splitTree.allLeaves.first, let session = worktree.paneSessions[slot] {
                    _ = try await splitPane(target: launcher.sessionName(for: session), direction: PaneControlRequest.SplitDirection(rawValue: direction.rawValue) ?? .right, command: command)
                } else { _ = try await openWorktree(path, command: command) }
                return .ok
            case .closePane(let path, let index): try await closePane(target: paneSession(path, index: index))
            case .sendPane(let path, let index, let text, let enter):
                try await terminals.send(text + (enter ? "\r" : ""), to: paneSession(path, index: index))
            case .showPane(let path, let index, let lines):
                return .paneShow(try await terminals.show(paneSession(path, index: index), lines: lines))
            case .notify(let path, let text, let clearAfter, let session):
                guard Attention.isValidText(text) else { throw HostRuntimeError.invalid("invalid notification text") }
                let index = try indices(path)
                let attention = Attention(text: text, timestamp: Date())
                let slot = session.flatMap { state.repos[index.repo].worktrees[index.worktree].paneSlot(forSessionName: $0) }
                state.repos[index.repo].worktrees[index.worktree].setAttention(attention, pane: slot)
                try save()
                if let seconds = Attention.effectiveClearAfter(clearAfter) {
                    Task { [weak self] in
                        try? await Task.sleep(for: .seconds(seconds))
                        guard let self, let index = try? self.indices(path) else { return }
                        if let slot { self.state.repos[index.repo].worktrees[index.worktree].clearPaneAttentionIfTimestamp(attention.timestamp, for: slot) }
                        else { self.state.repos[index.repo].worktrees[index.worktree].clearAttentionIfTimestamp(attention.timestamp) }
                        try? self.save()
                    }
                }
            case .clear(let path, let session):
                let index = try indices(path)
                if let session, let slot = state.repos[index.repo].worktrees[index.worktree].paneSlot(forSessionName: session) {
                    state.repos[index.repo].worktrees[index.worktree].paneAttention[slot] = nil
                } else { state.repos[index.repo].worktrees[index.worktree].attention = nil }
                try save()
            case .attentionReport(let path, let agent, let recap):
                _ = try requireWorktree(path)
                guard recap.isValid else { throw HostRuntimeError.invalid("invalid attention recap") }
                recaps.report(recap, worktree: path, agentID: agent)
            case .teamSend(let path, let agent, let recipient, let text, let priority):
                if RemoteTeamAddress(rawValue: recipient) != nil {
                    guard let remoteTeamSender else { return .error("remote team connection is unavailable") }
                    return await remoteTeamSender(message)
                }
                _ = try teamHandler().send(callerWorktree: path, callerAgentID: agent, recipient: recipient, text: text, priority: priority, repos: state.repos, teamsEnabled: true)
            case .teamMessage(let path, let recipient, let text):
                _ = try teamHandler().send(callerWorktree: path, recipient: recipient, text: text, priority: .normal, repos: state.repos, teamsEnabled: true)
            case .teamBroadcast(let path, let agent, let text, let priority):
                _ = try teamHandler().broadcast(callerWorktree: path, callerAgentID: agent, text: text, priority: priority, repos: state.repos, teamsEnabled: true)
            case .teamReply(let path, let agent, let id, let text, let priority, let fallback):
                let request = try TeamReplyResolver(inbox: inbox).resolve(callerWorktree: path, callerAgentID: agent,
                    messageID: id, fallback: fallback, text: text, priority: priority, repos: state.repos, teamsEnabled: true)
                return await handle(request)
            case .teamInbox(let request):
                let page = try teamHandler().diagnosticPage(callerWorktree: request.callerWorktree,
                    callerAgentID: request.callerAgentID, consuming: request.consuming, worktree: request.worktree,
                    repo: request.repo, member: request.member, unread: request.unread, all: request.all,
                    beforeID: request.beforeID, afterID: request.afterID, snapshotThroughID: request.snapshotThroughID,
                    forwardPagination: request.forwardPagination, limit: request.limit, repos: state.repos, teamsEnabled: true)
                return .teamInbox(messages: page.messages, nextBeforeID: page.nextBeforeID, nextAfterID: page.nextAfterID, snapshotThroughID: page.snapshotThroughID)
            case .teamInboxAdvance(let path, let agent, let through):
                try teamHandler().advanceRead(callerWorktree: path, callerAgentID: agent, throughID: through, repos: state.repos, teamsEnabled: true)
            case .teamMembers(let caller, let worktree, let repo):
                let result = try teamHandler().members(callerWorktree: caller, worktree: worktree, repo: repo, repos: state.repos, teamsEnabled: true)
                return .teamList(teamName: result.teamName, members: result.members)
            case .teamList(let path):
                let result = try teamHandler().members(callerWorktree: path, worktree: nil, repo: nil, repos: state.repos, teamsEnabled: true)
                return .teamList(teamName: result.teamName, members: result.members)
            case .teamHook(let path, let agent, let runtime, let event, let sessionID, let pane, _, let active, _):
                let output = try teamHandler().hook(callerWorktree: path, runtime: runtime, event: event, sessionID: sessionID,
                    paneSessionName: pane, repos: state.repos, teamsEnabled: true, agentID: agent)
                if let pane {
                    if event == .userPromptSubmit || event == .preToolUse { busyAgents.insert(pane) }
                    if event == .stop { busyAgents.remove(pane) }
                }
                let index = try indices(path)
                let key = sessionID.map { "\(runtime.rawValue):\($0)" }
                if event == .stop {
                    switch recaps.stop(worktree: path, agentID: agent, stopHookActive: active) {
                    case .requestRecap: return .teamHookOutput(TeamHookRenderer.requestRecap())
                    case .record(let recap):
                        let slot = pane.flatMap { state.repos[index.repo].worktrees[index.worktree].paneSlot(forSessionName: $0) }
                        state.repos[index.repo].worktrees[index.worktree].recordAgentStop(SidebarAgentStop(agentName: runtime.rawValue,
                            stoppedAt: Date(), recap: recap, paneSlotID: slot?.id.uuidString, providerSessionKey: key))
                        SidebarHostNavigation.adoptReportedEmoji(recap, worktreePath: path, in: &state.repos)
                    }
                } else if event == .userPromptSubmit || event == .preToolUse || event == .postToolUse {
                    state.clearAgentStopAttention(worktreePath: path, providerSessionKey: key)
                }
                try save()
                return .teamHookOutput(output)
            case .providerActivity: break
            case .agentPromptStagingCapability, .worktreeBaseCapability, .worktreeCreateIdempotencyCapability,
                 .worktreeRemoveCapability, .worktreePinnedRemovalCapability, .worktreePinCapability: return .ok
            case .createWorktree(let caller, let name, let branch, let existing, let base, let command, let runtime, let prompt, let suppliedID):
                guard let repo = state.repo(forWorktreePath: caller) else { throw HostRuntimeError.notFound("caller is not registered") }
                let id = suppliedID ?? UUID().uuidString
                if let operation = creations[id] { return .worktreeCreate(operation) }
                let path = URL(fileURLWithPath: repo.path).appendingPathComponent(".worktrees").appendingPathComponent(name).path
                let pending = WorktreeCreateStatus(operationID: id, state: .pending, worktreePath: path, messageAddress: path)
                creations[id] = pending
                Task {
                    do {
                        let result = try await createWorktree(repository: repo.path, name: name, branch: branch,
                            existing: existing, base: base, command: command, agent: runtime, prompt: prompt, callerPath: caller)
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
                    let response = await handle(.createWorktree(callerWorktree: repo.path, worktreeName: creation.worktreeName,
                        branchName: creation.branchName, existing: creation.existing, base: creation.base,
                        command: creation.command, agentRuntime: creation.agentRuntime, agentPrompt: creation.agentPrompt,
                        operationID: creation.operationID))
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

    func teamHandler() -> TeamInboxRequestHandler {
        let presence = presence
        let dispatcher = TeamEventDispatcher(inbox: inbox, preferencesProvider: { TeamEventRoutingPreferences() }, templateProvider: { "" })
        return TeamInboxRequestHandler(inbox: inbox, dispatcher: dispatcher,
            agentRecords: { (try? presence.listAll()) ?? [] }, agentReachability: { TeamAgentReachability.isReachable($0) })
    }
}
