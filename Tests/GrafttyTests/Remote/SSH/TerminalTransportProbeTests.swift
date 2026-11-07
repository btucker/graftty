#if os(macOS)
import CryptoKit
import Foundation
import GrafttyHostAgent
import GrafttyKit
import GrafttyProtocol
import GrafttyRemoteClient
import Testing

/// The same production SSH client and handler used on Mac and mobile. These
/// loopback measurements isolate transport costs; they do not measure Ethernet,
/// signaling services, native parsing, or display presentation.
@Suite(.serialized)
struct TerminalTransportProbeTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["GRAFTTY_TERMINAL_FLOW_PROBES"] != nil),
          .timeLimit(.minutes(3)), arguments: [false, true])
    func probeDirectAndWebRTC(direct: Bool) async throws {
        let hostKey = Curve25519.Signing.PrivateKey()
        let clientKey = Curve25519.Signing.PrivateKey()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = TrustedPeerStore(directory: directory)
        let peer = TrustedPeer(id: .init(value: "transport-probe"), kind: .mac,
            publicKey: try .init(rawRepresentation: clientKey.publicKey.rawRepresentation),
            displayName: "probe", capabilities: .defaultsAfterPairing, pairedAt: Date(), lastSeenAt: nil)
        try store.add(peer)
        let fingerprint = RemoteIdentityFingerprint(of: try .init(rawRepresentation: hostKey.publicKey.rawRepresentation))
        let factory: @Sendable (String) async throws -> GrafttyKit.TerminalByteStream = { TransportProbeStream(bulk: $0 == "bulk") }
        let open: @Sendable (String) async throws -> TerminalSessionClient
        let close: @Sendable () async -> Void
        let started = ContinuousClock.now
        if direct {
            let host = DirectSSHHostServer(hostKey: hostKey, trustedPeerStore: store,
                streamFactory: factory, panesStateSubscribe: { _ in .init {} },
                paneControlMutator: { _ in .ok }, displayOwnershipStore: SessionDisplayOwnershipStore())
            let client = DirectSSHHostConnection(clientKey: clientKey, expectedHostFingerprint: fingerprint)
            do {
                let port = try await host.start(host: "127.0.0.1", port: 0)
                try await client.connect(host: "127.0.0.1", port: port)
            } catch { await client.close(); await host.close(); throw error }
            open = { try await client.openTerminalSession(sessionName: $0) }
            close = { await client.close(); await host.close() }
        } else {
            let host = WebRTCHostAgent(hostKey: hostKey, trustedPeerStore: store,
                streamFactory: factory, panesStateSubscribe: { _ in .init {} },
                paneControlMutator: { _ in .ok }, displayOwnershipStore: SessionDisplayOwnershipStore())
            let client = RemoteHostConnection(clientKey: clientKey, expectedHostFingerprint: fingerprint)
            do {
                let offer = try await client.createOffer()
                let answer = try await host.acceptOffer(offer, clientDeviceID: peer.id)
                try await client.applyAnswer(answer)
            } catch { await client.close(); await host.close(); throw error }
            open = { try await client.openTerminalSession(sessionName: $0) }
            close = { await client.close(); await host.close() }
        }
        let watchdog = Task {
            do { try await Task.sleep(for: .seconds(60)) } catch { return }
            await close()
        }
        defer { watchdog.cancel() }
        do {
            let echo = try await open("echo")
            defer { echo.close() }
            let setup = Self.milliseconds(started.duration(to: .now))
            for load in ["idle", "streamingSibling", "stalledSibling"] {
                let bulk = load == "idle" ? nil : try await open("bulk")
                let reader = load == "streamingSibling" ? Task {
                    do { while !Task.isCancelled { _ = try await bulk?.receive() } } catch {}
                } : nil
                defer { reader?.cancel(); bulk?.close() }
                try await Task.sleep(for: .milliseconds(50))
                var samples: [Double] = []
                for sequence in 0..<110 {
                    let bytes = Data("echo-\(sequence)".utf8)
                    let start = ContinuousClock.now
                    try await echo.send(.binary(bytes))
                    #expect(try await echo.receive() == .binary(bytes))
                    if sequence >= 10 { samples.append(Self.milliseconds(start.duration(to: .now))) }
                    try await Task.sleep(for: .milliseconds(2))
                }
                samples.sort()
                print("[transport-probe] direct=\(direct) load=\(load) setupMs=\(setup) samples=\(samples.count) p50Ms=\(samples[49]) p95Ms=\(samples[94]) maxMs=\(samples[99])")
            }
        } catch { await close(); throw error }
        await close()
    }

    private static func milliseconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
    }
}

private final class TransportProbeStream: GrafttyKit.TerminalByteStream, @unchecked Sendable {
    let inboundBytes: AsyncStream<Data>
    private let continuation: AsyncStream<Data>.Continuation?
    private let lock = NSLock()
    private var closed = false

    init(bulk: Bool) {
        if bulk {
            continuation = nil
            let bytes = Data(repeating: 0x78, count: 64 * 1024)
            inboundBytes = AsyncStream(unfolding: { Task.isCancelled ? nil : bytes })
        } else {
            let pair = AsyncStream<Data>.makeStream(bufferingPolicy: .bufferingOldest(16))
            inboundBytes = pair.stream
            continuation = pair.continuation
        }
    }

    func send(_ bytes: Data) async throws {
        guard !lock.withLock({ closed }), let continuation,
              case .enqueued = continuation.yield(bytes) else { throw CancellationError() }
    }
    func close() async {
        lock.withLock { closed = true }
        continuation?.finish()
    }
}
#endif
