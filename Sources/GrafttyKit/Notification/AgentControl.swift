import Foundation

public enum AgentControlError: String, Error, LocalizedError {
    case unavailable, unknownAgent, owningSessionRequired, parentRequired, activeChildren, invalidRequest
    public var errorDescription: String? {
        switch self {
        case .unavailable: "Agent management is unavailable on this host."
        case .unknownAgent: "No matching managed agent in this project."
        case .owningSessionRequired: "Finish must be called from the agent's own terminal session."
        case .parentRequired: "Only the creating parent or the user can clean up this agent."
        case .activeChildren: "This agent has children that still require completion or cleanup."
        case .invalidRequest: "The agent request is missing a required value."
        }
    }
}

@MainActor
public enum AgentControl {
    public static func sessionContext(path: String, agentID: String?, paneSessionName: String?,
                                      provider: TeamHookRuntime, isSubagent: Bool = false, platform: any ControlPlatform) async throws -> String {
        guard !isSubagent else { return "" }
        guard let index = platform.state.indices(forWorktreePath: path) else { return "" }
        var worktree = platform.state.repos[index.repo].worktrees[index.worktree]
        // A provider started manually in an existing shell gains identity without
        // moving its saved view. Native subagents were excluded above.
        if let agentID, let session = paneSessionName, let slot = worktree.paneSlot(forSessionName: session),
           !worktree.agents.contains(where: { $0.paneSlotID == slot && $0.status != .closed }),
           !worktree.agents.contains(where: { $0.status == .starting && $0.paneSlotID == nil && $0.provider == provider }) {
            worktree.ensureWorkspaceLayout()
            var observed = ManagedAgent(name: provider.displayName, provider: provider, parent: nil)
            observed.nativeAgentID = agentID
            observed.paneSlotID = slot
            worktree.agents.append(observed)
            let previous = platform.state.repos[index.repo].worktrees[index.worktree]
            platform.state.repos[index.repo].worktrees[index.worktree] = worktree
            do { try platform.worktreeCreation.saveStateNow() }
            catch { platform.state.repos[index.repo].worktrees[index.worktree] = previous; throw error }
        }
        var sections: [String] = []
        if let session = paneSessionName, let slot = worktree.paneSlot(forSessionName: session),
           var agent = worktree.agents.first(where: { $0.paneSlotID == slot && $0.status != .closed })
                ?? worktree.agents.first(where: { $0.paneSlotID == nil && $0.status == .starting && $0.provider == provider }) {
            guard agent.provider == provider else { return "" }
            agent.paneSlotID = slot
            let previousNativeID = agent.nativeAgentID
            agent.nativeAgentID = agentID
            agent.observeWaiting(false)
            try save(agent, path: path, platform: platform)
            if let agentID, previousNativeID != agentID {
                let worktrees = platform.state.repo(forWorktreePath: path)?.worktrees ?? []
                for childWorktree in worktrees {
                    for var child in childWorktree.agents where child.parentManagedAgentID == agent.id {
                        guard let previous = child.parent else { continue }
                        child.parent = TeamInboxEndpoint(member: previous.member, worktree: path,
                            runtime: provider.rawValue, agentID: agentID)
                        // The old native inbox may have been read. The restarted parent
                        // needs its own durable copy; cleanup still has the same ID.
                        child.deliveredCompletionID = nil
                        try save(child, path: childWorktree.path, platform: platform)
                    }
                }
            }
            if let prompt = agent.initialPrompt, !prompt.isEmpty {
                sections.append("Saved initial assignment, for recovery only. If this is already in your launch context or completed, do not repeat it:\n" + prompt)
            }
            sections.append("Managed agent \(agent.id), assignment \(agent.assignmentID.uuidString). Finish the assignment with graftty agent finish \(agent.id) --assignment \(agent.assignmentID.uuidString) --result-stdin. A turn ending is not assignment completion.")
        }
        try await reconcileCompletions(repoIndex: index.repo, platform: platform)
        if let agentID {
            let pending = (platform.state.repo(forWorktreePath: path)?.worktrees.flatMap(\.agents) ?? []).filter {
                $0.parent?.agentID == agentID && $0.status == .awaitingCleanup
            }
            for child in pending {
                guard let completion = child.completion else { continue }
                sections.append("Cleanup pending for \(child.name) (\(child.id)): \(completion.result)\nHandle the result, then run graftty agent close \(child.id) --completion \(completion.id.uuidString).")
            }
        }
        return sections.joined(separator: "\n\n")
    }

    public static func handle(_ request: AgentControlRequest, platform: any ControlPlatform) async -> ResponseMessage {
        do {
            if request.action == .capability {
                return platform.controlCapabilities.contains(.managedAgents) ? .ok : .error("operation is unavailable on this host")
            }
            guard let repoIndex = platform.state.repos.firstIndex(where: { $0.worktrees.contains { $0.path == request.callerWorktree } }) else {
                throw AgentControlError.unknownAgent
            }
            if request.action == .add {
                return try await add(request, repoIndex: repoIndex, platform: platform)
            }
            let repoPath = platform.state.repos[repoIndex].path
            try await reconcileCompletions(repoIndex: repoIndex, platform: platform)
            guard let repo = platform.state.repos.first(where: { $0.path == repoPath }) else { throw AgentControlError.unknownAgent }
            if request.action == .list {
                return .agents(repo.worktrees.flatMap { worktree in
                    worktree.agents.filter { agent in
                        (request.parent == nil || agent.parent?.agentID == request.parent)
                            && (request.status == nil || agent.status == request.status)
                            && (request.agentID == nil || agent.id == request.agentID)
                    }.map { AgentControlRecord(worktree: worktree.path, agent: $0, operationID: $0.launchOperationID) }
                })
            }
            guard let worktreeIndex = repo.worktrees.firstIndex(where: { worktree in
                worktree.agents.contains { $0.id == request.agentID }
            }), let agentIndex = repo.worktrees[worktreeIndex].agents.firstIndex(where: { $0.id == request.agentID }) else {
                throw AgentControlError.unknownAgent
            }
            let path = repo.worktrees[worktreeIndex].path
            var agent = repo.worktrees[worktreeIndex].agents[agentIndex]
            if [.close, .resume].contains(request.action), let caller = request.callerAgentID,
               agent.parent?.agentID != caller || agent.parent?.worktree != request.callerWorktree {
                throw AgentControlError.parentRequired
            }
            switch request.action {
            case .finish:
                guard path == request.callerWorktree, let session = request.paneSessionName,
                      let slot = repo.worktrees[worktreeIndex].paneSlot(forSessionName: session),
                      slot == agent.paneSlotID else { throw AgentControlError.owningSessionRequired }
                guard let assignment = request.assignmentID, let result = request.result else { throw AgentControlError.invalidRequest }
                try agent.finish(assignment: assignment, result: result)
                try save(agent, path: path, platform: platform)
                if let currentIndex = platform.state.repos.firstIndex(where: { $0.path == repoPath }) {
                    try await reconcileCompletions(repoIndex: currentIndex, platform: platform)
                }
            case .close:
                guard !repo.worktrees.flatMap(\.agents).contains(where: {
                    ($0.parentManagedAgentID == agent.id || $0.parent?.agentID == agent.nativeAgentID) && $0.parent != nil && $0.status != .closed
                }) else { throw AgentControlError.activeChildren }
                guard let completion = request.completionID else { throw AgentControlError.invalidRequest }
                try agent.beginClose(completion: completion)
                if agent.status != .closed {
                    try save(agent, path: path, platform: platform)
                    do {
                        if let slot = agent.paneSlotID { try await platform.closeAgentSession(worktree: path, slot: slot) }
                        agent.transcript = platform.state.worktree(forPath: path)?.agents.first(where: { $0.id == agent.id })?.transcript
                        agent.didClose()
                    } catch {
                        agent.transcript = platform.state.worktree(forPath: path)?.agents.first(where: { $0.id == agent.id })?.transcript
                        agent.closeFailed(reason: error.localizedDescription)
                        try save(agent, path: path, platform: platform)
                        throw error
                    }
                    try save(agent, path: path, platform: platform)
                }
            case .resume:
                try agent.resume()
                try save(agent, path: path, platform: platform)
            case .add, .list, .capability: break
            }
            guard let current = platform.state.worktree(forPath: path)?.agents.first(where: { $0.id == agent.id }) else {
                throw AgentControlError.unknownAgent
            }
            return .agents([AgentControlRecord(worktree: path, agent: current)])
        } catch { return .error(error.localizedDescription) }
    }

    private static func add(_ request: AgentControlRequest, repoIndex: Int, platform: any ControlPlatform) async throws -> ResponseMessage {
        guard let name = request.name, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AgentControlError.invalidRequest
        }
        if let error = WorktreeAgentLaunchCommand.validationError(prompt: request.prompt) { return .error(error) }
        let repoPath = platform.state.repos[repoIndex].path
        if let caller = request.callerAgentID, let provider = TeamAgentIdentity(rawValue: caller)?.runtime,
           request.paneSessionName != nil {
            _ = try await sessionContext(path: request.callerWorktree, agentID: caller,
                paneSessionName: request.paneSessionName, provider: provider, platform: platform)
        }
        guard let repoIndex = platform.state.repos.firstIndex(where: { $0.path == repoPath }) else { throw AgentControlError.unknownAgent }
        let repo = platform.state.repos[repoIndex]
        if let operation = request.operationID,
           let worktree = repo.worktrees.first(where: { $0.agents.contains { $0.launchOperationID == operation } }),
           let agent = worktree.agents.first(where: { $0.launchOperationID == operation }) {
            return .agents([.init(worktree: worktree.path, agent: agent, operationID: operation)])
        }
        AgentPreference.migrate()
        let provider = try AgentPreference.resolve(explicit: request.provider, configured: AgentPreference.provider())
        let parent = request.callerAgentID.map {
            TeamInboxEndpoint(member: repo.worktrees.first(where: { $0.path == request.callerWorktree })?.branch ?? "",
                worktree: request.callerWorktree, runtime: TeamAgentIdentity(rawValue: $0)?.runtime.rawValue, agentID: $0)
        }
        var agent = ManagedAgent(name: name, provider: provider, parent: parent, status: .starting)
        agent.initialPrompt = request.prompt
        agent.launchOperationID = request.operationID ?? UUID().uuidString.lowercased()
        agent.parentManagedAgentID = repo.worktrees.first(where: { $0.path == request.callerWorktree })?.agents.first(where: {
            $0.nativeAgentID == request.callerAgentID && request.callerAgentID != nil
        })?.id
        if let target = request.worktree {
            guard let index = platform.state.indices(forWorktreePath: target), index.repo == repoIndex,
                  let state = platform.state.worktree(forPath: target)?.state, [.running, .closed].contains(state) else {
                return .error("The selected worktree is unavailable or does not belong to this project.")
            }
            guard platform.controlCapabilities.contains(.paneAgent) else { throw AgentControlError.unavailable }
            platform.state.repos[index.repo].worktrees[index.worktree].ensureWorkspaceLayout()
            platform.state.repos[index.repo].worktrees[index.worktree].agents.append(agent)
            do { try platform.worktreeCreation.saveStateNow() }
            catch {
                platform.state.repos[index.repo].worktrees[index.worktree].agents.removeAll { $0.id == agent.id }
                throw error
            }
            let response = await platform.handlePlatformRequest(.addPane(.init(path: target, direction: .right, command: nil,
                agentRuntime: provider, agentPrompt: agent.launchPrompt(request.prompt), managedAgent: agent)))
            guard response == .ok else {
                agent.launchFailed(reason: { if case .error(let reason) = response { return reason }; return "Agent launch failed." }())
                try save(agent, path: target, platform: platform)
                return response ?? .error("Agent launch failed.")
            }
            let current = platform.state.worktree(forPath: target)?.agents.first(where: { $0.id == agent.id }) ?? agent
            return .agents([.init(worktree: target, agent: current, operationID: agent.launchOperationID)])
        }
        let names = WorktreeRequestNames.resolve(name: name, branch: nil, existing: false)
        let response = await CLIWorktreeCreationRequestHandler.begin(.init(callerWorktree: request.callerWorktree,
            worktreeName: names.worktree, branchName: names.branch, existing: false, base: request.base, command: nil,
            agentRuntime: provider, agentPrompt: agent.launchPrompt(request.prompt), operationID: agent.launchOperationID,
            managedAgent: agent), platform: platform.worktreeCreation)
        guard case .worktreeCreate(let status) = response else { return response }
        return .agents([.init(worktree: status.worktreePath, agent: agent, operationID: status.operationID)])
    }

    private static func save(_ agent: ManagedAgent, path: String, platform: any ControlPlatform) throws {
        guard let index = platform.state.indices(forWorktreePath: path),
              let agentIndex = platform.state.repos[index.repo].worktrees[index.worktree].agents.firstIndex(where: { $0.id == agent.id }) else {
            throw AgentControlError.unknownAgent
        }
        let previous = platform.state.repos[index.repo].worktrees[index.worktree].agents[agentIndex]
        platform.state.repos[index.repo].worktrees[index.worktree].agents[agentIndex] = agent
        do { try platform.worktreeCreation.saveStateNow() }
        catch {
            platform.state.repos[index.repo].worktrees[index.worktree].agents[agentIndex] = previous
            throw error
        }
    }

    /// The saved completion is the outbox. Inbox delivery never clears cleanup state.
    public static func reconcileCompletions(repoIndex: Int, platform: any ControlPlatform) async throws {
        let repo = platform.state.repos[repoIndex]
        for worktree in repo.worktrees {
            for var agent in worktree.agents {
                guard let completion = agent.completion, let parent = agent.parent,
                      agent.deliveredCompletionID != completion.id else { continue }
                let key = completion.id.uuidString
                let inbox = platform.teamInbox
                let completedAgent = agent
                _ = try await OffMainIO.run {
                    try inbox.appendAgentCompletion(teamID: repo.path, teamName: repo.displayName,
                        to: parent, completionID: completion.id,
                        body: """
                        Agent \(completedAgent.name) (\(completedAgent.id)) finished assignment \(completion.assignmentID.uuidString).

                        \(completion.result)

                        Handle this result, then clean up its terminal with:
                        graftty agent close \(completedAgent.id) --completion \(key)
                        Reading this message does not acknowledge cleanup. Recover pending work with graftty agent list --parent \(parent.agentID ?? "") --status awaiting-cleanup --json.
                        """)
                }
                guard let current = platform.state.worktree(forPath: worktree.path)?.agents.first(where: { $0.id == agent.id }),
                      current.completion?.id == completion.id else { continue }
                agent = current
                agent.deliveredCompletionID = completion.id
                try save(agent, path: worktree.path, platform: platform)
            }
        }
    }
}
