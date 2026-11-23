import Foundation
import GrafttyProtocol
import NIOConcurrencyHelpers
import NIOCore
import NIOSSH

/// One paired viewer's Chat channel for one agent tab. The host answers the
/// opening frame with the conversation so far and then streams every change.
/// Replies to submissions and answers carry the ID they answer, so they can
/// interleave with that stream.
public final class AgentChatChannelClient: @unchecked Sendable {
    static let unsupported = "Chat is not available from the Mac that runs this agent. The terminal is still available."
    static let unreachable = "Chat could not reach the Mac that runs this agent. The terminal is still available."

    private enum ClientError: Error { case closed, rejected, timedOut }

    private let channel: SubsystemChannel
    private let deadline: ReplyDeadline
    private let lock = NIOLock()
    private var pending: [String: SSHReplyWaiter<AgentChatServerMessage>] = [:]
    private var updates: AsyncStream<AgentChatUpdate>.Continuation?

    public convenience init(parentChannel: Channel, parentHandler: NIOSSHHandler, timeout: Duration = .seconds(30)) {
        self.init(parentChannel: parentChannel, parentHandler: parentHandler,
                  subsystemReplyTimeout: timeout, deadline: .after(timeout))
    }

    init(parentChannel: Channel, parentHandler: NIOSSHHandler, subsystemReplyTimeout: Duration, deadline: ReplyDeadline) {
        channel = SubsystemChannel(
            parentChannel: parentChannel,
            parentHandler: parentHandler,
            subsystem: SSHChannelTypeNames.agentChat,
            // A failed open must not take the whole link down with it.
            closeParentOnOpenTimeout: false,
            reply: .acknowledged(timeout: subsystemReplyTimeout),
            errors: SubsystemErrors(
                closed: ClientError.closed, rejected: ClientError.rejected, timedOut: ClientError.timedOut
            )
        )
        self.deadline = deadline
    }

    /// Attaches to the tab's conversation. The channel closes when the
    /// returned stream is no longer read.
    public func open(worktreePath: String, agentID: String) async -> AgentChatFeed {
        let (stream, continuation) = AsyncStream<AgentChatUpdate>.makeStream()
        lock.withLock { updates = continuation }
        do {
            try await channel.open(
                onFrame: { [self] bytes in receive(bytes) },
                onError: { [weak self] _ in self?.close() },
                onClose: { [weak self] in self?.channelClosed() }
            )
        } catch ClientError.rejected {
            return .unavailable(Self.unsupported)
        } catch {
            return .unavailable(Self.unreachable)
        }
        continuation.onTermination = { [weak self] _ in self?.close() }
        let reply = try? await request("open", .open(worktreePath: worktreePath, agentID: agentID))
        switch reply {
        case .snapshot(let snapshot):
            return .attached(snapshot, stream)
        case .unavailable(let reason):
            close()
            return .unavailable(reason)
        default:
            close()
            return .unavailable(Self.unreachable)
        }
    }

    public func submit(_ submission: AgentChatSubmission) async -> AgentChatSubmissionResult {
        // Once the frame is written the host may act on it, whatever happens
        // to its reply.
        let written = NIOLockedValueBox(false)
        let reply = try? await request("submit:\(submission.submissionID)", .submit(submission)) {
            written.withLockedValue { $0 = true }
        }
        if case .submitted(_, let result) = reply { return result }
        return written.withLockedValue { $0 } ? .uncertain : .rejected(.unavailable)
    }

    public func answer(binding: AgentChatBinding, requestID: String, decision: AgentChatDecision) async -> Bool {
        let reply = try? await request(
            "answer:\(requestID)", .answer(binding: binding, requestID: requestID, decision: decision)
        )
        if case .answered(_, let accepted) = reply { return accepted }
        return false
    }

    public func close() {
        channel.close()
        channelClosed()
    }

    /// Sends one message and waits for the reply filed under `key`.
    private func request(
        _ key: String, _ message: AgentChatClientMessage, onWritten: @escaping @Sendable () -> Void = {}
    ) async throws -> AgentChatServerMessage {
        let body = try JSONEncoder.shared.encode(message)
        guard body.count <= AgentChatClientMessage.maximumEncodedBytes, let child = channel.channel else {
            throw ClientError.closed
        }
        let waiter = SSHReplyWaiter<AgentChatServerMessage>()
        let registered = lock.withLock {
            guard pending[key] == nil else { return false }
            pending[key] = waiter
            return true
        }
        guard registered else { throw ClientError.closed }
        defer { lock.withLock { if pending[key] === waiter { pending[key] = nil } } }
        return try await waiter.wait(
            scheduleTimeout: deadline.schedule,
            timeoutError: ClientError.timedOut,
            onAbort: {},
            start: {
                child.writeAndFlush(child.allocator.buffer(bytes: body)).whenComplete { result in
                    switch result {
                    case .success: onWritten()
                    case .failure(let error): waiter.finish(.failure(error))
                    }
                }
            }
        )
    }

    private func receive(_ bytes: Data) {
        guard let message = try? JSONDecoder.shared.decode(AgentChatServerMessage.self, from: bytes) else {
            close()
            return
        }
        let key: String
        switch message {
        case .update(let update):
            lock.withLock { updates }?.yield(update)
            return
        case .snapshot, .unavailable: key = "open"
        case .submitted(let submissionID, _): key = "submit:\(submissionID)"
        case .answered(let requestID, _): key = "answer:\(requestID)"
        }
        lock.withLock { pending.removeValue(forKey: key) }?.finish(.success(message))
    }

    private func channelClosed() {
        let (waiters, continuation) = lock.withLock {
            defer { pending = [:]; updates = nil }
            return (Array(pending.values), updates)
        }
        waiters.forEach { $0.finish(.failure(ClientError.closed)) }
        continuation?.finish()
    }
}

extension AgentChatConnection {
    /// Chat for one tab through whichever link `link` returns when the view
    /// opens. Sends and answers stay on the channel that open made.
    public static func following(
        worktreePath: String, agentID: String,
        link: @escaping @Sendable () async -> (any RemoteHostLink)?
    ) -> AgentChatConnection {
        remote(worktreePath: worktreePath, agentID: agentID) {
            guard let link = await link() as? any AgentChatHostLink else { throw ChannelError.ioOnClosedChannel }
            return try await link.makeAgentChatClient()
        }
    }

    /// Chat for one tab over a paired link. Each `open` uses a fresh channel
    /// from `makeClient`, replacing the one before it.
    public static func remote(
        worktreePath: String, agentID: String,
        makeClient: @escaping @Sendable () async throws -> AgentChatChannelClient
    ) -> AgentChatConnection {
        let current = NIOLockedValueBox<AgentChatChannelClient?>(nil)
        return AgentChatConnection(
            open: {
                guard let client = try? await makeClient() else {
                    return .unavailable(AgentChatChannelClient.unreachable)
                }
                current.withLockedValue { earlier in
                    defer { earlier = client }
                    return earlier
                }?.close()
                return await client.open(worktreePath: worktreePath, agentID: agentID)
            },
            submit: { submission in
                await current.withLockedValue { $0 }?.submit(submission) ?? .rejected(.unavailable)
            },
            answer: { binding, requestID, decision in
                await current.withLockedValue { $0 }?.answer(
                    binding: binding, requestID: requestID, decision: decision
                ) ?? false
            }
        )
    }
}
