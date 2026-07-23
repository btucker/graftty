#if os(macOS)
import CryptoKit
import Foundation
import GrafttyHostAgent
import GrafttyKit
import GrafttyProtocol
import GrafttyRemoteClient
import Testing
import WebRTC

@Suite("Mac-to-Mac SSH-over-WebRTC loopback", .serialized)
struct RemoteMacConnectionLoopbackTests {
    // Keep native libwebrtc opt-in on macOS: initializing its worker threads
    // can prevent headless GitHub runners from exiting after the tests finish.
    // A real Mac can run this gate with:
    // GRAFTTY_RUN_WEBRTC_LOOPBACK=1 swift test --filter RemoteMacConnectionLoopbackTests
    @Test(
        .enabled(
            if: ProcessInfo.processInfo.environment["GRAFTTY_RUN_WEBRTC_LOOPBACK"] == "1",
            "Set GRAFTTY_RUN_WEBRTC_LOOPBACK=1 to run the native WebRTC smoke test."
        ),
        .timeLimit(.minutes(1))
    )
    func terminalRoundTripThroughLANSignalingAndHostAgent() async throws {
        let clientDeviceID = RemoteDeviceID(value: "mac-loopback-client")
        let clientKey = Curve25519.Signing.PrivateKey()
        let hostKey = Curve25519.Signing.PrivateKey()
        let hostFingerprint = RemoteIdentityFingerprint(
            of: try RemoteIdentityPublicKey(
                rawRepresentation: hostKey.publicKey.rawRepresentation
            )
        )
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("graftty-mac-webrtc-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let trustedPeerStore = TrustedPeerStore(
            directory: directory.appendingPathComponent("trusted-peers", isDirectory: true)
        )
        try trustedPeerStore.add(
            TrustedPeer(
                id: clientDeviceID,
                kind: .mac,
                publicKey: try RemoteIdentityPublicKey(
                    rawRepresentation: clientKey.publicKey.rawRepresentation
                ),
                displayName: "Loopback Client",
                capabilities: .defaultsAfterPairing,
                pairedAt: Date(),
                lastSeenAt: nil
            )
        )

        let hostAgent = WebRTCHostAgent(
            hostKey: hostKey,
            trustedPeerStore: trustedPeerStore,
            streamFactory: { _ in EchoTerminalStream() },
            panesStateSubscribe: { onChange in
                await onChange([])
                return PanesStateChannelHandler.Cancellable(cancel: {})
            },
            paneControlMutator: { _ in .ok },
            displayOwnershipStore: SessionDisplayOwnershipStore()
        )
        let routeHandler = LANRemoteAccessRouteHandler(
            lanBaseURLProvider: { URL(string: "http://127.0.0.1")! },
            beginPairing: { _, _ in Self.unusedPairingResult() },
            handleIntroduce: { _ in Self.unusedIntroduceResult() },
            handleAwaitOutcome: { _ in Self.unusedOutcomeResult() },
            handleSignalingOffer: { offer in
                do {
                    let answer = try await hostAgent.acceptOffer(
                        RTCSessionDescription(type: .offer, sdp: offer.sdp)
                    )
                    return .success(SignalingAnswer(sdp: answer.sdp))
                } catch WebRTCHostAgent.HostError.busy {
                    return .hostBusy("host already has an active connection")
                } catch {
                    return .internalFailure(String(describing: error))
                }
            }
        )
        let server = LANRemoteAccessServer(
            config: .init(port: 0, bindHost: "127.0.0.1"),
            routeHandler: routeHandler
        )
        try server.start()
        guard let port = server.listeningPort else {
            server.stop()
            Issue.record("LAN signaling server did not expose a listening port")
            return
        }

        let connection = RemoteHostConnection(
            clientKey: clientKey,
            expectedHostFingerprint: hostFingerprint
        )
        var terminal: TerminalSessionClient?
        do {
            let offer = try await connection.createOffer()
            let answer = try await SignalingClient().exchange(
                baseURL: URL(string: "http://127.0.0.1:\(port)")!,
                offer: SignalingOffer(
                    clientDeviceID: clientDeviceID.value,
                    sdp: offer.sdp
                )
            )
            try await connection.applyAnswer(
                RTCSessionDescription(type: .answer, sdp: answer.sdp)
            )

            let openedTerminal = try await connection.openTerminalSession(
                sessionName: "loopback-session"
            )
            terminal = openedTerminal
            let payload = Data("mac-to-mac-webrtc".utf8)
            try await openedTerminal.send(.binary(payload))
            let frame = try await Self.receiveWithTimeout(openedTerminal)

            #expect(frame == .binary(payload))
            #expect(await connection.state == RemoteHostConnection.State.connected)
            #expect(await hostAgent.state == WebRTCHostAgent.State.connected)
        } catch {
            terminal?.close()
            await connection.close()
            await hostAgent.close()
            server.stop()
            throw error
        }

        terminal?.close()
        await connection.close()
        await hostAgent.close()
        server.stop()
    }

    private static func receiveWithTimeout(
        _ terminal: TerminalSessionClient
    ) async throws -> WebSocketFrame {
        let timeout = Task {
            try? await Task.sleep(for: .seconds(10))
            guard !Task.isCancelled else { return }
            terminal.close()
        }
        defer { timeout.cancel() }
        return try await terminal.receive()
    }

    private static func unusedPairingResult() -> Result<PairingPayload, PairingErrorResponse> {
        .failure(PairingErrorResponse(code: .noActiveSession, error: "unused by signaling test"))
    }

    private static func unusedIntroduceResult() -> Result<PairingIntroduceResponse, PairingErrorResponse> {
        .failure(PairingErrorResponse(code: .noActiveSession, error: "unused by signaling test"))
    }

    private static func unusedOutcomeResult() -> Result<PairingOutcomeResponse, PairingErrorResponse> {
        .failure(PairingErrorResponse(code: .noActiveSession, error: "unused by signaling test"))
    }
}

private final class EchoTerminalStream: GrafttyKit.TerminalByteStream, @unchecked Sendable {
    private let continuation: AsyncStream<Data>.Continuation
    let inboundBytes: AsyncStream<Data>

    init() {
        var continuation: AsyncStream<Data>.Continuation!
        inboundBytes = AsyncStream { continuation = $0 }
        self.continuation = continuation
    }

    func send(_ bytes: Data) async throws {
        continuation.yield(bytes)
    }

    func close() async {
        continuation.finish()
    }
}
#endif
