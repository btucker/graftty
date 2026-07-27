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
final class RemoteMacHostPairingCoordinator: ObservableObject {
    @Published private(set) var pendingRequest: PendingRemotePairingRequest?

    private let server: HostPairingServer
    private let beginCoordinator: PairingBeginCoordinator
    private let admission: HostPairingAdmission
    private let tickInterval: Duration
    private var tickTask: Task<Void, Never>?
    private var admissionLease: HostPairingAdmission.Lease?

    convenience init(
        server: HostPairingServer,
        tickInterval: Duration = .seconds(1)
    ) {
        self.init(
            server: server,
            tickInterval: tickInterval,
            admission: HostPairingAdmission()
        )
    }

    init(
        server: HostPairingServer,
        tickInterval: Duration = .seconds(1),
        admission: HostPairingAdmission
    ) {
        self.server = server
        self.beginCoordinator = PairingBeginCoordinator(server: server)
        self.tickInterval = tickInterval
        self.admission = admission
    }

    func beginPairing(
        validFor: TimeInterval,
        lanBaseURL: URL
    ) async -> Result<PairingPayload, PairingErrorResponse> {
        await server.tick()
        await refreshPendingRequest()
        guard admissionLease == nil, let lease = admission.acquire() else {
            return .failure(PairingErrorResponse(
                code: .pairingBusy,
                error: "pairing session already active"
            ))
        }
        admissionLease = lease
        let result = await beginCoordinator.startIfIdle(
            validFor: validFor,
            lanBaseURL: lanBaseURL
        )
        await refreshPendingRequest()
        if case .success = result {
            startTicking()
        } else {
            releaseAdmission(lease)
        }
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
        let result = await server.handleAwaitOutcome(request)
        await refreshPendingRequest()
        return result
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

    func cancel() async {
        await server.cancel()
        await refreshPendingRequest()
    }

    private func refreshPendingRequest() async {
        let state = await server.currentState()
        if state.isTerminal {
            tickTask?.cancel()
            tickTask = nil
            if let lease = admissionLease {
                releaseAdmission(lease)
            }
        }
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

    private func startTicking() {
        tickTask?.cancel()
        tickTask = Task { [weak self, server, tickInterval] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: tickInterval)
                } catch {
                    return
                }
                if Task.isCancelled { return }
                await server.tick()
                guard let self else { return }
                await self.refreshPendingRequest()
                if (await server.currentState()).isTerminal {
                    return
                }
            }
        }
    }

    private func releaseAdmission(_ lease: HostPairingAdmission.Lease) {
        if admissionLease == lease {
            admissionLease = nil
        }
        admission.release(lease)
    }
}
