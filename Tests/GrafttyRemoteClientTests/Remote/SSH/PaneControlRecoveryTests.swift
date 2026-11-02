import Foundation
import GrafttyProtocol
import GrafttyTunnel
import NIOCore
import NIOSSH
import Testing
@testable import GrafttyRemoteClient

@Suite("Pane-control reply correlation", .timeLimit(.minutes(1)))
struct PaneControlRecoveryTests {
    @Test("@spec REMOTE-11.25: When a pane-control RPC times out, the client shall invalidate its channel before resuming the caller and send later mutations on a fresh channel so a late reply cannot answer another request.", arguments: [false, true])
    func timeoutDiscardsLateReplyAndReopens(lateReplyBeforeNextRequest: Bool) async throws {
        let host = GatedPaneControlHost()
        let link = try await InMemorySSHLink.make(serverChild: { try host.install($0) })
        let clock = ManualReplyDeadline()
        let driver = PaneControlChannelClient(
            parentChannel: link.client, parentHandler: link.clientHandler,
            responseDeadline: clock.deadline
        )
        // Exercise the same serial facade used by both Mac and mobile.
        let client = PaneControlClient(driver: driver)
        try await withCancellationCleanup(driver: driver, link: link) {
            try await client.open()
            let outcomes = Task {
                do {
                    _ = try await client.equalize(target: "first")
                    Issue.record("expected timeout")
                } catch {
                    guard case PaneControlChannelClient.ClientError.timedOut = error else { throw error }
                }
                if lateReplyBeforeNextRequest {
                    await host.reply(to: 0, with: .error(code: "stale", message: "first reply"))
                }
                // Issue the next mutation immediately after the timeout resumes
                // this caller, without a test-task scheduling gap.
                return try await client.equalize(target: "second")
            }
            try await host.waitForRequests(1)
            try #require(clock.isArmed)
            clock.fire()
            try await host.waitForRequests(2)
            if !lateReplyBeforeNextRequest {
                await host.reply(to: 0, with: .error(code: "stale", message: "first reply"))
            }
            await host.reply(to: 1, with: .ok)
            let response = try await outcomes.value
            #expect(response == .ok)
            let third = Task { try await client.equalize(target: "third") }
            try await host.waitForRequests(3)
            await host.reply(to: 2, with: .ok)
            let thirdResponse = try await third.value
            #expect(thirdResponse == .ok)
            #expect(host.channelCount == 2)
            #expect(await host.firstChannelIsClosed())
            #expect(link.client.isActive)
            await client.close()
        }
    }

    @Test("an explicit close after timeout prevents recovery")
    func closePreventsRecovery() async throws {
        let host = GatedPaneControlHost()
        let link = try await InMemorySSHLink.make(serverChild: { try host.install($0) })
        let clock = ManualReplyDeadline()
        let driver = PaneControlChannelClient(
            parentChannel: link.client, parentHandler: link.clientHandler,
            responseDeadline: clock.deadline
        )
        try await withCancellationCleanup(driver: driver, link: link) {
            try await driver.open()
            let first = Task { try await driver.send(.equalize(target: "first")) }
            try await host.waitForRequests(1)
            try #require(clock.isArmed)
            clock.fire()
            _ = await first.result
            driver.close()
            do {
                _ = try await driver.send(.equalize(target: "after-close"))
                Issue.record("expected channelClosed")
            } catch {
                guard case PaneControlChannelClient.ClientError.channelClosed = error else { throw error }
            }
            #expect(host.channelCount == 1)
        }
    }

    @Test("direct caller cancellation keeps the RPC busy until its reply is consumed")
    func directCancellationPreservesPairing() async throws {
        let host = GatedPaneControlHost()
        let link = try await InMemorySSHLink.make(serverChild: { try host.install($0) })
        let clock = ManualReplyDeadline()
        let driver = PaneControlChannelClient(
            parentChannel: link.client, parentHandler: link.clientHandler,
            responseDeadline: clock.deadline
        )
        try await withCancellationCleanup(driver: driver, link: link) {
            try await driver.open()
            let first = Task { try await driver.send(.equalize(target: "first")) }
            try await host.waitForRequests(1)
            first.cancel()
            do {
                _ = try await driver.send(.equalize(target: "while-busy"))
                Issue.record("expected busy")
            } catch {
                guard case PaneControlChannelClient.ClientError.busy = error else { throw error }
            }
            await host.reply(to: 0, with: .error(code: "first", message: "cancelled caller's reply"))
            let firstResponse = try await first.value
            #expect(firstResponse == .error(code: "first", message: "cancelled caller's reply"))
            let second = Task { try await driver.send(.equalize(target: "second")) }
            try await host.waitForRequests(2)
            await host.reply(to: 1, with: .ok)
            let response = try await second.value
            #expect(response == .ok)
            #expect(host.channelCount == 1)
            driver.close()
        }
    }

    @Test("@spec REMOTE-11.26: When a pane-control caller is cancelled while awaiting a reply, the client shall consume that reply before sending a later mutation so cancellation cannot shift reply pairing.")
    func cancellationConsumesReplyBeforeNextMutation() async throws {
        let host = GatedPaneControlHost()
        let link = try await InMemorySSHLink.make(serverChild: { try host.install($0) })
        let clock = ManualReplyDeadline()
        let driver = PaneControlChannelClient(
            parentChannel: link.client, parentHandler: link.clientHandler,
            responseDeadline: clock.deadline
        )
        let client = PaneControlClient(driver: driver)
        try await withCancellationCleanup(driver: driver, link: link) {
            try await client.open()
            let first = Task { try await client.equalize(target: "first") }
            try await host.waitForRequests(1)
            first.cancel()
            let second = Task { try await client.equalize(target: "second") }
            await host.reply(to: 0, with: .error(code: "first", message: "cancelled caller's reply"))
            #expect(try await first.value == .error(code: "first", message: "cancelled caller's reply"))
            try await host.waitForRequests(2)
            await host.reply(to: 1, with: .ok)
            let response = try await second.value
            #expect(response == .ok)
            #expect(host.channelCount == 1)
            await client.close()
        }
    }
}

/// Close even when a manual-clock RPC is stuck at Task.value: that wait
/// ignores cancellation, so an async defer alone cannot unblock the test.
private func withCancellationCleanup(
    driver: PaneControlChannelClient,
    link: InMemorySSHLink,
    operation: () async throws -> Void
) async throws {
    do {
        try await withTaskCancellationHandler {
            try await operation()
        } onCancel: {
            driver.close()
            Task { await link.close() }
        }
    } catch {
        driver.close()
        await link.close()
        throw error
    }
    driver.close()
    await link.close()
}

/// Keeps server child channels and request frames so tests can release each
/// reply independently, including an attempted write on a timed-out child.
private final class GatedPaneControlHost: @unchecked Sendable {
    private let lock = NSLock()
    private var children: [Channel] = []
    private var requests: [Channel] = []
    private let received = RequestCounter()

    func waitForRequests(_ count: Int) async throws {
        while received.count < count {
            try Task.checkCancellation()
            await Task.yield()
        }
    }

    var channelCount: Int { lock.withLock { children.count } }

    func install(_ child: Channel) throws {
        lock.withLock { children.append(child) }
        let pipeline = child.pipeline.syncOperations
        try pipeline.addHandler(SSHChannelDataCodec())
        try pipeline.addHandler(LengthPrefixedFraming.makeFrameDecoder())
        try pipeline.addHandler(LengthPrefixedFraming.makeFramePrepender())
        try pipeline.addHandler(Handler(host: self))
    }

    func firstChannelIsClosed() async -> Bool {
        let child = lock.withLock { children[0] }
        return (try? await child.eventLoop.submit { !child.isActive }.get()) ?? false
    }

    func reply(to index: Int, with response: PaneControlResponse) async {
        let child = lock.withLock { requests[index] }
        let bytes = try! JSONEncoder().encode(response)
        // A poisoned channel rejects the old host reply. Reusing that child
        // instead delivers the stale response to the second continuation.
        _ = try? await child.writeAndFlush(child.allocator.buffer(bytes: bytes)).get()
    }

    private final class Handler: ChannelInboundHandler, @unchecked Sendable {
        typealias InboundIn = ByteBuffer
        private let host: GatedPaneControlHost
        init(host: GatedPaneControlHost) { self.host = host }

        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            host.lock.withLock { host.requests.append(context.channel) }
            host.received.increment()
        }

        func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
            if let request = event as? SSHChannelRequestEvent.SubsystemRequest, request.wantReply {
                context.triggerUserOutboundEvent(ChannelSuccessEvent(), promise: nil)
            } else {
                context.fireUserInboundEventTriggered(event)
            }
        }
    }
}
