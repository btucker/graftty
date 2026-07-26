import Foundation
import NIO
import NIOEmbedded
import Testing
@testable import GrafttyRemoteClient
import WebRTC

@Suite("SSHNIOTransport unit tests — partial-write closes channel.")
struct SSHNIOTransportUnitTests {

    @Test("@spec SSH-1.1: When `RTCDataChannel.sendData` returns false mid-loop in `OutboundRelayHandler.write` (SCTP backpressure on a multi-slice write), the handler shall close both the DataChannel AND the NIO embedded channel — the peer cannot safely continue interpreting bytes after a partial SSH frame.")
    func partialWriteAbortsAndClosesChannel() async throws {
        final class FakeSink: DataChannelSink, @unchecked Sendable {
            var sinkReadyState: RTCDataChannelState = .open
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
}
