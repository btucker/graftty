import Foundation
import GrafttyProtocol
import GrafttyTunnel
import NIOCore
import NIOSSH
import Testing
@testable import GrafttyRemoteClient

// The waits below have no deadline of their own, so a regression fails here
// instead of hanging the run.
@Suite(.timeLimit(.minutes(1)))
struct AgentChatChannelClientTests {
    private static let binding = AgentChatBinding(agentID: "codex-1", assignmentID: "A", conversationID: "T")

    /// The host end of the chat channel, scripted by the test.
    private final class Host: @unchecked Sendable {
        private let lock = NSLock()
        private var _received: [AgentChatClientMessage] = []
        private var channels: [Channel] = []
        var refusesSubsystem = false
        var unavailable: String?
        var result: AgentChatSubmissionResult = .accepted
        /// Close the channel when a submission arrives, before any reply.
        var dropsOnSubmit = false
        var snapshot = AgentChatSnapshot(binding: AgentChatChannelClientTests.binding)

        var received: [AgentChatClientMessage] { lock.withLock { _received } }

        func install(_ child: Channel) throws {
            let pipeline = child.pipeline.syncOperations
            try pipeline.addHandler(SSHChannelDataCodec())
            try pipeline.addHandler(LengthPrefixedFraming.makeFrameDecoder())
            try pipeline.addHandler(LengthPrefixedFraming.makeFramePrepender())
            try pipeline.addHandler(Handler(host: self))
        }

        func push(_ update: AgentChatUpdate) {
            for channel in lock.withLock({ channels }) { write(.update(update), on: channel) }
        }

        fileprivate func write(_ message: AgentChatServerMessage, on channel: Channel) {
            guard let body = try? JSONEncoder().encode(message) else { return }
            // The testing event loop defers `execute` from its own thread
            // until the loop is run by hand; a direct write hops when needed.
            channel.writeAndFlush(channel.allocator.buffer(bytes: body), promise: nil)
        }

        fileprivate func handle(_ message: AgentChatClientMessage, on channel: Channel) {
            lock.withLock { _received.append(message) }
            switch message {
            case .open:
                if let unavailable {
                    write(.unavailable(reason: unavailable), on: channel)
                } else {
                    lock.withLock { channels.append(channel) }
                    write(.snapshot(snapshot), on: channel)
                }
            case .submit(let submission):
                if dropsOnSubmit {
                    channel.close(promise: nil)
                } else {
                    write(.submitted(submissionID: submission.submissionID, result: result), on: channel)
                }
            case .answer(_, let requestID, _):
                write(.answered(requestID: requestID, accepted: true), on: channel)
            }
        }
    }

    private final class Handler: ChannelInboundHandler, @unchecked Sendable {
        typealias InboundIn = ByteBuffer
        let host: Host
        init(host: Host) { self.host = host }

        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            let bytes = Data(unwrapInboundIn(data).readableBytesView)
            guard let message = try? JSONDecoder().decode(AgentChatClientMessage.self, from: bytes) else { return }
            host.handle(message, on: context.channel)
        }

        func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
            guard event is SSHChannelRequestEvent.SubsystemRequest else {
                context.fireUserInboundEventTriggered(event)
                return
            }
            if host.refusesSubsystem {
                context.triggerUserOutboundEvent(ChannelFailureEvent(), promise: nil)
            } else {
                context.triggerUserOutboundEvent(ChannelSuccessEvent(), promise: nil)
            }
        }
    }

    private func connect(_ host: Host) async throws -> (InMemorySSHLink, AgentChatConnection) {
        let link = try await InMemorySSHLink.make(serverChild: { try host.install($0) })
        let connection = AgentChatConnection.remote(worktreePath: "/repo/wt", agentID: "codex-1") {
            AgentChatChannelClient(parentChannel: link.client, parentHandler: link.clientHandler)
        }
        return (link, connection)
    }

    private func submission(_ text: String, id: String = "s1") -> AgentChatSubmission {
        AgentChatSubmission(binding: Self.binding, submissionID: id, text: text)
    }

    @Test func aRemoteViewerReceivesTheSnapshotAndUpdates() async throws {
        let host = Host()
        host.snapshot.items = [AgentChatItem(id: "i1", turnID: "t1", kind: .agent, text: "Hello", isComplete: true)]
        let (link, connection) = try await connect(host)

        guard case .attached(let snapshot, let updates) = await connection.open() else {
            Issue.record("expected the conversation")
            return
        }
        #expect(snapshot == host.snapshot)
        #expect(host.received == [.open(worktreePath: "/repo/wt", agentID: "codex-1")])

        let update = AgentChatUpdate(sequence: 1, event: .turnState(.active))
        host.push(update)
        var iterator = updates.makeAsyncIterator()
        #expect(await iterator.next() == update)
        await link.close()
    }

    @Test("@spec AGENT-6.182: When the user sends a slash command from an agent tab's Chat view on Mac or GrafttyMobile, the application shall deliver the draft's exact command text and arguments to that tab's bound session.")
    func aRemoteSubmissionReturnsTheHostsResult() async throws {
        let host = Host()
        let (link, connection) = try await connect(host)
        // The channel lives for as long as its feed is held.
        guard case .attached(_, let updates) = await connection.open() else {
            Issue.record("expected the conversation")
            return
        }
        defer { withExtendedLifetime(updates) {} }

        let sent = submission("/review the last commit")
        #expect(await connection.submit(sent) == .accepted)
        #expect(host.received.last == .submit(sent))

        host.result = .rejected(.notController)
        #expect(await connection.submit(submission("again", id: "s2")) == .rejected(.notController))

        #expect(await connection.answer(Self.binding, "r1", .accept))
        #expect(host.received.last == .answer(binding: Self.binding, requestID: "r1", decision: .accept))
        await link.close()
    }

    @Test func aLostAcknowledgmentIsReportedAsUncertain() async throws {
        let host = Host()
        host.dropsOnSubmit = true
        let (link, connection) = try await connect(host)

        // Nothing is open yet, so nothing can have been sent.
        #expect(await connection.submit(submission("early")) == .rejected(.unavailable))

        guard case .attached(_, let updates) = await connection.open() else {
            Issue.record("expected the conversation")
            return
        }
        #expect(await connection.submit(submission("hello")) == .uncertain)

        // The feed ends with the channel, and later sends are refused.
        var iterator = updates.makeAsyncIterator()
        #expect(await iterator.next() == nil)
        #expect(await connection.submit(submission("later", id: "s2")) == .rejected(.unavailable))
        #expect(await connection.answer(Self.binding, "r1", .accept) == false)
        await link.close()
    }

    @Test func aHostThatCannotServeChatExplainsWhy() async throws {
        let host = Host()
        host.refusesSubsystem = true
        let (link, connection) = try await connect(host)
        guard case .unavailable(let reason) = await connection.open() else {
            Issue.record("expected Chat to be unavailable")
            return
        }
        #expect(reason == "Chat is not available from the Mac that runs this agent. The terminal is still available.")
        #expect(host.received.isEmpty)

        host.refusesSubsystem = false
        host.unavailable = "Chat is not available for this agent yet. Use Terminal."
        guard case .unavailable(let hostReason) = await connection.open() else {
            Issue.record("expected the host's reason")
            return
        }
        #expect(hostReason == "Chat is not available for this agent yet. Use Terminal.")
        await link.close()
    }

    @Test func reopeningReplacesTheEarlierChannel() async throws {
        let host = Host()
        let (link, connection) = try await connect(host)
        guard case .attached(_, let first) = await connection.open(),
              case .attached(_, let second) = await connection.open() else {
            Issue.record("expected the conversation twice")
            return
        }
        defer { withExtendedLifetime(second) {} }
        var iterator = first.makeAsyncIterator()
        #expect(await iterator.next() == nil)
        #expect(await connection.submit(submission("hello")) == .accepted)
        await link.close()
    }

    @Test func aFeedNobodyReadsClosesItsChannel() async throws {
        let host = Host()
        let (link, connection) = try await connect(host)
        guard case .attached = await connection.open() else {
            Issue.record("expected the conversation")
            return
        }
        // The feed was dropped, so the viewer has gone and nothing is sent.
        #expect(await connection.submit(submission("hello")) == .rejected(.unavailable))
        #expect(host.received.count == 1)
        await link.close()
    }
}
