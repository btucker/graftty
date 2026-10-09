import Foundation
import GrafttyProtocol

@MainActor
final class HostMaintenance: WorktreeMonitorDelegate {
    weak var runtime: HeadlessHostRuntime?
    let monitor = WorktreeMonitor()
    var task: Task<Void, Never>?
    var dirty: Set<String> = []
    init(runtime: HeadlessHostRuntime) { self.runtime = runtime; monitor.delegate = self }
    func start() {
        guard let runtime else { return }
        for repo in runtime.state.repos { monitor.installRepoWatchers(repo: repo); dirty.insert(repo.path) }
        task = Task { [weak self] in
            var iteration = 0
            while !Task.isCancelled {
                guard let self, let runtime = self.runtime else { return }
                try? runtime.consumeAttentionActivities()
                if iteration % 15 == 0 { self.dirty.formUnion(runtime.state.repos.map(\.path)) }
                let paths = self.dirty
                self.dirty.removeAll()
                for path in paths {
                    do {
                        try await runtime.refreshRepository(path)
                        if let repo = runtime.state.repos.first(where: { $0.path == path }) { self.monitor.installRepoWatchers(repo: repo) }
                    } catch { self.dirty.insert(path) }
                }
                iteration += 1
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }
    func stop() { task?.cancel(); task = nil; monitor.stopAll() }
    nonisolated func worktreeMonitorDidDetectChange(_ monitor: WorktreeMonitor, repoPath: String) {
        Task { @MainActor [weak self] in self?.dirty.insert(repoPath) }
    }
    nonisolated func worktreeMonitorDidDetectOriginRefChange(_ monitor: WorktreeMonitor, repoPath: String) {
        Task { @MainActor [weak self] in self?.dirty.insert(repoPath) }
    }
    nonisolated func worktreeMonitorDidDetectDeletion(_ monitor: WorktreeMonitor, worktreePath: String) { markWorktree(worktreePath) }
    nonisolated func worktreeMonitorDidDetectBranchChange(_ monitor: WorktreeMonitor, worktreePath: String) { markWorktree(worktreePath) }
    nonisolated func worktreeMonitorDidDetectContentChange(_ monitor: WorktreeMonitor, worktreePath: String) { markWorktree(worktreePath) }
    private nonisolated func markWorktree(_ path: String) {
        Task { @MainActor [weak self] in
            guard let self, let repo = self.runtime?.state.repo(forWorktreePath: path) else { return }
            self.dirty.insert(repo.path)
        }
    }
}

public extension HeadlessHostRuntime {
    func startMaintenance() {
        guard maintenance == nil else { return }
        let coordinator = HostMaintenance(runtime: self)
        maintenance = coordinator
        coordinator.start()
    }

    func refreshRepository(_ path: String) async throws {
        guard let repo = state.repos.first(where: { $0.path == path }) else { throw HostRuntimeError.notFound("repository is not registered") }
        guard !busyPaths.contains(where: { $0 == path || $0.hasPrefix(path + "/") }), !repo.worktrees.contains(where: { busyPaths.contains($0.path) }) else {
            throw HostRuntimeError.busy("repository operations in progress")
        }
        let generation = operationGeneration
        let discovered = try await GitWorktreeDiscovery.discover(repoPath: path)
        let branches = try await RemoteBranchStore.defaultList(path)
        guard generation == operationGeneration, !busyPaths.contains(where: { $0 == path || $0.hasPrefix(path + "/") }),
              !repo.worktrees.contains(where: { busyPaths.contains($0.path) }) else { throw HostRuntimeError.busy("repository changed during discovery") }
        guard let ri = state.repos.firstIndex(where: { $0.path == path }) else { return }
        // Reconcile against the latest state, preserving pane and attention
        // mutations accepted while the read-only Git scans were suspended.
        state.repos[ri].worktrees = WorktreeReconciler.reconcile(existing: state.repos[ri].worktrees, discovered: discovered).merged
        state.repos[ri].defaultBranchHint = branches.defaultBranch ?? state.repos[ri].defaultBranchHint
        repositoryBranches[path] = branches
        try save()
        let refreshed = state.repos[ri]
        if let defaultBranch = refreshed.defaultBranchHint {
            for worktree in refreshed.worktrees where worktree.state.hasOnDiskWorktree {
                let refs = await GitWorktreeStats.resolveUpstreamRefs(worktreePath: worktree.path, branch: worktree.branch,
                    defaultBranch: defaultBranch, timeout: .seconds(5))
                if let stats = try? await GitWorktreeStats.compute(worktreePath: worktree.path, upstreamRefs: refs, timeout: .seconds(5)) {
                    worktreeStats[worktree.path] = stats.toWire()
                }
            }
        }
    }

    func repositoryInfo() async -> [RemoteRepositoryInfo] {
        for repo in state.repos where repositoryBranches[repo.path] == nil { try? await refreshRepository(repo.path) }
        return state.repos.map { repo in
            let snapshot = repositoryBranches[repo.path] ?? RemoteBranchSnapshot()
            let localNames = Set(snapshot.localBranches.map(\.name))
            let branches = snapshot.localBranches.map { branch in
                RemoteRepositoryInfo.Branch(name: branch.name, source: .local, lastCommitDate: branch.lastCommitDate,
                    mountedWorktreeID: repo.branchMountedPath(branch.name), pullRequest: nil)
            } + snapshot.remoteBranches.filter { !localNames.contains($0.name) }.map { branch in
                RemoteRepositoryInfo.Branch(name: branch.name, source: .remoteOnly, lastCommitDate: branch.lastCommitDate,
                    mountedWorktreeID: repo.branchMountedPath(branch.name), pullRequest: nil)
            }
            return RemoteRepositoryInfo(id: repo.path, displayName: repo.displayName, origin: origin,
                defaultBranchStatus: nil, branches: branches)
        }
    }

    func consumeAttentionActivities(handoff: AttentionFileHandoff = AttentionFileHandoff()) throws {
        try handoff.consumeActivities(acceptingWorktree: { state.worktree(forPath: $0) != nil }) { event in
            switch event {
            case .stop(let stop):
                guard let index = state.indices(forWorktreePath: stop.worktree) else { return }
                let key = AgentHookAttentionIdentity.key(runtime: stop.runtime, sessionID: stop.sessionID, callerAgentID: stop.agentID)
                let slot = stop.paneSessionName.flatMap { state.repos[index.repo].worktrees[index.worktree].paneSlot(forSessionName: $0) }
                state.repos[index.repo].worktrees[index.worktree].recordAgentStop(SidebarAgentStop(agentName: stop.runtime.rawValue,
                    stoppedAt: stop.stoppedAt, recap: stop.recap, paneSlotID: slot?.id.uuidString, providerSessionKey: key))
                SidebarHostNavigation.adoptReportedEmoji(stop.recap, worktreePath: stop.worktree, in: &state.repos)
                if let pane = stop.paneSessionName { busyAgents.remove(pane) }
            case .progress(let progress):
                guard state.worktree(forPath: progress.worktree) != nil else { return }
                let key = AgentHookAttentionIdentity.key(runtime: progress.runtime, sessionID: progress.sessionID, callerAgentID: progress.agentID)
                state.clearAgentStopAttention(worktreePath: progress.worktree, providerSessionKey: key, progressedAt: progress.progressedAt)
            }
            try save()
        }
    }
}
