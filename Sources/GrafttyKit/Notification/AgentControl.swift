import Foundation
import GrafttyProtocol

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
    // Persisted `closing` remains retryable after restart; only this process's
    // active effects suppress overlapping teardown of the same stable agent.
    private static var closingAgents: Set<String> = []
    private static var outboxDrains: Set<String> = []
    private struct DetailSnapshot {
        let repo: String
        let agentID: String
        let file: URL
        let byteCount: Int
        var accessed: Date
    }
    private static var detailSnapshots: [UUID: DetailSnapshot] = [:]

    /// Older live providers may not send SessionStart again after an app update.
    /// Recover their identity once, using hooks rather than guessing from titles.
    public static func recoverObservedSession(path: String, agentID: String?, paneSessionName: String?,
                                               provider: TeamHookRuntime, platform: any ControlPlatform) async throws {
        guard let agentID, let session = paneSessionName else { return }
        func needsObservation() -> Bool {
            guard let worktree = platform.state.worktree(forPath: path),
                  let slot = worktree.paneSlot(forSessionName: session) else { return false }
            return !worktree.agents.contains { $0.paneSlotID == slot && $0.status != .closed }
        }
        guard needsObservation() else { return }
        let presence = platform.teamPresence
        let records = try await OffMainIO.run { try presence.listAll() }
        guard needsObservation(), !records.contains(where: {
            $0.isSubagent == true && TeamAgentDirectory.identity(for: $0).rawValue == agentID
        }) else { return }
        _ = try await sessionContext(path: path, agentID: agentID, paneSessionName: session,
            provider: provider, platform: platform)
    }

    public static func sessionContext(path: String, agentID: String?, paneSessionName: String?,
                                      provider: TeamHookRuntime, isSubagent: Bool = false, platform: any ControlPlatform) async throws -> String {
        guard !isSubagent else { return "" }
        guard let index = platform.state.indices(forWorktreePath: path) else { return "" }
        var worktree = platform.state.repos[index.repo].worktrees[index.worktree]
        // A provider started manually in an existing shell gains identity without
        // moving its saved view. Native subagents were excluded above.
        if let agentID, let session = paneSessionName, let slot = worktree.paneSlot(forSessionName: session),
           !worktree.agents.contains(where: { $0.paneSlotID == slot && $0.status != .closed }) {
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
           var agent = worktree.agents.first(where: { $0.paneSlotID == slot && $0.status != .closed }) {
            guard agent.provider == provider else { return "" }
            agent.paneSlotID = slot
            if agent.nativeAgentID != agentID { agent.nativeBindingDate = Date() }
            agent.nativeAgentID = agentID
            agent.observeWaiting(false)
            try save(agent, path: path, platform: platform)
            try repairParentEndpoints(repoPath: platform.state.repos[index.repo].path, platform: platform)
            if let prompt = agent.initialPrompt, !prompt.isEmpty {
                sections.append("Saved initial assignment, for recovery only. If this is already in your launch context or completed, do not repeat it:\n" + prompt)
            }
            sections.append("Managed agent \(agent.id), assignment \(agent.assignmentID.uuidString). Finish the assignment with graftty agent finish \(agent.id) --assignment \(agent.assignmentID.uuidString) --result-stdin. A turn ending is not assignment completion.")
        }
        await reconcileOutbox(platform: platform)
        if let agentID {
            let pending = (platform.state.repo(forWorktreePath: path)?.worktrees.flatMap(\.agents) ?? []).filter {
                $0.parent?.agentID == agentID && $0.requiresAcknowledgment
            }
            for child in pending {
                guard let completion = child.completion else { continue }
                sections.append("Cleanup pending for \(child.name) (\(child.id)): \(AgentTextPreview.prefix(completion.result, bytes: 4096))\nRead the full result with graftty agent show \(child.id) --json. Handle the result, then run graftty agent close \(child.id) --completion \(completion.id.uuidString).")
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
            try? repairParentEndpoints(repoPath: repoPath, platform: platform)
            Task { await reconcileOutbox(platform: platform) }
            guard let repo = platform.state.repos.first(where: { $0.path == repoPath }) else { throw AgentControlError.unknownAgent }
            if request.action == .list {
                let all = repo.worktrees.flatMap { worktree in
                    worktree.agents.filter { agent in
                        (request.parent == nil || agent.parent?.agentID == request.parent || agent.parentManagedAgentID == request.parent)
                            && (request.status == nil || agent.status == request.status)
                            && (request.agentID == nil || agent.id == request.agentID)
                    }.map { (worktree.path, $0) }
                }
                let offset = max(0, request.offset ?? 0)
                let limit = min(200, max(1, request.limit ?? 100))
                var rows = all.dropFirst(offset).prefix(limit).map { path, agent in
                    AgentControlRecord(worktree: path, agent: agent.summary(), operationID: agent.launchOperationID)
                }
                if offset + rows.count < all.count, !rows.isEmpty { rows[rows.count - 1].nextOffset = offset + rows.count }
                return .agents(rows)
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
            case .show:
                expireDetailSnapshots()
                let token: UUID
                let snapshot: DetailSnapshot
                if let retained = request.detailToken {
                    guard let saved = detailSnapshots[retained], saved.repo == repo.path,
                          saved.agentID == agent.id else { return .error("Detail snapshot expired. Run agent show again.") }
                    token = retained
                    snapshot = saved
                    detailSnapshots[retained]?.accessed = Date()
                } else {
                    guard (request.offset ?? 0) == 0 else { throw AgentControlError.invalidRequest }
                    if detailSnapshots.count >= 4, let oldest = detailSnapshots.min(by: { $0.value.accessed < $1.value.accessed })?.key {
                        removeDetailSnapshot(oldest)
                    }
                    token = UUID()
                    let archives = platform.agentArchives
                    let retainedAgent = agent
                    let file = archives.directory.appendingPathComponent("details", isDirectory: true)
                        .appendingPathComponent(token.uuidString + ".json")
                    let count = try await OffMainIO.run {
                        var full = retainedAgent
                        if full.transcript == nil, let reference = full.transcriptArchive {
                            full.transcript = try archives.read(reference)
                        }
                        let encoder = JSONEncoder()
                        encoder.outputFormatting = [.sortedKeys]
                        let data = try encoder.encode(full)
                        try AttentionFileHandoff(rootDirectory: file.deletingLastPathComponent()).ensureDirectory()
                        try data.write(to: file, options: .atomic)
                        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
                        return data.count
                    }
                    snapshot = .init(repo: repo.path, agentID: agent.id, file: file, byteCount: count, accessed: Date())
                    if detailSnapshots.count >= 4, let oldest = detailSnapshots.min(by: { $0.value.accessed < $1.value.accessed })?.key {
                        removeDetailSnapshot(oldest)
                    }
                    detailSnapshots[token] = snapshot
                }
                let offset = min(snapshot.byteCount, max(0, request.offset ?? 0))
                let end = offset + min(64 * 1024, snapshot.byteCount - offset)
                let chunk = try await OffMainIO.run {
                    let handle = try FileHandle(forReadingFrom: snapshot.file)
                    defer { try? handle.close() }
                    try handle.seek(toOffset: UInt64(offset))
                    return try handle.read(upToCount: end - offset) ?? Data()
                }
                guard chunk.count == end - offset else { throw CocoaError(.fileReadCorruptFile) }
                if end == snapshot.byteCount { removeDetailSnapshot(token) }
                return .agents([.init(worktree: path, agent: agent.summary(), operationID: agent.launchOperationID,
                    detail: chunk, nextOffset: end < snapshot.byteCount ? end : nil, detailToken: token)])
            case .finish:
                guard path == request.callerWorktree, let session = request.paneSessionName,
                      let slot = repo.worktrees[worktreeIndex].paneSlot(forSessionName: session),
                      slot == agent.paneSlotID else { throw AgentControlError.owningSessionRequired }
                guard let assignment = request.assignmentID, let result = request.result else { throw AgentControlError.invalidRequest }
                try agent.finish(assignment: assignment, result: result)
                try save(agent, path: path, platform: platform)
                if let index = platform.state.repos.firstIndex(where: { $0.path == repoPath }) {
                    try? await reconcileCompletions(repoIndex: index, agentID: agent.id, platform: platform)
                }
            case .close:
                guard closingAgents.insert(agent.id).inserted else {
                    return .error("Cleanup is already in progress. Retry with the same completion ID.")
                }
                defer { closingAgents.remove(agent.id) }
                guard !hasOpenChildren(of: agent, in: repo) else { throw AgentControlError.activeChildren }
                guard let completion = request.completionID else { throw AgentControlError.invalidRequest }
                try agent.beginClose(completion: completion)
                if agent.status != .closed {
                    try save(agent, path: path, platform: platform)
                    do {
                        if let slot = agent.paneSlotID { try await platform.closeAgentSession(worktree: path, slot: slot) }
                        agent = platform.state.worktree(forPath: path)?.agents.first(where: { $0.id == agent.id }) ?? agent
                        agent.didClose()
                    } catch {
                        agent = platform.state.worktree(forPath: path)?.agents.first(where: { $0.id == agent.id }) ?? agent
                        agent.closeFailed(reason: error.localizedDescription)
                        try save(agent, path: path, platform: platform)
                        throw error
                    }
                    try save(agent, path: path, platform: platform)
                }
            case .resume:
                guard !closingAgents.contains(agent.id) else { throw ManagedAgent.LifecycleError.invalidState }
                await consumeExitEvents(agentID: agent.id, platform: platform)
                agent = platform.state.worktree(forPath: path)?.agents.first(where: { $0.id == agent.id }) ?? agent
                let expectedCompletion = agent.completion?.id
                if let slot = agent.paneSlotID {
                    guard try await platform.agentSessionIsAlive(worktree: path, slot: slot) else {
                        throw ManagedAgent.LifecycleError.invalidState
                    }
                } else { throw ManagedAgent.LifecycleError.invalidState }
                guard !closingAgents.contains(agent.id),
                      let latest = platform.state.worktree(forPath: path)?.agents.first(where: { $0.id == agent.id }),
                      latest.completion?.id == expectedCompletion else { throw ManagedAgent.LifecycleError.invalidState }
                agent = latest
                try agent.resume()
                try save(agent, path: path, platform: platform)
            case .add, .list, .capability: break
            }
            guard let current = platform.state.worktree(forPath: path)?.agents.first(where: { $0.id == agent.id }) else {
                throw AgentControlError.unknownAgent
            }
            return .agents([AgentControlRecord(worktree: path, agent: current.summary())])
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
            return .agents([.init(worktree: agent.launchTargetWorktree ?? worktree.path, agent: agent.summary(), operationID: operation)])
        }
        AgentPreference.migrate()
        let provider = try AgentPreference.resolve(explicit: request.provider, configured: AgentPreference.provider())
        let callerTree = repo.worktrees.first { $0.path == request.callerWorktree }
        let callerSlot = request.paneSessionName.flatMap { callerTree?.paneSlot(forSessionName: $0) }
        let owner = callerTree?.agents.first {
            $0.status != .closed && $0.nativeAgentID == request.callerAgentID && request.callerAgentID != nil
                && (callerSlot == nil || $0.paneSlotID == callerSlot)
        }
        if let owner, [.closing, .interrupted, .failed].contains(owner.status) {
            throw ManagedAgent.LifecycleError.invalidState
        }
        let parent = request.callerAgentID.map {
            TeamInboxEndpoint(member: repo.worktrees.first(where: { $0.path == request.callerWorktree })?.branch ?? "",
                worktree: request.callerWorktree, runtime: TeamAgentIdentity(rawValue: $0)?.runtime.rawValue, agentID: $0)
        }
        var agent = ManagedAgent(name: name, provider: provider, parent: parent, status: .starting)
        agent.paneSlotID = PaneSlotID()
        agent.paneSessionID = PaneSessionID()
        agent.initialPrompt = request.prompt
        agent.launchOperationID = request.operationID ?? UUID().uuidString.lowercased()
        agent.parentManagedAgentID = owner?.id
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
                agentRuntime: provider, agentPrompt: request.prompt, managedAgent: agent)))
            guard response == .ok else {
                agent = platform.state.worktree(forPath: target)?.agents.first(where: { $0.id == agent.id }) ?? agent
                let reason = { if case .error(let reason) = response { return reason }; return "Agent launch failed." }()
                agent.launchFailed(reason: reason)
                agent.recordFailure(reason)
                if let slot = agent.paneSlotID, platform.state.worktree(forPath: target)?.paneSessions[slot] == nil {
                    agent.paneSlotID = nil
                }
                try save(agent, path: target, platform: platform)
                return response ?? .error("Agent launch failed.")
            }
            let current = platform.state.worktree(forPath: target)?.agents.first(where: { $0.id == agent.id }) ?? agent
            return .agents([.init(worktree: target, agent: current.summary(), operationID: agent.launchOperationID)])
        }
        let names = WorktreeRequestNames.resolve(name: name, branch: request.branch, existing: request.existing ?? false)
        if let error = WorktreeCreationInput.validationError(worktreeName: names.worktree, branchName: names.branch,
            existing: request.existing ?? false, base: request.base) { return .error(error) }
        agent.launchTargetWorktree = AppState.linkedWorktreePath(repoPath: repo.path, worktreeName: names.worktree)
        // Reserve the child before ref resolution can suspend. Parent cleanup
        // must see this obligation even while the destination is being prepared.
        guard let callerIndex = platform.state.indices(forWorktreePath: request.callerWorktree) else { throw AgentControlError.unknownAgent }
        platform.state.repos[callerIndex.repo].worktrees[callerIndex.worktree].agents.append(agent)
        do { try platform.worktreeCreation.saveStateNow() }
        catch {
            platform.state.repos[callerIndex.repo].worktrees[callerIndex.worktree].agents.removeAll { $0.id == agent.id }
            throw error
        }
        let response = await CLIWorktreeCreationRequestHandler.begin(.init(callerWorktree: request.callerWorktree,
            worktreeName: names.worktree, branchName: names.branch, existing: request.existing ?? false, base: request.base, command: nil,
            agentRuntime: provider, agentPrompt: request.prompt, operationID: agent.launchOperationID,
            managedAgent: agent), platform: platform.worktreeCreation)
        guard case .worktreeCreate(let status) = response else {
            if let path = platform.state.repos.flatMap(\.worktrees).first(where: { $0.agents.contains { $0.id == agent.id } })?.path {
                agent.paneSlotID = nil
                agent.launchFailed(reason: { if case .error(let reason) = response { return reason }; return "Agent creation failed" }())
                try save(agent, path: path, platform: platform)
            }
            return response
        }
        guard let persisted = platform.state.repos.first(where: { $0.path == repo.path })?.worktrees
            .flatMap(\.agents).first(where: { $0.launchOperationID == status.operationID }) else {
            throw AgentControlError.unknownAgent
        }
        return .agents([.init(worktree: status.worktreePath, agent: persisted.summary(), operationID: status.operationID)])
    }

    /// Called only for confirmed session destruction, not renderer eviction or disconnect.
    public static func sessionEnded(path: String, slot: PaneSlotID, reason: String,
                                    platform: any ControlPlatform) throws {
        guard var agent = platform.state.worktree(forPath: path)?.agents.first(where: {
            $0.paneSlotID == slot && $0.status != .closed
        }) else { return }
        agent.sessionEnded(reason: reason)
        agent.paneSlotID = nil
        try save(agent, path: path, platform: platform)
    }

    /// Ordinary destructive close retains an interrupted result for parent acknowledgment.
    public static func interruptSession(path: String, slot: PaneSlotID, platform: any ControlPlatform) async throws {
        guard var agent = platform.state.worktree(forPath: path)?.agents.first(where: { $0.paneSlotID == slot && $0.status != .closed }) else { return }
        guard closingAgents.insert(agent.id).inserted else { return }
        defer { closingAgents.remove(agent.id) }
        if let repo = platform.state.repo(forWorktreePath: path), hasOpenChildren(of: agent, in: repo) {
            agent.recordFailure(AgentControlError.activeChildren.localizedDescription)
            try save(agent, path: path, platform: platform)
            throw AgentControlError.activeChildren
        }
        agent.requestSessionClose(reason: "Terminal closure requested before assignment completion.")
        try save(agent, path: path, platform: platform)
        do { try await platform.closeAgentSession(worktree: path, slot: slot) }
        catch {
            agent = platform.state.worktree(forPath: path)?.agents.first(where: { $0.id == agent.id }) ?? agent
            agent.recordFailure(error.localizedDescription)
            try save(agent, path: path, platform: platform)
            throw error
        }
        try sessionEnded(path: path, slot: slot, reason: "Terminal closed", platform: platform)
        await reconcileOutbox(platform: platform)
    }

    private static func repairParentEndpoints(repoPath: String, platform: any ControlPlatform) throws {
        guard let repo = platform.state.repos.first(where: { $0.path == repoPath }) else { return }
        for worktree in repo.worktrees {
            for var child in worktree.agents {
                guard let parentID = child.parentManagedAgentID,
                      let ownerTree = repo.worktrees.first(where: { $0.agents.contains { $0.id == parentID } }),
                      let owner = ownerTree.agents.first(where: { $0.id == parentID }),
                      let native = owner.nativeAgentID, let old = child.parent else { continue }
                let endpoint = TeamInboxEndpoint(member: old.member, worktree: ownerTree.path,
                    runtime: owner.provider.rawValue, agentID: native)
                if child.parent != endpoint {
                    child.parent = endpoint
                    child.deliveredCompletionID = nil
                    try save(child, path: worktree.path, platform: platform)
                }
            }
        }
    }

    private static func hasOpenChildren(of parent: ManagedAgent, in repo: RepoEntry) -> Bool {
        repo.worktrees.flatMap(\.agents).contains { child in
            guard child.parent != nil, child.status != .closed else { return false }
            if let stableParent = child.parentManagedAgentID { return stableParent == parent.id }
            return parent.nativeAgentID != nil && child.parent?.agentID == parent.nativeAgentID
        }
    }

    /// Invoked by host restore and periodic delivery maintenance, even without a CLI request.
    public static func reconcileOutbox(platform: any ControlPlatform) async {
        expireDetailSnapshots()
        let identity = platform.teamInbox.rootDirectory.path
        guard outboxDrains.insert(identity).inserted else { return }
        defer { outboxDrains.remove(identity) }
        let archives = platform.agentArchives
        let activeFiles = Set(detailSnapshots.values.map(\.file))
        try? await OffMainIO.run { try archives.removeExpiredDetails(excluding: activeFiles) }
        try? await migrateTranscripts(platform: platform)
        await consumeExitEvents(platform: platform)
        for path in platform.state.repos.map(\.path) {
            do { try repairParentEndpoints(repoPath: path, platform: platform) } catch { continue }
            guard let index = platform.state.repos.firstIndex(where: { $0.path == path }) else { continue }
            try? await reconcileCompletions(repoIndex: index, platform: platform)
        }
        await refreshProcessObservations(platform: platform)
    }

    private static func consumeExitEvents(agentID: String? = nil, platform: any ControlPlatform) async {
        let handoff = AgentLifecycleHandoff(directory: platform.worktreeCreation.agentPromptDirectory.appendingPathComponent("lifecycle"))
        for (file, event) in (try? await OffMainIO.run { try handoff.pending() }) ?? [] {
            guard agentID == nil || agentID == event.agentID else { continue }
            do {
                guard try apply(event, platform: platform) else { continue }
                try await OffMainIO.run { try FileManager.default.removeItem(at: file) }
            } catch { /* The durable file remains for the next retry. */ }
        }
    }

    private static func refreshProcessObservations(platform: any ControlPlatform) async {
        guard let live = try? await platform.agentSessionNames() else { return }
        let presence = platform.teamPresence
        let reachable = await OffMainIO.run {
            Set(((try? presence.listAll()) ?? []).filter {
                $0.isSubagent != true && TeamAgentReachability.isReachable($0)
            }.map { TeamAgentDirectory.identity(for: $0).rawValue })
        }
        for worktree in platform.state.repos.flatMap(\.worktrees) {
            for candidate in worktree.agents {
                // Earlier teardown may suspend while this assignment changes.
                guard let current = platform.state.worktree(forPath: worktree.path),
                      var agent = current.agents.first(where: { $0.id == candidate.id }),
                      agent.status != .closed, agent.status != .starting,
                      !closingAgents.contains(agent.id), let slot = agent.paneSlotID,
                      let session = current.paneSessions[slot] else { continue }
                if !live.contains(ZmxLauncher.sessionName(for: session)) {
                    do {
                        guard try await !platform.agentSessionIsAlive(worktree: worktree.path, slot: slot),
                              !closingAgents.contains(agent.id),
                              platform.state.worktree(forPath: worktree.path)?.agents.contains(where: {
                                  $0.id == agent.id && $0.paneSlotID == slot && $0.status != .closed
                              }) == true else { continue }
                        try await platform.closeAgentSession(worktree: worktree.path, slot: slot)
                        try sessionEnded(path: worktree.path, slot: slot, reason: "Terminal process exited", platform: platform)
                    } catch { /* Inventory/teardown failure is retried on the next maintenance pass. */ }
                } else if agent.processObservation != .exited, let native = agent.nativeAgentID {
                    let observation: AgentProcessObservation = reachable.contains(native) ? .reachable : .disconnected
                    if agent.processObservation != observation {
                        agent.processObservation = observation
                        try? save(agent, path: worktree.path, platform: platform)
                    }
                }
            }
        }
    }

    /// Unknown agents may belong to another owner or await state recovery; retain their event files.
    private static func apply(_ event: AgentLifecycleEvent, platform: any ControlPlatform) throws -> Bool {
        guard let worktree = platform.state.repos.flatMap(\.worktrees).first(where: {
            $0.agents.contains { $0.id == event.agentID }
        }), var agent = worktree.agents.first(where: { $0.id == event.agentID }) else { return false }
        guard (agent.launchAssignmentID ?? agent.assignmentID) == event.assignmentID,
              agent.paneSessionID == event.sessionID, agent.status != .closed else { return true }
        if let exited = event.recordedAt, let replacementStarted = agent.nativeBindingDate,
           exited < replacementStarted { return true }
        agent.sessionEnded(reason: "\(agent.provider.displayName) exited with status \(event.exitCode).",
                           failedLaunch: event.exitCode == 126 || event.exitCode == 127 || agent.status == .starting)
        try save(agent, path: worktree.path, platform: platform)
        return true
    }

    /// Legacy inline archives migrate once; failed writes or state saves retain the original bytes.
    public static func migrateTranscripts(platform: any ControlPlatform) async throws {
        let pending = platform.state.repos.flatMap(\.worktrees).flatMap { worktree in
            worktree.agents.compactMap { agent -> (String, String, String)? in
                agent.transcript.map { (worktree.path, agent.id, $0) }
            }
        }
        guard !pending.isEmpty else { return }
        let archives = platform.agentArchives
        let archived = try await OffMainIO.run {
            try pending.map { (path, id, transcript) in
                (path, id, transcript, try archives.write(transcript))
            }
        }
        // Re-read after I/O: provider hooks and unrelated assignments may have changed meanwhile.
        let previous = platform.state
        var changed = false
        for (path, id, transcript, reference) in archived {
            guard let index = platform.state.indices(forWorktreePath: path),
                  let ai = platform.state.repos[index.repo].worktrees[index.worktree].agents.firstIndex(where: { $0.id == id }),
                  platform.state.repos[index.repo].worktrees[index.worktree].agents[ai].transcript == transcript else { continue }
            platform.state.repos[index.repo].worktrees[index.worktree].agents[ai].transcriptArchive = reference
            platform.state.repos[index.repo].worktrees[index.worktree].agents[ai].transcript = nil
            changed = true
        }
        guard changed else { return }
        do { try platform.worktreeCreation.saveStateNow() }
        catch { platform.state = previous; throw error }
    }

    public static func archiveTranscript(_ transcript: String, path: String, slot: PaneSlotID,
                                         session: PaneSessionID, platform: any ControlPlatform) async throws {
        let archives = platform.agentArchives
        let reference = try await OffMainIO.run { try archives.write(transcript) }
        guard let worktree = platform.state.worktree(forPath: path), worktree.paneSessions[slot] == session,
              var agent = worktree.agents.first(where: { $0.paneSlotID == slot }) else { return }
        agent.transcriptArchive = reference
        agent.transcript = nil
        try save(agent, path: path, platform: platform)
    }

    private static func removeDetailSnapshot(_ token: UUID) {
        guard let snapshot = detailSnapshots.removeValue(forKey: token) else { return }
        try? FileManager.default.removeItem(at: snapshot.file)
    }

    private static func expireDetailSnapshots() {
        for (token, snapshot) in detailSnapshots where Date().timeIntervalSince(snapshot.accessed) >= 60 {
            removeDetailSnapshot(token)
        }
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
    public static func reconcileCompletions(repoIndex: Int, agentID: String? = nil, platform: any ControlPlatform) async throws {
        let repo = platform.state.repos[repoIndex]
        for worktree in repo.worktrees {
            for var agent in worktree.agents {
                guard agentID == nil || agentID == agent.id else { continue }
                guard let completion = agent.completion, let parent = agent.parent,
                      agent.deliveredCompletionID != completion.id else { continue }
                let key = completion.id.uuidString
                let completedAgent = agent
                do {
                    try await platform.appendAgentCompletion(repo: repo, parent: parent, completionID: completion.id,
                        body: """
                        Agent \(completedAgent.name) (\(completedAgent.id)) reported \(completion.outcome?.rawValue ?? "completed") for assignment \(completion.assignmentID.uuidString).

                        \(AgentTextPreview.prefix(completion.result, bytes: 4096))
                        Full result/history: graftty agent show \(completedAgent.id) --json

                        Handle this result, then clean up its terminal with:
                        graftty agent close \(completedAgent.id) --completion \(key)
                        Reading this message does not acknowledge cleanup. Recover pending work with graftty agent list --parent \(parent.agentID ?? "") --json.
                        """)
                    guard let current = platform.state.worktree(forPath: worktree.path)?.agents.first(where: { $0.id == agent.id }),
                          current.completion?.id == completion.id, current.parent == parent else { continue }
                    agent = current
                    agent.deliveredCompletionID = completion.id
                    agent.deliveryFailure = nil
                    try save(agent, path: worktree.path, platform: platform)
                } catch {
                    if var current = platform.state.worktree(forPath: worktree.path)?.agents.first(where: { $0.id == agent.id }) {
                        current.deliveryFailure = error.localizedDescription
                        try? save(current, path: worktree.path, platform: platform)
                    }
                }
            }
        }
    }
}
