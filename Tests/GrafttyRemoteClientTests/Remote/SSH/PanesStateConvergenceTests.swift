import Foundation
import GrafttyProtocol
import GrafttyTunnel
import NIOCore
import NIOSSH
import Testing
@testable import GrafttyRemoteClient

@Suite("Panes-state convergence over authenticated SSH", .timeLimit(.minutes(1)))
struct PanesStateConvergenceTests {
    @Test("@spec REMOTE-6.15: While a panes-state subscription remains open, the client shall renew only that subscription on the existing host connection 60 seconds after the previous fresh initial snapshot and apply its new initial snapshot, including empty or unchanged legacy snapshots, without treating a quiet feed as a failure.", arguments: [false, true])
    func renewalReplacesSilentFeedOnSameParent(legacy: Bool) async throws {
        let fixture = try await FeedFixture.make(legacy: legacy, stallAfter: 3)
        let renewal = ManualReplyDeadline()
        let initial = ManualReplyDeadline()
        let store = try await PanesStateSubscription.open(
            on: fixture.host, health: .init(renewal: renewal.deadline, initialSnapshot: initial.deadline))
        let first = try #require(await next(fixture.channels))
        let team = TeamChannelClient(parentChannel: fixture.link.client, parentHandler: fixture.link.clientHandler, handler: { $0 })
        let control = PaneControlChannelClient(parentChannel: fixture.link.client, parentHandler: fixture.link.clientHandler)
        let terminal = TerminalSessionClient(parentChannel: fixture.link.client, parentHandler: fixture.link.clientHandler, sessionName: "retained")
        try await team.open()
        try await control.open()
        try await terminal.connect()
        // Exercise terminal bytes and the display-ownership control carrier
        // on the same SSH connection before and after pane-only renewal.
        let ownership = try DisplayOwnershipSnapshot(sessionName: "retained", ownerClientID: DisplayClientID("viewer"),
            ownerKind: .mac, grid: DisplayGrid(cols: 80, rows: 24), epoch: 7)
        let ownershipText = WebControlEnvelope.ownership(ownership).encoded()
        try await terminal.send(.text(ownershipText))
        #expect(try await terminal.receive() == .text(ownershipText))
        #expect(try await team.send(Data("team-before".utf8)) == Data("team-before".utf8))
        #expect(try await control.send(.equalize(target: "retained")) == .ok)
        let oldRows = [row("removed")]
        let metadata = SidebarSnapshot(projects: [.init(id: "project", repositoryID: "/repo", name: "Project")])
        try await send(.snapshot(oldRows, sidebar: metadata), to: first)
        #expect(try await store.waitForFirstSnapshot(timeout: .seconds(2)) == .received)
        var frames = store.frameUpdates().makeAsyncIterator()
        #expect(await frames.next() == .snapshot(oldRows, sidebar: metadata))
        // No incremental frames follow, exactly as on a healthy idle host.
        #expect(await armed(renewal))
        renewal.fire()
        guard let second = await next(fixture.channels) else {
            Issue.record("the silent pane feed never renewed")
            await store.unsubscribe()
            await fixture.link.close()
            return
        }
        let newRows = [row("added")]
        try await send(.snapshot(newRows, sidebar: metadata), to: second)
        #expect(await frames.next() == .snapshot(newRows, sidebar: metadata))
        #expect(!first.isActive)
        #expect(fixture.link.client.isActive)
        #expect(await store.connectionState == .subscribed)
        #expect(try await team.send(Data("team-after".utf8)) == Data("team-after".utf8))
        #expect(try await control.send(.equalize(target: "retained")) == .ok)
        try await terminal.send(.binary(Data("terminal-after".utf8)))
        #expect(try await terminal.receive() == .binary(Data("terminal-after".utf8)))
        try await terminal.send(.text(ownershipText))
        #expect(try await terminal.receive() == .text(ownershipText))
        #expect(fixture.shells.count == 1)

        #expect(await armed(renewal))
        renewal.fire()
        let third = try #require(await next(fixture.channels))
        // V1 hosts may send a legitimate empty snapshot without metadata.
        try await send(.snapshot([]), to: third)
        #expect(await frames.next() == .snapshot([]))
        #expect(await store.current.isEmpty)
        #expect(await store.sidebar == nil)
        // The fourth pane child opens, but never acknowledges its subsystem.
        // The one renewal deadline must bound negotiation as well as frames.
        #expect(await armed(renewal))
        renewal.fire()
        #expect(await next(fixture.channels) != nil)
        #expect(await armed(initial))
        initial.fire()
        #expect(await frames.next() == nil)
        if case .closed = await store.connectionState {} else { Issue.record("failed renewal stayed healthy") }
        #expect(fixture.link.client.isActive)
        #expect(try await team.send(Data("team-after-failure".utf8)) == Data("team-after-failure".utf8))
        #expect(try await control.send(.equalize(target: "retained")) == .ok)
        try await terminal.send(.binary(Data("terminal-after-failure".utf8)))
        #expect(try await terminal.receive() == .binary(Data("terminal-after-failure".utf8)))
        try await terminal.send(.text(ownershipText))
        #expect(try await terminal.receive() == .text(ownershipText))
        #expect(fixture.shells.count == 1)
        await store.unsubscribe()
        #expect(await frames.next() == nil)
        team.close()
        control.close()
        terminal.close()
        await fixture.link.close()
    }

    @Test("@spec REMOTE-6.16: If a panes-state subscription has no initial snapshot within 15 seconds of initial subsystem acceptance or within a 15-second renewal attempt that includes channel opening and subsystem negotiation, then the shared client shall close the feed as unhealthy and end its observers while leaving the parent connection open.")
    func acceptedButSilentChannelBecomesUnhealthy() async throws {
        let fixture = try await FeedFixture.make()
        let initial = ManualReplyDeadline()
        let renewal = ManualReplyDeadline()
        let (closes, closed) = AsyncStream<String>.makeStream()
        let store = try await PanesStateSubscription.open(
            on: fixture.host, health: .init(renewal: renewal.deadline, initialSnapshot: initial.deadline),
            onClosed: { closed.yield($0) })
        #expect(await next(fixture.channels) != nil)
        guard await armed(initial) else {
            Issue.record("the feed never armed its first-snapshot deadline")
            await store.unsubscribe()
            await fixture.link.close()
            return
        }
        initial.fire()
        #expect(await next(closes) == "panes-state initial snapshot timed out")
        if case .closed = await store.connectionState {} else { Issue.record("feed stayed healthy") }
        #expect(fixture.link.client.isActive)
        var frames = store.frameUpdates().makeAsyncIterator()
        #expect(await frames.next() == nil)
        await store.unsubscribe()
        await fixture.link.close()
    }

    private func row(_ name: String) -> WorktreePanes {
        WorktreePanes(path: "/repo/\(name)", displayName: name, repoDisplayName: "repo", displayBranch: name,
                      state: .running, isMainCheckout: false, prBadge: nil, stats: nil, attentionText: nil, layout: nil)
    }

    private func send(_ frame: PanesStateMessage, to channel: Channel) async throws {
        try await channel.writeAndFlush(channel.allocator.buffer(bytes: JSONEncoder().encode(frame))).get()
    }

    private func armed(_ deadline: ManualReplyDeadline) async -> Bool {
        let end = ContinuousClock.now.advanced(by: .seconds(2))
        while !deadline.isArmed, ContinuousClock.now < end { await Task.yield() }
        return deadline.isArmed
    }

    private func next<T: Sendable>(_ stream: AsyncStream<T>) async -> T? {
        await withTaskGroup(of: T?.self) { group in
            group.addTask { var iterator = stream.makeAsyncIterator(); return await iterator.next() }
            group.addTask { try? await Task.sleep(for: .seconds(2)); return nil }
            let result = await group.next() ?? nil
            group.cancelAll()
            return result
        }
    }
}

private struct FeedFixture {
    let link: InMemorySSHLink
    let channels: AsyncStream<Channel>
    let host: FeedHost
    let shells: RequestCounter

    static func make(legacy: Bool = false, stallAfter: Int = .max) async throws -> FeedFixture {
        let (channels, continuation) = AsyncStream<Channel>.makeStream()
        let shells = RequestCounter()
        let paneRequests = RequestCounter()
        let link = try await InMemorySSHLink.make { child in
            try child.pipeline.syncOperations.addHandler(FeedAcceptor(accepted: { continuation.yield($0) }, shells: shells, legacy: legacy, paneRequests: paneRequests, stallAfter: stallAfter))
        }
        return FeedFixture(link: link, channels: channels, host: FeedHost(link: link), shells: shells)
    }
}

private struct FeedHost: PanesStateDriverMaking {
    let link: InMemorySSHLink
    func makePanesStateDriver(originAware: Bool) async throws -> any PanesStateSubscriptionDriver {
        PanesStateChannelClient(parentChannel: link.client, parentHandler: link.clientHandler,
                                subsystemName: originAware ? SSHChannelTypeNames.panesStateV2 : SSHChannelTypeNames.panesState,
                                requestReply: true, onSnapshot: { _ in }, onClosed: { _ in })
    }
}

private final class FeedAcceptor: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = SSHChannelData
    typealias OutboundOut = SSHChannelData
    let accepted: @Sendable (Channel) -> Void
    let shells: RequestCounter
    private var isTerminal = false
    let legacy: Bool
    let paneRequests: RequestCounter
    let stallAfter: Int
    init(accepted: @escaping @Sendable (Channel) -> Void, shells: RequestCounter, legacy: Bool,
         paneRequests: RequestCounter, stallAfter: Int) {
        self.accepted = accepted
        self.shells = shells
        self.legacy = legacy
        self.paneRequests = paneRequests
        self.stallAfter = stallAfter
    }
    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if let request = event as? SSHChannelRequestEvent.SubsystemRequest {
            if legacy, request.subsystem == SSHChannelTypeNames.panesStateV2 {
                context.triggerUserOutboundEvent(ChannelFailureEvent(), promise: nil)
                return
            }
            do {
                let pipeline = context.channel.pipeline.syncOperations
                try pipeline.addHandler(SSHChannelDataCodec())
                try pipeline.addHandler(LengthPrefixedFraming.makeFrameDecoder())
                try pipeline.addHandler(LengthPrefixedFraming.makeFramePrepender())
                try pipeline.addHandler(FeedRPCResponder(subsystem: request.subsystem))
                let isPanes = request.subsystem == SSHChannelTypeNames.panesState || request.subsystem == SSHChannelTypeNames.panesStateV2
                if isPanes { paneRequests.increment() }
                if request.wantReply, !isPanes || paneRequests.count <= stallAfter {
                    context.triggerUserOutboundEvent(ChannelSuccessEvent(), promise: nil)
                }
                if isPanes { accepted(context.channel) }
            } catch { context.close(promise: nil) }
        } else if event is SSHChannelRequestEvent.ShellRequest {
            isTerminal = true
            shells.increment()
            context.triggerUserOutboundEvent(ChannelSuccessEvent(), promise: nil)
        } else { context.fireUserInboundEventTriggered(event) }
    }
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        if isTerminal {
            // The terminal child has no framing handlers. Echo both channel
            // bytes and stderr ownership frames without opening a new shell.
            context.writeAndFlush(data, promise: nil)
        } else { context.fireChannelRead(data) }
    }
}

private final class FeedRPCResponder: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer
    let subsystem: String
    init(subsystem: String) { self.subsystem = subsystem }
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let bytes = Data(unwrapInboundIn(data).readableBytesView)
        let response: Data?
        if subsystem == SSHChannelTypeNames.team,
           let request = try? JSONDecoder().decode(TeamRPCEnvelope.self, from: bytes) {
            response = try? JSONEncoder().encode(TeamRPCEnvelope(kind: .response, requestID: request.requestID, payload: request.payload))
        } else if subsystem == SSHChannelTypeNames.paneControl {
            response = try? JSONEncoder().encode(PaneControlResponse.ok)
        } else { response = nil }
        if let response { context.writeAndFlush(wrapOutboundOut(context.channel.allocator.buffer(bytes: response)), promise: nil) }
    }
}
