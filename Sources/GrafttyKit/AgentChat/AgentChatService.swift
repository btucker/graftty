import Foundation
import GrafttyProtocol

/// Who is asking to act on a tab's conversation.
public enum AgentChatViewer: Sendable, Equatable {
    /// The Mac that hosts the agent.
    case host
    /// A paired device, by its authenticated device ID.
    case device(String)
}

/// The host's entry point for Chat. The Mac app calls it directly for its own
/// tabs, and the paired-viewer channel calls it for everyone else, so both
/// paths bind to the same session and pass the same checks.
@MainActor
public final class AgentChatService {
    private let host: AgentChatHost
    private let storage: CodexAppServerSessionStorage
    private let state: @MainActor () -> AppState
    private let ownership: SessionDisplayOwnershipStore?

    public init(
        host: AgentChatHost = AgentChatHost(),
        storage: CodexAppServerSessionStorage,
        ownership: SessionDisplayOwnershipStore?,
        state: @escaping @MainActor () -> AppState
    ) {
        self.host = host
        self.storage = storage
        self.ownership = ownership
        self.state = state
    }

    /// Chat for one viewer of one tab.
    public func connection(worktreePath: String, agentID: String, viewer: AgentChatViewer) -> AgentChatConnection {
        AgentChatConnection(
            open: { [weak self] in
                await self?.open(worktreePath: worktreePath, agentID: agentID)
                    ?? .unavailable("Chat is unavailable on this host.")
            },
            submit: { [weak self] submission in
                await self?.submit(submission, worktreePath: worktreePath, viewer: viewer) ?? .rejected(.unavailable)
            },
            answer: { [weak self] binding, requestID, decision in
                await self?.answer(binding: binding, requestID: requestID, decision: decision,
                                   worktreePath: worktreePath, viewer: viewer) ?? false
            }
        )
    }

    /// Whether this tab can offer the Chat / Terminal switch right now.
    public func isAvailable(worktreePath: String, agentID: String) async -> Bool {
        await resolve(worktreePath: worktreePath, agentID: agentID).binding != nil
    }

    public func open(worktreePath: String, agentID: String) async -> AgentChatFeed {
        switch await resolve(worktreePath: worktreePath, agentID: agentID).resolution {
        case .unavailable(let reason):
            return .unavailable(reason)
        case .endpoint(let endpoint):
            do {
                let (snapshot, updates) = try await host.open(endpoint)
                return .attached(snapshot, updates)
            } catch {
                return .unavailable("Chat could not connect to this agent. The terminal is still available.")
            }
        }
    }

    public func submit(
        _ submission: AgentChatSubmission, worktreePath: String, viewer: AgentChatViewer
    ) async -> AgentChatSubmissionResult {
        let current = await resolve(worktreePath: worktreePath, agentID: submission.binding.agentID)
        return await host.submit(
            submission, current: current.binding,
            isController: isController(viewer, sessionName: current.sessionName)
        )
    }

    public func answer(
        binding: AgentChatBinding, requestID: String, decision: AgentChatDecision,
        worktreePath: String, viewer: AgentChatViewer
    ) async -> Bool {
        let current = await resolve(worktreePath: worktreePath, agentID: binding.agentID)
        return await host.answer(
            binding: binding, requestID: requestID, decision: decision, current: current.binding,
            isController: isController(viewer, sessionName: current.sessionName)
        )
    }

    /// The same rule that admits terminal keystrokes: the display owner acts,
    /// and the host Mac may act on a session nobody has claimed.
    func isController(_ viewer: AgentChatViewer, sessionName: String?) -> Bool {
        guard let ownership, let sessionName else { return viewer == .host }
        let snapshot = ownership.snapshot(sessionName: sessionName)
        // A leader that has disconnected keeps its place but cannot act.
        let hasActiveOwner = snapshot.ownerClientID.map {
            ownership.isAttachedOwner(sessionName: sessionName, clientID: $0)
        } ?? false
        switch viewer {
        case .host:
            return !hasActiveOwner || snapshot.ownerKind == .mac
        case .device(let deviceID):
            return hasActiveOwner && snapshot.ownerIdentity == "ssh-device:\(deviceID)"
        }
    }

    private struct Resolved {
        let resolution: AgentChatResolution
        let sessionName: String?
        var binding: AgentChatBinding? {
            if case .endpoint(let endpoint) = resolution { return endpoint.binding }
            return nil
        }
    }

    private func resolve(worktreePath: String, agentID: String) async -> Resolved {
        let state = state()
        guard let repo = state.repos.first(where: { $0.worktrees.contains { $0.path == worktreePath } }),
              let worktree = state.worktree(forPath: worktreePath),
              let agent = worktree.agents.first(where: { $0.id == agentID }) else {
            return Resolved(resolution: AgentChatHost.resolve(agent: nil, record: nil, appServerIsRunning: false),
                            sessionName: nil)
        }
        let sessionName = agent.paneSlotID.flatMap { worktree.paneSessions[$0] }.map(ZmxLauncher.sessionName(for:))
        let storage = storage
        let teamID = repo.path
        let record: CodexAppServerSessionRecord? = await OffMainIO.run {
            guard let sessionName else { return nil }
            return try? storage.read(teamID: teamID, worktree: worktreePath, paneSessionName: sessionName)
        }
        // A reused PID is another process. Match the recorded start time.
        let running = record.map { record in
            record.appServerProcessStartTimeMicroseconds.map {
                ProcessIdentityReader.startTimeMicroseconds(ofPID: record.appServerPID) == $0
            } ?? false
        } ?? false
        return Resolved(
            resolution: AgentChatHost.resolve(agent: agent, record: record, appServerIsRunning: running),
            sessionName: sessionName
        )
    }
}
