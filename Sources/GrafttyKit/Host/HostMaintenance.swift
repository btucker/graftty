import Foundation
import GrafttyProtocol

@MainActor
final class HostMaintenance: WorktreeMonitorDelegate {
    weak var runtime: HeadlessHostRuntime?
    let monitor = WorktreeMonitor(watchContents: true)
    var task: Task<Void, Never>?
    var portTask: Task<Void, Never>?
    var resourceTask: Task<Void, Never>?
    var dirty: Set<String> = []
    init(runtime: HeadlessHostRuntime) { self.runtime = runtime; monitor.delegate = self }
    func start() {
        guard let runtime else { return }
        for repo in runtime.state.repos { monitor.installRepoWatchers(repo: repo); dirty.insert(repo.path) }
        resourceTask = Task { [weak self] in
            let sampler = HostResourceSampler()
            while !Task.isCancelled {
                guard let runtime = self?.runtime else { return }
                let active = runtime.state.repos.flatMap(\.worktrees).filter { $0.state == .running }.count
                var sample = await sampler.sample(diskPath: runtime.configuration.stateDirectory.path,
                    activeWorktrees: active, pendingOperations: runtime.busyPaths.count)
                guard !Task.isCancelled else { return }
                sample.pendingPlacements = runtime.placements.pendingCount
                sample.acceptingPlacements = runtime.drain == nil
                runtime.hostResources = sample
                try? await Task.sleep(for: .seconds(5))
            }
        }
        portTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let runtime = self?.runtime else { return }
                await runtime.refreshPortBindings()
                try? await Task.sleep(for: .seconds(2))
            }
        }
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
    func stop() { resourceTask?.cancel(); resourceTask = nil; runtime?.hostResources = nil; task?.cancel(); task = nil; portTask?.cancel(); portTask = nil; monitor.stopAll() }
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
            case .recap(let report):
                state.recordAgentRecap(report.recap, callerPath: report.worktree, reportedAt: report.reportedAt)
            case .response(let response):
                guard let index = state.indices(forWorktreePath: response.worktree) else { return }
                state.repos[index.repo].worktrees[index.worktree].recordAgentResponse(response.response)
            case .stop(let stop):
                guard state.worktree(forPath: stop.worktree) != nil else { return }
                ControlRequestCore.recordHookLiveness(callerPath: stop.worktree, runtime: stop.runtime, event: .stop,
                    sessionID: stop.sessionID ?? stop.agentID, paneSessionName: stop.paneSessionName,
                    attentionReason: nil, platform: controlPlatform)
                ControlRequestCore.recordStoppedTurn(callerPath: stop.worktree, runtime: stop.runtime,
                    callerAgentID: stop.agentID, sessionID: stop.sessionID, paneSessionName: stop.paneSessionName,
                    recap: stop.recap, stoppedAt: stop.stoppedAt, recapReportedAt: stop.recapReportedAt, platform: controlPlatform)
            case .progress(let progress):
                guard let index = state.indices(forWorktreePath: progress.worktree) else { return }
                if let input = progress.userInput {
                    state.repos[index.repo].worktrees[index.worktree].recordUserInput(input)
                }
                state.clearAgentAttention(callerPath: progress.worktree, callerAgentID: progress.agentID,
                    runtime: progress.runtime, sessionID: progress.sessionID, progressedAt: progress.progressedAt)
            }
            try save()
        }
    }
}
