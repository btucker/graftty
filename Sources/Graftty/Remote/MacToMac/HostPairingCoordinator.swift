import Combine
import Foundation
import GrafttyKit
import GrafttyProtocol

struct PendingRemotePairingRequest: Identifiable, Equatable {
    let id: RemotePairingNonce
    let clientDisplayName: String
    let verificationCode: RemoteVerificationCode
}

@MainActor
final class HostPairingCoordinator: ObservableObject {
    @Published private(set) var pendingRequest: PendingRemotePairingRequest?

    private let server: HostPairingServer
    private let beginCoordinator: PairingBeginCoordinator

    init(server: HostPairingServer) {
        self.server = server
        self.beginCoordinator = PairingBeginCoordinator(server: server)
    }

    func beginPairing(
        validFor: TimeInterval,
        lanBaseURL: URL
    ) async -> Result<PairingPayload, PairingErrorResponse> {
        let result = await beginCoordinator.startIfIdle(
            validFor: validFor,
            lanBaseURL: lanBaseURL
        )
        await refreshPendingRequest()
        return result
    }

    func handleIntroduce(
        _ request: PairingIntroduceRequest
    ) async -> Result<PairingIntroduceResponse, PairingErrorResponse> {
        let result = await server.handleIntroduce(request)
        await refreshPendingRequest()
        return result
    }

    func handleAwaitOutcome(
        _ request: PairingAwaitOutcomeRequest
    ) async -> Result<PairingOutcomeResponse, PairingErrorResponse> {
        await server.handleAwaitOutcome(request)
    }

    func confirm() async -> Result<TrustedPeer, PairingErrorResponse> {
        do {
            let peer = try await server.confirm()
            await refreshPendingRequest()
            return .success(peer)
        } catch {
            await refreshPendingRequest()
            return .failure(PairingErrorResponse(
                code: .internalError,
                error: "failed to confirm pairing: \(error)"
            ))
        }
    }

    func deny() async {
        await server.deny()
        await refreshPendingRequest()
    }

    private func refreshPendingRequest() async {
        let state = await server.currentState()
        guard case .pendingConfirmation(
            _,
            _,
            _,
            let clientDisplayName,
            let transcript,
            let verificationCode,
            _
        ) = state else {
            pendingRequest = nil
            return
        }

        pendingRequest = PendingRemotePairingRequest(
            id: transcript.nonce,
            clientDisplayName: clientDisplayName,
            verificationCode: verificationCode
        )
    }
}
