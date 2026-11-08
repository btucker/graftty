import Foundation
import CryptoKit
import GrafttyProtocol
import NIO
import NIOEmbedded
import Testing
@testable import GrafttyRemoteClient
@testable import GrafttyTunnel
import WebRTC

@Suite("SSHNIOTransport unit tests — partial-write closes channel.")
struct SSHNIOTransportUnitTests {
    @Test("@spec SSH-1.12: When native WebRTC teardown begins, the application shall run it once outside Swift tasks, release detached resources before resuming its waiters, and finish cleanup even if a waiter is cancelled.", .timeLimit(.minutes(1)))
    func nativeShutdownJoinsAndReleasesBeforeReturning() async {
        let result = ShutdownProbe()
        let entered = AsyncStream<Void>.makeStream()
        let release = DispatchSemaphore(value: 0)
        let shutdown = makeShutdown(result: result, entered: entered.continuation, release: release)
        let first = Task { await shutdown.run(); return result.snapshot.released }
        var events = entered.stream.makeAsyncIterator()
        await events.next()
        let second = Task { await shutdown.run(); return result.snapshot.released }
        first.cancel()
        release.signal()
        #expect(await first.value)
        #expect(await second.value)
        let snapshot = result.snapshot
        #expect(snapshot.calls == 1)
        #expect(snapshot.outsideTask)
        #expect(snapshot.releaseOutsideTask)
        #expect(snapshot.callbackFinished)
    }

    private func makeShutdown(
        result: ShutdownProbe,
        entered: AsyncStream<Void>.Continuation,
        release: DispatchSemaphore
    ) -> WebRTCShutdown {
        let resource = ReleaseProbeSink { outsideTask in result.recordRelease(outsideTask) }
        return WebRTCShutdown {
            result.recordCall(withUnsafeCurrentTask { $0 == nil })
            entered.yield(())
            // Model native shutdown waiting for a GCD event-log callback.
            let callback = DispatchSemaphore(value: 0)
            DispatchQueue.global().async { callback.signal() }
            result.recordCallback(callback.wait(timeout: .now() + 5) == .success)
            #expect(release.wait(timeout: .now() + 5) == .success)
            withExtendedLifetime(resource) {}
        }
    }

    @Test("@spec SSH-1.11: When the last SSH data-channel owner is released from a Swift task, the application shall destroy its native channel proxy outside the cooperative executor and release the inbox and relay.", .timeLimit(.minutes(1)))
    func inboxReleaseDestroysNativeSinkOutsideSwiftTask() async {
        let releasedOutsideTask = await withCheckedContinuation { continuation in
            // Reproduce the sampled ownership chain: inbox callback -> relay
            // -> native sink. Drop the final inbox owner on a Swift task.
            var inbox: DataChannelInbox? = makeInboxOwningSink { outsideTask in
                continuation.resume(returning: outsideTask)
            }
            #expect(inbox != nil)
            inbox = nil
        }
        #expect(releasedOutsideTask, "Native proxy destruction can synchronously wait for WebRTC's signaling thread")
    }

    private func makeInboxOwningSink(onRelease: @escaping @Sendable (Bool) -> Void) -> DataChannelInbox {
        let sink = ReleaseProbeSink(onRelease: onRelease)
        let relay = OutboundRelayHandler(sink: sink, mtu: 4)
        let inbox = DataChannelInbox()
        inbox.attach(onOpen: {}, onClose: {}, onMessage: { _ in }, onBufferedAmountChange: {
            withExtendedLifetime(relay) {}
        })
        return inbox
    }

    @Test("Diagnostic snapshots retain an SDK buffer peak after it drains")
    func snapshotsRetainObservedBufferedPeak() async throws {
        let sink = BufferedSink()
        let relay = OutboundRelayHandler(sink: sink, mtu: 4, bufferedByteLimit: 8)
        let loop = NIOAsyncTestingEventLoop()
        try await loop.submit {
            sink.sinkBufferedAmount = 12
            #expect(relay.sendDiagnostics.peakBufferedBytes == 12)
            sink.sinkBufferedAmount = 0
            #expect(relay.sendDiagnostics.peakBufferedBytes == 12)
        }.get()
    }

    @Test("@spec SSH-1.9: While an SSH-over-WebRTC transport is active or closed, the application shall expose bounded numeric send diagnostics for queued bytes, WebRTC buffering, completed and failed writes, and local write-admission delay without retaining payloads.")
    func sendDiagnosticsMeasureAdmissionAndReleaseFailures() async throws {
        let sink = BufferedSink()
        let clock = ProbeClock()
        let loop = NIOAsyncTestingEventLoop()
        let channel = NIOAsyncTestingChannel(loop: loop)
        let relay = OutboundRelayHandler(sink: sink, mtu: 4, bufferedByteLimit: 8,
                                        pendingByteLimit: 32, diagnosticNow: { clock.now })
        try await loop.submit { try channel.pipeline.syncOperations.addHandler(relay) }.get()
        try await channel.connect(to: .init(unixDomainSocketPath: "diagnostics")).get()
        defer { channel.close(promise: nil) }
        let first: EventLoopFuture<Void> = channel.writeAndFlush(channel.allocator.buffer(bytes: [UInt8](repeating: 1, count: 12)))
        try await loop.submit { clock.now = 10_000_000 }.get()
        let second: EventLoopFuture<Void> = channel.writeAndFlush(channel.allocator.buffer(bytes: [UInt8](repeating: 2, count: 2)))
        try await loop.submit {
            let blocked = relay.sendDiagnostics
            #expect(blocked.acceptedBytes == 14)
            #expect(blocked.submittedBytes == 8)
            #expect(blocked.pendingBytes == 6)
            #expect(blocked.peakPendingBytes == 12)
            #expect(blocked.bufferedBytes == 8)
            #expect(blocked.peakBufferedBytes == 8)
            #expect(blocked.completedWrites == 0)
            #expect(blocked.meanAdmissionMilliseconds == nil)
            clock.now = 30_000_000
            sink.sinkBufferedAmount = 0
            relay.resumeSending()
            let drained = relay.sendDiagnostics
            #expect(drained.pendingBytes == 0)
            #expect(drained.submittedBytes == 14)
            #expect(drained.completedWrites == 2)
            #expect(drained.meanAdmissionMilliseconds == 25)
            #expect(drained.maxAdmissionMilliseconds == 30)
            sink.sinkBufferedAmount = 8
        }.get()
        try await first.get()
        try await second.get()
        let pending: EventLoopFuture<Void> = channel.writeAndFlush(channel.allocator.buffer(bytes: [UInt8(3)]))
        try await channel.close().get()
        await #expect(throws: (any Error).self) { try await pending.get() }
        try await loop.submit {
            #expect(relay.sendDiagnostics.failedWrites == 1)
            #expect(relay.sendDiagnostics.pendingBytes == 0)
            #expect(relay.sendDiagnostics.completedWrites == 2)
        }.get()
    }


    @Test("@spec SSH-1.3: While the WebRTC send buffer is full, the SSH transport shall defer ordered writes, resume them after draining, and fail pending writes on close.")
    func boundedSendingResumesInOrder() async throws {
        let sink = BufferedSink()
        let loop = NIOAsyncTestingEventLoop()
        let channel = NIOAsyncTestingChannel(loop: loop)
        let relay = OutboundRelayHandler(sink: sink, mtu: 4, bufferedByteLimit: 8, pendingByteLimit: 32)
        try await loop.submit { try channel.pipeline.syncOperations.addHandler(relay) }.get()
        try await channel.connect(to: .init(unixDomainSocketPath: "bounded")).get()
        let first: EventLoopFuture<Void> = channel.writeAndFlush(channel.allocator.buffer(bytes: Array(UInt8(0)..<12)))
        let second: EventLoopFuture<Void> = channel.writeAndFlush(channel.allocator.buffer(bytes: [UInt8(12), 13]))
        try await loop.submit {
            #expect(sink.bytes == Array(0..<8))
            sink.sinkBufferedAmount = 0
            relay.resumeSending()
            #expect(sink.bytes == Array(0..<14))
        }.get()
        try await first.get()
        try await second.get()
        try await loop.submit { sink.sinkBufferedAmount = 8 }.get()
        let pending: EventLoopFuture<Void> = channel.writeAndFlush(channel.allocator.buffer(bytes: [UInt8(99)]))
        try await channel.close().get()
        await #expect(throws: (any Error).self) { try await pending.get() }
    }

    @Test("@spec SSH-1.4: If queued SSH output exceeds its byte limit, then the transport shall close and fail writes without dropping bytes from a live SSH stream.")
    func overflowingPendingOutputClosesTransport() async throws {
        let sink = BufferedSink()
        let loop = NIOAsyncTestingEventLoop()
        let channel = NIOAsyncTestingChannel(loop: loop)
        let relay = OutboundRelayHandler(sink: sink, mtu: 4, bufferedByteLimit: 8, pendingByteLimit: 8)
        try await loop.submit {
            try channel.pipeline.syncOperations.addHandler(relay)
            sink.sinkBufferedAmount = 8
        }.get()
        try await channel.connect(to: .init(unixDomainSocketPath: "bounded")).get()
        let pending: EventLoopFuture<Void> = channel.writeAndFlush(channel.allocator.buffer(bytes: [UInt8](repeating: 1, count: 8)))
        let overflow: EventLoopFuture<Void> = channel.writeAndFlush(channel.allocator.buffer(bytes: [UInt8(2)]))
        await #expect(throws: (any Error).self) { try await overflow.get() }
        await #expect(throws: (any Error).self) { try await pending.get() }
        #expect(!channel.isActive)
        #expect(sink.bytes.isEmpty)
        #expect(sink.closed)
    }

    @Test("@spec REMOTE-11.8: When the SSH parent channel closes, the remote connection shall tear down its WebRTC transport and notify consumers so they can evict the cached connection.")
    func closingParentChannelFailsRemoteConnection() async throws {
        let key = Curve25519.Signing.PrivateKey()
        let publicKey = try RemoteIdentityPublicKey(
            rawRepresentation: key.publicKey.rawRepresentation
        )
        let connection = RemoteHostConnection(
            clientKey: key,
            expectedHostFingerprint: .init(of: publicKey)
        )
        _ = try await connection.createOffer()
        let transport = try #require(await connection.sshTransportForTesting)
        try await transport.channel.close().get()
        let deadline = ContinuousClock.now.advanced(by: .seconds(1))
        while !(await connection.state.isTerminal), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await connection.state.isTerminal)
        #expect(await connection.sshTransportForTesting == nil)
        await connection.close()
        await transport.close()
    }

    @Test("@spec SSH-1.1: When `RTCDataChannel.sendData` returns false mid-loop in `OutboundRelayHandler.write` (SCTP backpressure on a multi-slice write), the handler shall close both the DataChannel AND the NIO embedded channel — the peer cannot safely continue interpreting bytes after a partial SSH frame.")
    func partialWriteAbortsAndClosesChannel() async throws {
        final class FakeSink: DataChannelSink, @unchecked Sendable {
            var sinkReadyState: RTCDataChannelState = .open
            var sinkBufferedAmount: UInt64 = 0
            private(set) var sendCount = 0
            private(set) var closedCount = 0
            var failOnCall: Int?

            func sinkSend(_ buffer: RTCDataBuffer) -> Bool {
                sendCount += 1
                if let failOnCall, sendCount == failOnCall {
                    return false
                }
                return true
            }

            func sinkClose() {
                closedCount += 1
            }
        }

        let sink = FakeSink()
        sink.failOnCall = 2

        let loop = NIOAsyncTestingEventLoop()
        let channel = NIOAsyncTestingChannel(loop: loop)
        let handler = OutboundRelayHandler(sink: sink, mtu: 16 * 1024)
        try await loop.submit {
            try channel.pipeline.syncOperations.addHandler(handler)
        }.get()
        try await channel.connect(to: .init(unixDomainSocketPath: "test")).get()

        // 24KB buffer → splits into 16KB + 8KB; second slice fails.
        var buf = channel.allocator.buffer(capacity: 24 * 1024)
        buf.writeBytes([UInt8](repeating: 0x41, count: 24 * 1024))

        do {
            try await channel.writeAndFlush(buf).get()
            Issue.record("Expected ChannelError.outputClosed")
        } catch ChannelError.outputClosed {
            // expected
        }

        #expect(sink.sendCount == 2)
        #expect(sink.closedCount == 1)
        #expect(!channel.isActive, "channel must close after partial-write failure")
    }

    @Test("@spec SSH-1.2: When `pendingInbound` accumulates more than 1 MiB without the embedded channel becoming active, `SSHNIOTransport` shall close the underlying DataChannel and transition to closed — bounding memory under a flooding peer.")
    func pendingInboundCapClosesTransport() async throws {
        // We need a real-looking RTCDataChannel to construct SSHNIOTransport.
        // Construct via the existing public init and a real factory.
        // Then deliver inbound directly via the test seam — the embedded
        // channel never gets activated because we never call start().
        let pcFactory = RTCPeerConnectionFactory(encoderFactory: nil, decoderFactory: nil)
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        guard let pc = pcFactory.peerConnection(
            with: RemoteHostConnection.defaultConfig(),
            constraints: constraints,
            delegate: nil
        ) else {
            Issue.record("could not create RTCPeerConnection")
            return
        }
        defer { pc.close() }
        let dcConfig = RTCDataChannelConfiguration()
        dcConfig.isOrdered = true
        guard let dc = pc.dataChannel(forLabel: "test-cap", configuration: dcConfig) else {
            Issue.record("could not create RTCDataChannel")
            return
        }
        defer { dc.close() }

        let transport = SSHNIOTransport(dataChannel: dc)

        // Deliver ~1 MiB + 1 KB across small chunks WITHOUT calling start().
        let chunk = Data(repeating: 0x41, count: 1024)
        for _ in 0..<1025 {
            transport.deliverInboundForTesting(chunk)
        }

        // Poll for the embedded loop to drain the 1025 enqueued tasks. On the
        // iOS Simulator under CI load (cooperative pool contending with other
        // tests' Tasks — AsyncStream drains, scheduled deadlines, etc.), a
        // single fixed sleep is fragile. Poll up to 5s; tests typically finish
        // in well under a second.
        let deadline = Date().addingTimeInterval(5.0)
        while transport.pendingInboundByteCountForTesting != 0 {
            if Date() >= deadline { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        // After overflow the transport should have closed itself — assert via
        // the pending byte counter being reset (a successful close resets it).
        #expect(transport.pendingInboundByteCountForTesting == 0,
                "pendingInbound should be flushed when transport closes on cap overflow")
        // Join the embedded NIO teardown before the deferred native WebRTC
        // closes run. Letting the transport deinitialize concurrently with
        // `pc.close()` can deadlock libwebrtc's worker-thread join when this
        // suite shares a Swift Testing process with socket-heavy targets.
        await transport.close()
    }

    @Test("@spec SSH-1.8: When the NIO channel of an SSH-over-DataChannel transport closes, the host and the client shall close the underlying WebRTC DataChannel at once rather than wait for the transport owner to observe the closure.")
    func closingNIOChannelClosesDataChannel() async throws {
        let factory = RTCPeerConnectionFactory(encoderFactory: nil, decoderFactory: nil)
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        let pc = try #require(factory.peerConnection(
            with: RemoteHostConnection.defaultConfig(),
            constraints: constraints,
            delegate: nil
        ))
        defer { pc.close() }
        let dc = try #require(pc.dataChannel(forLabel: "close-propagation", configuration: RTCDataChannelConfiguration()))
        defer { dc.close() }
        #expect(dc.readyState == .connecting)

        let transport = SSHNIOTransport(dataChannel: dc)
        try await transport.channel.close().get()
        // The close promise succeeds before the channel's close future does.
        // The transport registers its close-future callback at construction,
        // so that callback has run once this later registration resumes.
        try await transport.channel.closeFuture.get()

        #expect(dc.readyState == .closing || dc.readyState == .closed)
        // Join the embedded teardown before the deferred native closes,
        // matching `pendingInboundCapClosesTransport`.
        await transport.close()
    }
}

private final class BufferedSink: DataChannelSink, @unchecked Sendable {
    var sinkReadyState: RTCDataChannelState = .open
    var sinkBufferedAmount: UInt64 = 0
    var bytes: [UInt8] = []
    var closed = false
    func sinkSend(_ buffer: RTCDataBuffer) -> Bool {
        bytes.append(contentsOf: buffer.data)
        sinkBufferedAmount += UInt64(buffer.data.count)
        return true
    }
    func sinkClose() { closed = true }
}

private final class ReleaseProbeSink: DataChannelSink, @unchecked Sendable {
    let onRelease: @Sendable (Bool) -> Void
    init(onRelease: @escaping @Sendable (Bool) -> Void) { self.onRelease = onRelease }
    var sinkReadyState: RTCDataChannelState { .closed }
    var sinkBufferedAmount: UInt64 { 0 }
    func sinkSend(_ buffer: RTCDataBuffer) -> Bool { false }
    func sinkClose() {}
    deinit { onRelease(withUnsafeCurrentTask { $0 == nil }) }
}

private final class ShutdownProbe: @unchecked Sendable {
    struct Snapshot {
        var calls = 0
        var outsideTask = false
        var released = false
        var releaseOutsideTask = false
        var callbackFinished = false
    }
    private let lock = NSLock()
    private var value = Snapshot()
    var snapshot: Snapshot { lock.withLock { value } }
    func recordCall(_ outsideTask: Bool) {
        lock.withLock { value.calls += 1; value.outsideTask = outsideTask }
    }
    func recordRelease(_ outsideTask: Bool) {
        lock.withLock { value.released = true; value.releaseOutsideTask = outsideTask }
    }
    func recordCallback(_ finished: Bool) { lock.withLock { value.callbackFinished = finished } }
}

private final class ProbeClock: @unchecked Sendable {
    private let lock = NSLock()
    private var ticks: UInt64 = 0
    var now: UInt64 {
        get { lock.withLock { ticks } }
        set { lock.withLock { ticks = newValue } }
    }
}
