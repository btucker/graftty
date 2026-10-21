import Foundation
import Testing
import WebRTC
import GrafttyTunnel

@Suite("SSH-over-DataChannel transport close propagation")
struct SSHNIOTransportCloseTests {
    @Test("@spec SSH-1.8: When the NIO channel of an SSH-over-DataChannel transport closes, the host and the client shall close the underlying WebRTC DataChannel at once rather than wait for the transport owner to observe the closure.")
    func closingNIOChannelClosesDataChannel() async throws {
        let factory = RTCPeerConnectionFactory(encoderFactory: nil, decoderFactory: nil)
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        let pc = try #require(factory.peerConnection(
            with: RTCConfiguration(),
            constraints: constraints,
            delegate: nil
        ))
        defer { pc.close() }
        let dc = try #require(pc.dataChannel(forLabel: "close-propagation", configuration: RTCDataChannelConfiguration()))
        defer { dc.close() }
        #expect(dc.readyState == .connecting)

        let transport = SSHNIOTransport(dataChannel: dc)
        try await transport.channel.close().get()

        // The close-future callback runs on the transport's loop before
        // `get()` resumes, so no wall-clock wait is needed.
        #expect(dc.readyState == .closing || dc.readyState == .closed)
        // Join the embedded teardown before the deferred native closes,
        // matching `SSHNIOTransportUnitTests.pendingInboundCapClosesTransport`.
        await transport.close()
    }
}
