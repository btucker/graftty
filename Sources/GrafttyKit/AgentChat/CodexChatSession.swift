import Foundation
import GrafttyProtocol

/// A text-framed JSON-RPC connection to a Codex app-server.
protocol CodexChatTransport: Sendable {
    func send(_ text: String) async throws
    /// Every message the server sends. The stream ends when the server goes away.
    func messages() -> AsyncThrowingStream<String, Error>
    func close() async
}

enum CodexChatTransportError: Error, Equatable {
    case closed
    case rpc(String)
}

/// Chat's connection to the app-server that a Codex tab's own terminal
/// interface already uses. It joins the running thread as a second client, so
/// both views observe the same turns and the same pending requests. It never
/// starts a thread or a provider process.
actor CodexChatSession {
    private typealias Reply = Result<[String: Any], CodexChatTransportError>

    private let transport: any CodexChatTransport
    private let threadID: String
    private var transcript: AgentChatTranscript
    private var subscribers: [UUID: AsyncStream<AgentChatUpdate>.Continuation] = [:]
    private var pending: [Int: (Reply) -> Void] = [:]
    private var nextRequestID = 1
    private var reader: Task<Void, Never>?
    private var isLoaded = false
    /// Set once the connection is gone or the session was stopped.
    private var isStopped = false
    private var earlyItems: [AgentChatEvent] = []
    /// The provider's own ID for each request that Chat may still answer.
    private var answerable: [String: Any] = [:]
    private var submissions: [String: AgentChatSubmissionResult] = [:]
    private var isAdmitting = false
    private var skills: [CodexChatDecoder.Skill] = []

    init(binding: AgentChatBinding, transport: any CodexChatTransport) {
        self.transport = transport
        threadID = binding.conversationID
        transcript = AgentChatTranscript(snapshot: AgentChatSnapshot(binding: binding))
    }

    var snapshot: AgentChatSnapshot { transcript.snapshot }

    /// Joins the running thread and loads its history.
    func start() async throws {
        let stream = transport.messages()
        reader = Task { [weak self] in
            do {
                for try await text in stream { await self?.receive(text) }
            } catch {}
            await self?.end(reason: Self.agentExited)
        }
        _ = try await call("initialize", [
            "clientInfo": ["name": "graftty-chat", "title": "Graftty", "version": "1"],
            "capabilities": ["experimentalApi": true],
        ])
        try await transport.send(Self.encode(["method": "initialized"]))
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            request("thread/resume", ["threadId": threadID]) { reply in
                switch reply {
                case .success(let result):
                    if self.install(history: result) {
                        continuation.resume()
                    } else {
                        // With no history loaded, later events would never be shown.
                        continuation.resume(throwing: CodexChatTransportError.rpc("thread/resume returned no thread"))
                    }
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            } onSendFailure: { continuation.resume(throwing: $0) }
        }
        refreshCommands()
    }

    static let agentExited = "The agent exited."
    static let conversationChanged = "The agent moved to another conversation. Reopen Chat to continue."

    /// Ends the session for every viewer before it returns. `reason` is shown
    /// unless the conversation had already ended.
    func stop(reason: String = CodexChatSession.agentExited) async {
        reader?.cancel()
        end(reason: reason)
        await transport.close()
    }

    /// The most rows a viewer receives when it attaches. Older rows stay in
    /// the agent's terminal scrollback.
    static let snapshotItemLimit = 400

    /// The current state and every later change, with no gap between them.
    func subscribe() -> (AgentChatSnapshot, AsyncStream<AgentChatUpdate>) {
        let id = UUID()
        let (stream, continuation) = AsyncStream<AgentChatUpdate>.makeStream()
        subscribers[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeSubscriber(id) }
        }
        var snapshot = transcript.snapshot
        if snapshot.items.count > Self.snapshotItemLimit {
            snapshot.items.removeFirst(snapshot.items.count - Self.snapshotItemLimit)
        }
        return (snapshot, stream)
    }

    /// Starts one turn for `submissionID`, however often it is retried.
    func submit(submissionID: String, text: String) async -> AgentChatSubmissionResult {
        if let earlier = submissions[submissionID] { return earlier }
        guard transcript.snapshot.endedReason == nil else { return .rejected(.ended) }
        guard !isAdmitting, transcript.snapshot.turnState == .idle else { return .rejected(.busy) }
        isAdmitting = true
        defer { isAdmitting = false }

        let params: [String: Any] = [
            "threadId": threadID,
            "clientUserMessageId": submissionID,
            "input": CodexChatDecoder.input(text: text, skills: skills),
        ]
        var wasSent = false
        let result: AgentChatSubmissionResult
        do {
            _ = try await call("turn/start", params) { wasSent = true }
            result = .accepted
            emit(.turnState(.active))
        } catch CodexChatTransportError.rpc {
            return .rejected(.unavailable)
        } catch {
            guard wasSent else { return .rejected(.unavailable) }
            result = .uncertain
        }
        submissions[submissionID] = result
        return result
    }

    /// Answers a request that is still pending. Returns false for one that the
    /// terminal, another viewer, or the provider already settled.
    func answer(requestID: String, decision: AgentChatDecision) async -> Bool {
        guard let providerID = answerable.removeValue(forKey: requestID) else { return false }
        do {
            try await transport.send(Self.encode(["id": providerID, "result": ["decision": decision.rawValue]]))
            return true
        } catch {
            return false
        }
    }

    // MARK: Incoming messages

    private func receive(_ text: String) {
        guard let message = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] else {
            return
        }
        let method = message["method"] as? String
        let params = message["params"] as? [String: Any] ?? [:]
        if let method, let id = message["id"] {
            receiveRequest(id: id, method: method, params: params)
        } else if let method {
            receiveNotification(method, params)
        } else if let id = message["id"] as? Int, let handler = pending.removeValue(forKey: id) {
            if let error = message["error"] as? [String: Any] {
                handler(.failure(.rpc(error["message"] as? String ?? "request failed")))
            } else {
                handler(.success(message["result"] as? [String: Any] ?? [:]))
            }
        }
    }

    private func receiveRequest(id: Any, method: String, params: [String: Any]) {
        guard let key = CodexChatDecoder.requestID(id),
              let request = CodexChatDecoder.request(id: key, method: method, params: params, threadID: threadID)
        else { return }
        if request.canAnswerInChat { answerable[key] = id }
        emit(.requestOpened(request))
    }

    private func receiveNotification(_ method: String, _ params: [String: Any]) {
        if method == "skills/changed" {
            refreshCommands()
            return
        }
        for event in CodexChatDecoder.events(notification: method, params: params, threadID: threadID) {
            if case .requestResolved(let id) = event { answerable[id] = nil }
            guard isLoaded else {
                // History is newer than any state seen before it arrived.
                // Items are kept: the reducer merges them by ID.
                if case .item = event { earlyItems.append(event) }
                if case .textDelta = event { earlyItems.append(event) }
                continue
            }
            emit(event)
        }
    }

    /// False when the reply carries no conversation to show.
    private func install(history result: [String: Any]) -> Bool {
        guard let history = CodexChatDecoder.history(threadResult: result) else { return false }
        isLoaded = true
        for item in history.items { emit(.item(item)) }
        emit(.turnState(history.turnState))
        earlyItems.forEach(emit)
        earlyItems = []
        return true
    }

    private func refreshCommands() {
        request("skills/list", [:]) { reply in
            guard case .success(let result) = reply else { return }
            self.skills = CodexChatDecoder.skills(skillsResult: result)
            self.emit(.commands(self.skills.map(\.command)))
        } onSendFailure: { _ in }
    }

    /// Fails whatever waits on the server and ends every viewer's feed.
    private func end(reason: String) {
        isStopped = true
        let handlers = pending.values
        pending = [:]
        handlers.forEach { $0(.failure(.closed)) }
        answerable = [:]
        if transcript.snapshot.endedReason == nil {
            emit(.ended(reason: reason))
        }
        subscribers.values.forEach { $0.finish() }
        subscribers = [:]
    }

    private func emit(_ event: AgentChatEvent) {
        let update = AgentChatUpdate(sequence: transcript.snapshot.sequence + 1, event: event)
        transcript.apply(update)
        subscribers.values.forEach { $0.yield(update) }
    }

    private func removeSubscriber(_ id: UUID) {
        subscribers[id] = nil
    }

    // MARK: Requests

    private func call(
        _ method: String, _ params: [String: Any], onSent: @escaping () -> Void = {}
    ) async throws -> [String: Any] {
        try await withCheckedThrowingContinuation { continuation in
            request(method, params, onSent: onSent) { reply in
                continuation.resume(with: reply.mapError { $0 as Error })
            } onSendFailure: { continuation.resume(throwing: $0) }
        }
    }

    /// Sends a request. `onResult` runs on this actor in arrival order with
    /// the server's other messages, so it can install state before the next
    /// notification is handled.
    private func request(
        _ method: String, _ params: [String: Any], onSent: @escaping () -> Void = {},
        onResult: @escaping (Reply) -> Void, onSendFailure: @escaping (Error) -> Void
    ) {
        // Nothing would ever answer it.
        guard !isStopped else {
            onResult(.failure(.closed))
            return
        }
        let id = nextRequestID
        nextRequestID += 1
        pending[id] = onResult
        let text = Self.encode(["id": id, "method": method, "params": params])
        Task {
            do {
                try await transport.send(text)
                onSent()
            } catch {
                self.sendFailed(id: id, error: error, onSendFailure)
            }
        }
    }

    private func sendFailed(id: Int, error: Error, _ onSendFailure: (Error) -> Void) {
        guard pending.removeValue(forKey: id) != nil else { return }
        onSendFailure(error)
    }

    private static func encode(_ object: [String: Any]) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }
}
