import Foundation
import GrafttyHostAgent
import GrafttyKit
import GrafttyProtocol
import NIOCore
import NIOEmbedded
import NIOSSH
import Testing

struct AgentChatChannelHandlerTests {
    private let binding = AgentChatBinding(agentID: "codex-1", assignmentID: "A", conversationID: "T")
    private let device = RemoteDeviceID(value: "phone")

    /// A host-side session the test scripts: its snapshot, its live updates,
    /// and what it was asked to do.
    private final class Session: @unchecked Sendable {
        private let lock = NSLock()
        private var _snapshot: AgentChatSnapshot
        private var _submissions: [AgentChatSubmission] = []
        private var _answers: [String] = []
        private var _opens: [(RemoteDeviceID, String, String)] = []
        private var continuations: [AsyncStream<AgentChatUpdate>.Continuation] = []
        var unavailable: String?
        var result: AgentChatSubmissionResult = .accepted

        init(_ snapshot: AgentChatSnapshot) { _snapshot = snapshot }

        var submissions: [AgentChatSubmission] { lock.withLock { _submissions } }
        var answers: [String] { lock.withLock { _answers } }
        var opens: [(RemoteDeviceID, String, String)] { lock.withLock { _opens } }

        /// Folds the update into the session and delivers it to every viewer.
        func push(_ update: AgentChatUpdate) {
            let targets = lock.withLock { () -> [AsyncStream<AgentChatUpdate>.Continuation] in
                var transcript = AgentChatTranscript(snapshot: _snapshot)
                transcript.apply(update)
                _snapshot = transcript.snapshot
                return continuations
            }
            targets.forEach { $0.yield(update) }
        }

        var opener: AgentChatChannelHandler.Opener {
            { [self] device, path, agent in
                lock.withLock { _opens.append((device, path, agent)) }
                return AgentChatConnection(
                    open: { [self] in
                        if let unavailable { return .unavailable(unavailable) }
                        let (stream, continuation) = AsyncStream<AgentChatUpdate>.makeStream()
                        let snapshot = lock.withLock { () -> AgentChatSnapshot in
                            continuations.append(continuation)
                            return _snapshot
                        }
                        return .attached(snapshot, stream)
                    },
                    submit: { [self] submission in
                        lock.withLock { _submissions.append(submission) }
                        return result
                    },
                    answer: { [self] _, requestID, _ in
                        lock.withLock {
                            _answers.append(requestID)
                            return _snapshot.requests.contains { $0.id == requestID }
                        }
                    }
                )
            }
        }
    }

    private func channel(_ session: Session) async throws -> NIOAsyncTestingChannel {
        let channel = NIOAsyncTestingChannel()
        try await channel.pipeline.addHandler(AgentChatChannelHandler(deviceID: device, opener: session.opener)).get()
        try await channel.connect(to: .init(unixDomainSocketPath: "/tmp/agent-chat-test")).get()
        return channel
    }

    private func send(_ message: AgentChatClientMessage, on channel: NIOAsyncTestingChannel) async throws {
        try await channel.writeInbound(ByteBuffer(bytes: JSONEncoder().encode(message)))
    }

    private func next(_ channel: NIOAsyncTestingChannel) async throws -> AgentChatServerMessage {
        let buffer = try await channel.waitForOutboundWrite(as: ByteBuffer.self)
        return try JSONDecoder().decode(AgentChatServerMessage.self, from: Data(buffer.readableBytesView))
    }

    private var open: AgentChatClientMessage { .open(worktreePath: "/repo/wt", agentID: "codex-1") }

    @Test func openingSendsTheSnapshotThenUpdatesInOrder() async throws {
        let session = Session(AgentChatSnapshot(binding: binding, sequence: 3))
        let channel = try await channel(session)
        try await send(open, on: channel)

        #expect(try await next(channel) == .snapshot(AgentChatSnapshot(binding: binding, sequence: 3)))
        #expect(session.opens.first?.0 == device)
        #expect(session.opens.first?.1 == "/repo/wt")

        let updates = (4...6).map { AgentChatUpdate(sequence: $0, event: .turnState($0 == 5 ? .active : .idle)) }
        updates.forEach(session.push)
        for update in updates {
            #expect(try await next(channel) == .update(update))
        }
        _ = try? await channel.finish()
    }

    @Test func aSubmissionIsAnsweredWithItsOwnIDAndTheHostsResult() async throws {
        let session = Session(AgentChatSnapshot(binding: binding))
        session.result = .rejected(.notController)
        let channel = try await channel(session)
        try await send(open, on: channel)
        _ = try await next(channel)

        let submission = AgentChatSubmission(binding: binding, submissionID: "s1", text: "/review the last commit")
        try await send(.submit(submission), on: channel)
        #expect(try await next(channel) == .submitted(submissionID: "s1", result: .rejected(.notController)))
        #expect(session.submissions == [submission])
        _ = try? await channel.finish()
    }

    @Test func aViewerThatReconnectsStillSeesThePendingRequest() async throws {
        let request = AgentChatPendingRequest(id: "7", kind: .commandApproval, summary: "touch f", canAnswerInChat: true)
        let session = Session(AgentChatSnapshot(binding: binding))
        let first = try await channel(session)
        try await send(open, on: first)
        _ = try await next(first)
        session.push(AgentChatUpdate(sequence: 1, event: .requestOpened(request)))
        _ = try await next(first)
        _ = try? await first.finish()

        let second = try await channel(session)
        try await send(open, on: second)
        guard case .snapshot(let snapshot) = try await next(second) else {
            Issue.record("expected a snapshot"); return
        }
        #expect(snapshot.requests == [request])

        session.push(AgentChatUpdate(sequence: 2, event: .requestResolved(id: "7")))
        #expect(try await next(second) == .update(AgentChatUpdate(sequence: 2, event: .requestResolved(id: "7"))))
        try await send(.answer(binding: binding, requestID: "7", decision: .accept), on: second)
        #expect(try await next(second) == .answered(requestID: "7", accepted: false))
        _ = try? await second.finish()
    }

    @Test func aTabThatCannotAttachSaysWhyAndKeepsTheChannelUsable() async throws {
        let session = Session(AgentChatSnapshot(binding: binding))
        session.unavailable = "Chat is not available for this agent yet. Use Terminal."
        let channel = try await channel(session)
        try await send(open, on: channel)
        #expect(try await next(channel) == .unavailable(reason: "Chat is not available for this agent yet. Use Terminal."))

        let submission = AgentChatSubmission(binding: binding, submissionID: "s1", text: "hello")
        try await send(.submit(submission), on: channel)
        #expect(try await next(channel) == .submitted(submissionID: "s1", result: .rejected(.unavailable)))
        #expect(session.submissions.isEmpty)
        _ = try? await channel.finish()
    }

    @Test func aSecondOpenOrAMalformedFrameClosesTheChannel() async throws {
        let session = Session(AgentChatSnapshot(binding: binding))
        let channel = try await channel(session)
        try await send(open, on: channel)
        _ = try await next(channel)
        try await send(open, on: channel)
        #expect(!channel.isActive)

        let other = try await self.channel(session)
        try await other.writeInbound(ByteBuffer(string: "not json"))
        #expect(!other.isActive)
    }

    @Test func theSubsystemIsRefusedWhenTheHostOffersNoChat() async throws {
        for offered in [false, true] {
            let session = Session(AgentChatSnapshot(binding: binding))
            let channel = NIOAsyncTestingChannel()
            let dispatcher = SubsystemDispatcher(
                streamFactory: { _, _ in throw ChannelError.ioOnClosedChannel },
                panesStateSubscribe: { _ in .init(cancel: {}) },
                paneControlMutator: { _ in .ok },
                agentChatOpener: offered ? session.opener : nil,
                ownershipStore: SessionDisplayOwnershipStore(),
                ownershipBroadcaster: DisplayOwnershipBroadcaster(),
                deviceIDProvider: { RemoteDeviceID(value: "phone") }
            )
            try await channel.pipeline.addHandler(dispatcher).get()
            try await channel.connect(to: .init(unixDomainSocketPath: "/tmp/agent-chat-test")).get()
            channel.pipeline.fireUserInboundEventTriggered(
                SSHChannelRequestEvent.SubsystemRequest(subsystem: SSHChannelTypeNames.agentChat, wantReply: false)
            )
            if offered {
                // The framing stack sits in front of the handler: one length-prefixed frame in, one out.
                var frame = ByteBuffer()
                let body = try JSONEncoder().encode(open)
                frame.writeInteger(UInt32(body.count))
                frame.writeBytes(body)
                try await channel.writeInbound(SSHChannelData(type: .channel, data: .byteBuffer(frame)))
                _ = try await channel.waitForOutboundWrite(as: SSHChannelData.self)
                #expect(session.opens.count == 1)
            } else {
                for _ in 0..<200 where channel.isActive { try await Task.sleep(nanoseconds: 5_000_000) }
                #expect(!channel.isActive)
                #expect(session.opens.isEmpty)
            }
            _ = try? await channel.finish()
        }
    }
}
