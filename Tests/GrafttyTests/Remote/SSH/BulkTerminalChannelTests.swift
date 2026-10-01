import Foundation
import GrafttyProtocol
import NIOCore
import NIOSSH
import NIOConcurrencyHelpers
import GrafttyKit
import NIOEmbedded
import Testing
@testable import GrafttyHostAgent

@Suite("Bulk terminal channel binding")
struct BulkTerminalChannelTests {
    @Test("@spec REMOTE-11.16: When a bulk history channel is bound to an already-open terminal, the host shall route history pages to it and continue forwarding live output while history writes are blocked.")
    func blockedHistoryDoesNotBlockLiveOutput() async throws {
        let registry = BulkTerminalChannels()
        let bulk = NIOAsyncTestingChannel()
        let gate = HistoryWriteGate()
        try await bulk.pipeline.addHandler(gate).get()
        try await bulk.connect(to: .init(unixDomainSocketPath: "bulk")).get()
        let device = RemoteDeviceID(value: "owner")
        let token = UUID().uuidString
        #expect(registry.register(token: token, deviceID: device, channel: bulk))
        let stream = BulkPagedStream()
        let terminal = NIOAsyncTestingChannel()
        let handler = TerminalSessionHandler(
            streamFactory: { _ in throw TerminalTestError.unexpected }, pagedFactory: { _ in stream },
            ownershipStore: SessionDisplayOwnershipStore(), ownershipBroadcaster: DisplayOwnershipBroadcaster(),
            deviceID: device, bulkChannels: registry
        )
        try await terminal.pipeline.addHandler(handler).get()
        try await terminal.connect(to: .init(unixDomainSocketPath: "terminal")).get()
        try await terminal.eventLoop.submit {
            terminal.pipeline.fireUserInboundEventTriggered(SSHChannelRequestEvent.EnvironmentRequest(
                wantReply: false, name: "GRAFTTY_SESSION", value: "test"))
            terminal.pipeline.fireUserInboundEventTriggered(SSHChannelRequestEvent.ShellRequest(wantReply: false))
        }.get()
        stream.continuation.yield(.output(Data("before-binding".utf8)))
        let before = try await terminal.waitForOutboundWrite(as: SSHChannelData.self)
        #expect(before.type == .channel)
        try await terminal.eventLoop.submit {
            terminal.pipeline.fireUserInboundEventTriggered(SSHChannelRequestEvent.EnvironmentRequest(
                wantReply: false, name: GrafttyWebRTC.historyTokenEnvironment, value: token))
        }.get()
        stream.continuation.yield(.page(.init(incarnation: 1, checkpointID: 2, requestID: 3,
            ordinal: 0, screen: 0, data: Data([1, 2]), complete: true)))
        stream.continuation.yield(.output(Data("live".utf8)))
        var live: SSHChannelData?
        let deadline = ContinuousClock.now.advanced(by: .seconds(1))
        while (live == nil || !gate.blocked.withLockedValue { $0 }), ContinuousClock.now < deadline {
            if live == nil { live = try await terminal.readOutbound(as: SSHChannelData.self) }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(live?.type == .channel)
        #expect(gate.blocked.withLockedValue { $0 })
        try await bulk.close().get()
        try? await terminal.close().get()
    }

    @Test("@spec REMOTE-11.15: When a terminal binds a bulk history channel, the host shall require a single-use token owned by the same authenticated device and connection lifecycle.")
    func tokenIsScopedAndSingleUse() async throws {
        let registry = BulkTerminalChannels()
        let channel = NIOAsyncTestingChannel()
        let owner = RemoteDeviceID(value: "owner")
        let other = RemoteDeviceID(value: "other")
        let token = UUID().uuidString
        #expect(registry.register(token: token, deviceID: owner, channel: channel))
        #expect(!registry.register(token: token, deviceID: owner, channel: channel))
        #expect(registry.claim(token: token, deviceID: other) == nil)
        #expect(registry.claim(token: token, deviceID: owner) === channel)
        #expect(registry.claim(token: token, deviceID: owner) == nil)
        #expect(BulkTerminalChannels().claim(token: token, deviceID: owner) == nil)
        try await channel.close().get()
    }
}

private enum TerminalTestError: Error { case unexpected }
private final class BulkPagedStream: PagedTerminalStream, @unchecked Sendable {
    let events: AsyncStream<PagedTerminalEvent>
    let continuation: AsyncStream<PagedTerminalEvent>.Continuation
    init() { (events, continuation) = AsyncStream.makeStream() }
    func send(_ bytes: Data) async throws { continuation.yield(.output(bytes)) }
    func requestHistory(_ request: PagedTerminalHistoryRequest) async throws {}
    func requestCheckpoint() async throws {}
    func close() async { continuation.finish() }
}
private final class HistoryWriteGate: ChannelDuplexHandler, @unchecked Sendable {
    typealias InboundIn = SSHChannelData
    typealias OutboundIn = SSHChannelData
    let blocked = NIOLockedValueBox(false)
    private var promises: [EventLoopPromise<Void>] = []
    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        blocked.withLockedValue { $0 = true }
        if let promise { promises.append(promise) }
    }
    func channelInactive(context: ChannelHandlerContext) {
        for promise in promises { promise.fail(ChannelError.ioOnClosedChannel) }
        promises.removeAll()
        context.fireChannelInactive()
    }
}
