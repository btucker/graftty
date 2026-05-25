#if canImport(UIKit)
import Foundation
import NIO
import NIOEmbedded
import Testing
@testable import GrafttyMobileKit
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
}
#endif
