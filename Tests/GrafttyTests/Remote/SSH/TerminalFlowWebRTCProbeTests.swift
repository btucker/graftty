#if os(macOS)
import CryptoKit
import Foundation
@testable import GrafttyHostAgent
import GrafttyKit
import GrafttyProtocol
@testable import GrafttyRemoteClient
import GrafttyRemoteTestSupport
import GrafttyTunnel
import NIOCore
import NIOSSH
import Testing
import WebRTC

/// Real WebRTC, real SSH and the production host handler. Native libwebrtc stays
/// opt-in on macOS, like `RemoteMacConnectionLoopbackTests`. Numeric report only.
@Suite("Terminal flow control over WebRTC", .serialized)
struct TerminalFlowWebRTCProbeTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["GRAFTTY_TERMINAL_FLOW_PROBES"] != nil),
          .timeLimit(.minutes(3)), arguments: [true, false])
    func probeNegotiatedWindowOverWebRTC(negotiated: Bool) async throws {
        let serverKey = Curve25519.Signing.PrivateKey()
        let clientKey = Curve25519.Signing.PrivateKey()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("flow-webrtc-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = TrustedPeerStore(directory: directory)
        let peer = SSHUserAuthTestSupport.makePeer(key: clientKey, kind: .mac)
        try store.add(peer)
        let offerer = LoopbackPeer(role: .offerer)
        let answerer = LoopbackPeer(role: .answerer)
        var transports: [SSHNIOTransport] = []
        func cleanup() async {
            for transport in transports { await transport.close() }
            await offerer.close()
            await answerer.close()
        }
        do {
            let offer = try await offerer.createOffer()
            let answer = try await answerer.accept(offer: offer)
            await offerer.bindIceCandidates(to: answerer)
            await answerer.bindIceCandidates(to: offerer)
            try await offerer.applyAnswer(answer)
            let clientChannel = try await offerer.openedDataChannel(label: "graftty-ssh")
            let serverChannel = try await answerer.openedDataChannel(label: "graftty-ssh")
            let clientTransport = SSHNIOTransport(dataChannel: clientChannel)
            let serverTransport = SSHNIOTransport(dataChannel: serverChannel)
            transports = [clientTransport, serverTransport]
            let source = FlowProbeStream()
            let ownership = SessionDisplayOwnershipStore()
            let broadcaster = DisplayOwnershipBroadcaster()
            let attaches = FlowProbeCounter()
            try await serverTransport.eventLoop.submit {
                let handler = SSHServerSetup.makeHandler(
                    hostKey: serverKey, trustedPeerStore: store, allocator: serverTransport.channel.allocator,
                    inboundChildChannelInitializer: { child, _ in
                        let isBulk = attaches.next() == 0
                        return child.pipeline.addHandler(TerminalSessionHandler(
                            streamFactory: { _ in isBulk ? source : FlowProbeStream() },
                            ownershipStore: ownership, ownershipBroadcaster: broadcaster, deviceID: peer.id
                        ))
                    }
                )
                try serverTransport.channel.pipeline.syncOperations.addHandler(handler)
            }.get()
            let handler = try await clientTransport.eventLoop.submit {
                let handler = SSHClientSetup.makeHandler(
                    clientKey: clientKey,
                    expectedHostFingerprint: .init(of: try RemoteIdentityPublicKey(rawRepresentation: serverKey.publicKey.rawRepresentation)),
                    allocator: clientTransport.channel.allocator
                )
                try clientTransport.channel.pipeline.syncOperations.addHandler(handler)
                return FlowProbeHandlerBox(handler: handler)
            }.get().handler
            try await serverTransport.start()
            try await clientTransport.start()
            func client() -> TerminalSessionClient {
                TerminalSessionClient(parentChannel: clientTransport.channel, parentHandler: handler, sessionName: "flow",
                                      outputWindowBytes: negotiated ? TerminalOutputCredit.clientWindowBytes : nil)
            }
            let bulk = client()
            let other = client()
            defer { bulk.close(); other.close() }
            // SSH authentication finishes in the background of the first open.
            try await bulk.connect()
            try await other.connect()
            await bulk.sendHello(clientID: DisplayClientID("bulk"), kind: .ios, role: .interactive, visible: true, cols: 80, rows: 24)

            func seconds(_ duration: Duration) -> Double {
                Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
            }
            let keepingUp = 64 * 1024 * 1024
            let start = ContinuousClock.now
            let producer = source.produce(bytes: keepingUp)
            defer { producer.cancel() }
            var received = 0
            while received < keepingUp {
                if case .binary(let bytes) = try await bulk.receive() { received += bytes.count }
            }
            await producer.value
            let keepingUpSeconds = seconds(start.duration(to: .now))
            let server = await serverTransport.sendDiagnostics()

            // A slow consumer behind a backlog, then a takeover behind that.
            let slow = source.produce(bytes: 32 * 1024 * 1024)
            defer { slow.cancel() }
            try await Task.sleep(for: .seconds(2))
            let takeoverStart = ContinuousClock.now
            await other.sendHello(clientID: DisplayClientID("other"), kind: .ios, role: .interactive, visible: true, cols: 80, rows: 24)
            await other.takeControl(clientID: DisplayClientID("other"), kind: .ios, cols: 90, rows: 30)
            let consumerRate = 2.0 * 1024 * 1024
            var ahead = 0
            reading: while true {
                switch try await bulk.receive() {
                case .binary(let bytes):
                    ahead += bytes.count
                    try await Task.sleep(for: .seconds(Double(bytes.count) / consumerRate))
                case .paged: throw PagedTerminalEnvelope.Error.invalid
                case .text(let text):
                    if case .ownership(let snapshot)? = try? WebControlEnvelope.parse(Data(text.utf8)),
                       snapshot.grid.cols == 90 { break reading }
                }
            }
            print("[terminal-flow] {\"scenario\":\"webrtcProductionHost\",\"negotiated\":\(negotiated),\"keepingUpMegabytesPerSecond\":\(Double(keepingUp) / 1_048_576 / keepingUpSeconds),\"serverPeakPendingBytes\":\(server.peakPendingBytes),\"serverPeakBufferedBytes\":\(server.peakBufferedBytes),\"bytesAheadOfTakeover\":\(ahead),\"takeoverSeconds\":\(seconds(takeoverStart.duration(to: .now)))}")
            #expect(server.failedWrites == 0)
            slow.cancel()
            bulk.close()
            other.close()
        } catch {
            await cleanup()
            throw error
        }
        await cleanup()
    }
}

private struct FlowProbeHandlerBox: @unchecked Sendable { let handler: NIOSSHHandler }

private final class FlowProbeCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func next() -> Int { lock.withLock { defer { value += 1 }; return value } }
}

private final class FlowProbeStream: GrafttyKit.TerminalByteStream, @unchecked Sendable {
    let inboundBytes: AsyncStream<Data>
    private let continuation: AsyncStream<Data>.Continuation

    init() {
        let pair = AsyncStream<Data>.makeStream(bufferingPolicy: .bufferingOldest(1))
        inboundBytes = pair.stream
        continuation = pair.continuation
    }

    func produce(bytes: Int) -> Task<Void, Never> {
        Task { [continuation] in
            let chunk = Data(repeating: 0x78, count: 64 * 1024)
            var sent = 0
            while sent < bytes, !Task.isCancelled {
                switch continuation.yield(chunk) {
                case .enqueued: sent += chunk.count
                case .dropped: try? await Task.sleep(for: .milliseconds(1))
                default: return
                }
            }
        }
    }

    func send(_ bytes: Data) async throws {}
    func close() async { continuation.finish() }
}
#endif
