import Foundation
import GrafttyProtocol

/// Where a tab's live Codex conversation can be reached.
public struct AgentChatEndpoint: Sendable, Equatable {
    public let binding: AgentChatBinding
    public let socketPath: String
    public let binaryPath: String

    public init(binding: AgentChatBinding, socketPath: String, binaryPath: String) {
        self.binding = binding
        self.socketPath = socketPath
        self.binaryPath = binaryPath
    }
}

public enum AgentChatResolution: Sendable, Equatable {
    case endpoint(AgentChatEndpoint)
    /// The reason is shown to the user in place of Chat.
    case unavailable(String)
}

public enum AgentChatHostError: Error, Equatable {
    case unsupportedPlatform
}

/// Owns one chat session per agent tab on this host. Every viewer of a tab
/// shares that session, so they see the same rows and one viewer's accepted
/// submission makes the next one busy.
public actor AgentChatHost {
    typealias Connect = @Sendable (AgentChatEndpoint) throws -> any CodexChatTransport

    /// How long a tab's app-server has to answer the join.
    static let defaultStartTimeout: Duration = .seconds(15)

    private let connect: Connect
    private let startTimeout: Duration
    private var sessions: [String: (endpoint: AgentChatEndpoint, session: CodexChatSession)] = [:]

    public init() {
        connect = { endpoint in
            #if os(macOS)
            return try CodexAppServerProxyTransport(binaryPath: endpoint.binaryPath, socketPath: endpoint.socketPath)
            #else
            throw AgentChatHostError.unsupportedPlatform
            #endif
        }
        startTimeout = Self.defaultStartTimeout
    }

    init(connect: @escaping Connect, startTimeout: Duration = AgentChatHost.defaultStartTimeout) {
        self.connect = connect
        self.startTimeout = startTimeout
    }

    /// Binds a tab's agent to its running conversation. It matches the exact
    /// agent, terminal session, live app-server process, and thread; a provider
    /// name and worktree path can describe two different tabs.
    /// Whether a tab may show the Chat / Terminal switch, judged from the
    /// agent alone. `resolve` still decides whether Chat can attach.
    public static func offers(_ agent: ManagedAgent) -> Bool {
        agent.provider == .codex && (agent.status == .running || agent.status == .waiting)
            && agent.providerSessionID?.isEmpty == false
    }

    public static func resolve(
        agent: ManagedAgent?,
        record: CodexAppServerSessionRecord?,
        appServerIsRunning: Bool
    ) -> AgentChatResolution {
        guard let agent else { return .unavailable("This agent is no longer available.") }
        guard agent.provider == .codex else {
            return .unavailable("Chat is not available for this agent yet. Use Terminal.")
        }
        guard agent.status == .running || agent.status == .waiting,
              let conversation = agent.providerSessionID, !conversation.isEmpty else {
            return .unavailable("This agent has no running conversation.")
        }
        guard let record, appServerIsRunning else {
            return .unavailable("This Codex session is not connected to Graftty, so Chat cannot attach to it.")
        }
        guard record.threadID == conversation else {
            return .unavailable("The agent switched conversations. Reopen Chat once it settles.")
        }
        return .endpoint(AgentChatEndpoint(
            binding: AgentChatBinding(
                agentID: agent.id, assignmentID: agent.assignmentID.uuidString, conversationID: conversation
            ),
            socketPath: record.socketPath,
            binaryPath: record.realBinaryPath
        ))
    }

    /// Attaches a viewer. A tab whose conversation changed gets a new session;
    /// the old one ends for the viewers still holding it.
    public func open(_ endpoint: AgentChatEndpoint) async throws -> (AgentChatSnapshot, AsyncStream<AgentChatUpdate>) {
        let agentID = endpoint.binding.agentID
        if let existing = sessions[agentID] {
            if existing.endpoint == endpoint, await existing.session.snapshot.endedReason == nil {
                return await existing.session.subscribe()
            }
            sessions[agentID] = nil
            // The agent is still running when only its conversation changed.
            await existing.session.stop(reason: existing.endpoint.binding == endpoint.binding
                ? CodexChatSession.agentExited : CodexChatSession.conversationChanged)
        }
        let session = CodexChatSession(binding: endpoint.binding, transport: try await connected(to: endpoint))
        // A server that takes the connection and then never answers must not
        // leave the viewer loading. Stopping the session fails the join.
        let deadline = Task { [startTimeout] in
            guard (try? await Task.sleep(for: startTimeout)) != nil else { return }
            await session.stop()
        }
        do {
            try await session.start()
            deadline.cancel()
        } catch {
            deadline.cancel()
            await session.stop()
            throw error
        }
        if let raced = sessions[agentID], raced.endpoint == endpoint {
            // Another viewer attached while this one was connecting.
            await session.stop()
            return await raced.session.subscribe()
        }
        sessions[agentID] = (endpoint, session)
        return await session.subscribe()
    }

    /// `current` is the tab's binding as resolved now. `isController` is the
    /// host's display-ownership answer for the sending viewer.
    public func submit(
        _ submission: AgentChatSubmission, current: AgentChatBinding?, isController: Bool
    ) async -> AgentChatSubmissionResult {
        guard isController else { return .rejected(.notController) }
        guard let session = session(for: submission.binding, current: current) else {
            return .rejected(current == submission.binding ? .unavailable : .staleBinding)
        }
        return await session.submit(submissionID: submission.submissionID, text: submission.text)
    }

    public func answer(
        binding: AgentChatBinding, requestID: String, decision: AgentChatDecision,
        current: AgentChatBinding?, isController: Bool
    ) async -> Bool {
        guard isController, let session = session(for: binding, current: current) else { return false }
        return await session.answer(requestID: requestID, decision: decision)
    }

    /// Ends chat for a tab whose agent exited or was closed.
    public func close(agentID: String) async {
        guard let existing = sessions.removeValue(forKey: agentID) else { return }
        await existing.session.stop()
    }

    /// Launching the proxy and its handshake block. They run off this actor,
    /// as team delivery does, so other tabs are not held up.
    private func connected(to endpoint: AgentChatEndpoint) async throws -> any CodexChatTransport {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { [connect] in
                continuation.resume(with: Result { try connect(endpoint) })
            }
        }
    }

    private func session(for binding: AgentChatBinding, current: AgentChatBinding?) -> CodexChatSession? {
        guard binding == current, let existing = sessions[binding.agentID],
              existing.endpoint.binding == binding else { return nil }
        return existing.session
    }
}
