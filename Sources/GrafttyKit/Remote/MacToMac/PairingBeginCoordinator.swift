import Foundation
import GrafttyProtocol

/// Serializes LAN pairing begin requests before they reach
/// `HostPairingServer.start(validFor:)`, which otherwise restarts an
/// active pairing session.
public actor PairingBeginCoordinator {
    private let server: HostPairingServer
    private var startInFlight = false

    public init(server: HostPairingServer) {
        self.server = server
    }

    public func startIfIdle(
        validFor: TimeInterval,
        lanBaseURL: URL
    ) async -> Result<PairingPayload, PairingErrorResponse> {
        guard !startInFlight else {
            return .failure(Self.busyError())
        }
        startInFlight = true
        defer { startInFlight = false }

        await server.tick()
        let state = await server.currentState()
        guard !Self.isActivePairingState(state) else {
            return .failure(Self.busyError())
        }

        do {
            let payload = try await server.start(validFor: validFor)
            return .success(Self.rewritePairingURL(in: payload, to: lanBaseURL))
        } catch {
            return .failure(PairingErrorResponse(
                code: .internalError,
                error: "failed to begin pairing: \(error)"
            ))
        }
    }

    private static func isActivePairingState(_ state: HostPairingSessionState) -> Bool {
        switch state {
        case .awaitingClient, .pendingConfirmation:
            return true
        case .idle, .confirmed, .denied, .cancelled, .expired, .failed:
            return false
        }
    }

    private static func rewritePairingURL(in payload: PairingPayload, to pairingURL: URL) -> PairingPayload {
        PairingPayload(
            version: payload.version,
            hostDeviceID: payload.hostDeviceID,
            hostKind: payload.hostKind,
            hostDisplayName: payload.hostDisplayName,
            hostPublicKeyFingerprint: payload.hostPublicKeyFingerprint,
            nonce: payload.nonce,
            expiry: payload.expiry,
            pairingURL: pairingURL
        )
    }

    private static func busyError() -> PairingErrorResponse {
        PairingErrorResponse(
            code: .pairingBusy,
            error: "pairing session already active"
        )
    }
}
