import Foundation
import GrafttyProtocol

/// What phase two of a `graftty worktree add` needs once the request is
/// admitted and its `.creating` row inserted.
public struct CLIWorktreeCreationPlan: Sendable {
    public let repoPath: String
    public let worktreePath: String
    public let branch: BranchSelection
    /// The immutable commit an explicit `--base` resolved to, or nil.
    public let base: String?
    public let initialCommand: String?
    public let agentRuntime: TeamHookRuntime?
}

/// Host-specific effects behind `CLIWorktreeCreationRequestHandler`. The
/// Mac app runs phase two through `AddWorktreeFlow`; the headless host runs
/// Git and zmx itself.
@MainActor
public protocol CLIWorktreeCreationPlatform: AnyObject {
    var state: AppState { get set }
    var teamInbox: TeamInbox { get }
    var worktreeCreations: CLIWorktreeCreationStore { get }
    /// Where staged agent prompts wait for their launch command.
    var agentPromptDirectory: URL { get }
    /// Records a change; no window may be observing state.
    func stateDidChange() throws
    /// Writes state now. Agent hooks read the launch expectation from disk.
    func saveStateNow() throws
    /// A host-specific reason the destination cannot be used, checked
    /// before the placeholder is inserted.
    func creationDestinationError(worktreePath: String, repo: RepoEntry) -> String?
    /// Runs Git and starts the first pane. Returns the failure message, or
    /// nil once the pane accepted its launch command. A Git failure removes
    /// the placeholder.
    func finishWorktreeCreation(_ plan: CLIWorktreeCreationPlan) async -> String?
}

public extension CLIWorktreeCreationPlatform {
    func creationDestinationError(worktreePath: String, repo: RepoEntry) -> String? { nil }

    /// Live launch status and persisted diagnostics share the same lookup for
    /// local and paired CLI callers. A restart never resumes the launch task.
    func worktreeCreationStatus(operationID: String) -> WorktreeCreateStatus? {
        if var status = worktreeCreations.status(operationID: operationID) {
            if let progress = state.worktree(forPath: status.worktreePath)?.creationProgress,
               progress.operationID == operationID { status.progress = progress }
            return status
        }
        guard let entry = state.repos.flatMap(\.worktrees).first(where: {
            $0.creationProgress?.operationID == operationID
        }), let progress = entry.creationProgress, !progress.isPending else { return nil }
        return WorktreeCreateStatus(operationID: operationID,
            state: progress.phase == .ready ? .ready : .failed,
            worktreePath: entry.path, messageAddress: entry.path,
            error: progress.error, progress: progress)
    }
}

/// `graftty worktree add`, local or from a paired Mac: admits the request
/// against live state, inserts the placeholder, saves any initial agent
/// task, and returns a pending operation while phase two runs.
@MainActor
public enum CLIWorktreeCreationRequestHandler {
    public static func begin(
        _ request: CreateWorktreeRequest,
        creationOrigin: WorktreeHistory.Origin? = nil,
        platform: any CLIWorktreeCreationPlatform
    ) async -> ResponseMessage {
        let worktreeCreations = platform.worktreeCreations
        let callerPath = request.callerWorktree
        let operationID = request.operationID ?? UUID().uuidString.lowercased()
        if let existing = platform.worktreeCreationStatus(operationID: operationID) {
            return .worktreeCreate(existing)
        }
        defer { worktreeCreations.discardBaseCapture(operationID: operationID) }
        guard let repo = platform.state.repos.first(where: { repo in
            repo.worktrees.contains(where: { $0.path == callerPath })
        }) else {
            return .error("caller is not inside a tracked worktree")
        }

        if let error = WorktreeCreationInput.validationError(
            worktreeName: request.worktreeName, branchName: request.branchName,
            existing: request.existing, base: request.base
        ) {
            return .error(error)
        }
        let resolvedBase: String?
        do {
            resolvedBase = try await worktreeCreations.captureBase(
                request.base, at: callerPath, operationID: operationID
            )
        } catch {
            return .error("could not resolve worktree base: \(error)")
        }
        // Ref resolution suspends this handler. A retry may have completed
        // the same preparation and started the operation in the meantime.
        if let retained = platform.worktreeCreationStatus(operationID: operationID) {
            return .worktreeCreate(retained)
        }

        let agentRuntime = request.agentRuntime
        let agentPrompt = request.agentPrompt
        if agentPrompt != nil, agentRuntime == nil {
            return .error("an agent prompt requires an agent runtime")
        }
        if let error = CLIWorktreeCreationPolicy.obsoletePromptLoaderError(
            agentRuntime: agentRuntime, command: request.command, agentPrompt: agentPrompt
        ) {
            return .error(error)
        }
        let launch: PreparedWorktreeAgentLaunch
        if let agentRuntime,
           CLIWorktreeCreationPolicy.shouldStageAgentPrompt(
               agentRuntime: agentRuntime, command: request.command, agentPrompt: agentPrompt
           ) {
            do {
                launch = try WorktreeAgentLaunchCommand.prepare(
                    agent: agentRuntime, prompt: agentPrompt, exactCommand: nil, managedAgent: request.managedAgent,
                    promptDirectory: platform.agentPromptDirectory
                )
            } catch {
                return .error("could not stage agent prompt: \(error.localizedDescription)")
            }
        } else {
            launch = PreparedWorktreeAgentLaunch(command: request.command, promptFile: nil)
        }

        let branch: BranchSelection = request.existing
            ? .useExisting(name: request.branchName, source: .local)
            : .createNew(name: request.branchName)
        if let error = platform.creationDestinationError(
            worktreePath: AppState.linkedWorktreePath(repoPath: repo.path, worktreeName: request.worktreeName),
            repo: repo
        ) {
            launch.discardPromptFile()
            return .error(error)
        }
        let worktreePath: String
        switch platform.state.insertCreatingWorktree(
            repoPath: repo.path,
            worktreeName: request.worktreeName,
            branch: branch,
            base: request.base,
            creationOrigin: creationOrigin ?? .init(date: Date(), source: .worktree, worktreePath: callerPath,
                worktreeName: repo.worktrees.first(where: { $0.path == callerPath }).map {
                    SidebarWorktreeLabel.text(for: $0, inRepoAtPath: repo.path,
                        siblingPaths: repo.worktrees.map(\.path), defaultBranch: repo.defaultBranchHint)
                })
        ) {
        case .success(let path):
            worktreePath = path
            try? platform.stateDidChange()
        case .failure(let error):
            launch.discardPromptFile()
            return .error(error.userMessage ?? "could not begin worktree creation")
        }

        if let index = platform.state.indices(forWorktreePath: worktreePath) {
            platform.state.repos[index.repo].worktrees[index.worktree].creationProgress?.operationID = operationID
            if let agent = request.managedAgent {
                platform.state.repos[index.repo].worktrees[index.worktree].agents.append(agent)
            }
            try? platform.stateDidChange()
        }

        if let agentRuntime, launch.promptFile != nil,
           let index = platform.state.indices(forWorktreePath: worktreePath) {
            platform.state.repos[index.repo].worktrees[index.worktree]
                .expectLaunchPrompt(WorktreeAgentLaunchCommand.initialPrompt(agentPrompt), runtime: agentRuntime)
        }

        // Persist before starting Git, so both a failed launch and a later
        // manual launch can recover the task. Retries return above before
        // reaching this write, preventing duplicate inbox copies.
        if let agentRuntime {
            do {
                try WorktreeAgentLaunchCommand.saveInitialPrompt(
                    agentPrompt, runtime: agentRuntime, repo: repo,
                    worktreePath: worktreePath, branchName: request.branchName, inbox: platform.teamInbox
                )
                // A background CLI request may have no window observing state.
                // Save the launch expectation before its first hook can arrive.
                try platform.saveStateNow()
            } catch {
                platform.state.removeWorktree(atPath: worktreePath)
                // The placeholder was already recorded above.
                try? platform.stateDidChange()
                launch.discardPromptFile()
                return .error("could not save initial agent task: \(error.localizedDescription)")
            }
        }
        let plan = CLIWorktreeCreationPlan(
            repoPath: repo.path,
            worktreePath: worktreePath,
            branch: branch,
            base: resolvedBase,
            initialCommand: launch.command.flatMap { value in
                value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : value
            },
            agentRuntime: agentRuntime
        )
        var status = worktreeCreations.start(
            worktreePath: worktreePath,
            messageAddress: worktreePath,
            stagedPromptFile: launch.promptFile,
            operationID: operationID
        ) {
            let failure = await platform.finishWorktreeCreation(plan)
            if let agent = request.managedAgent,
               let index = platform.state.indices(forWorktreePath: worktreePath),
               let ai = platform.state.repos[index.repo].worktrees[index.worktree].agents.firstIndex(where: { $0.id == agent.id }) {
                if let failure {
                    platform.state.repos[index.repo].worktrees[index.worktree].agents[ai].launchFailed(reason: failure)
                } else {
                    let slot = platform.state.repos[index.repo].worktrees[index.worktree].primaryPaneSlotID
                        ?? platform.state.repos[index.repo].worktrees[index.worktree].splitTree.allLeaves.first
                    platform.state.repos[index.repo].worktrees[index.worktree].agents[ai].paneSlotID = slot
                }
                try? platform.saveStateNow()
            }
            guard let failure else { return nil }
            // A background request may have no view persisting removal of
            // a failed placeholder or cancellation of its launch marker.
            if let index = platform.state.indices(forWorktreePath: worktreePath) {
                platform.state.repos[index.repo].worktrees[index.worktree].cancelExpectedLaunch()
            }
            try? platform.stateDidChange()
            return failure
        }
        status.progress = platform.state.worktree(forPath: worktreePath)?.creationProgress
        return .worktreeCreate(status)
    }
}
