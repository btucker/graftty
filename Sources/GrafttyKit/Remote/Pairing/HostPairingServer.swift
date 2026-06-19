import Foundation
import GrafttyProtocol

// MARK: - HostPairingServer

/// Thin async adapter over `HostPairingSession`.
///
/// Converts wire-shape requests (`PairingIntroduceRequest`,
/// `PairingAwaitOutcomeRequest`) into state-machine drive, mapping
/// `HostPairingSession.Error` to `PairingErrorResponse` codes, and lets
/// clients long-poll for the host's user-confirmation outcome via
/// `handleAwaitOutcome` — internally suspending on a
/// `CheckedContinuation` that the host UI's `confirm`/`deny`/`cancel`/
/// `tick` resumes.
///
/// The session is the source of truth for state. The server adds
/// nonce-scoped lookups (every request carries the nonce from the QR
/// payload, so the server refuses stale or fabricated requests) and a
/// waiter list (one continuation per long-poll, all resumed together by
/// a single state transition).
public actor HostPairingServer {

    // MARK: Dependencies

    private let session: HostPairingSession

    // MARK: Waiters

    /// Continuations waiting for the next terminal state. A single
    /// confirm/deny/cancel/expiry resumes them all with the same outcome.
    private var outcomeWaiters: [UUID: CheckedContinuation<PairingOutcome, Never>] = [:]
    private var cancelledOutcomeWaiterIDs: Set<UUID> = []

    /// The nonce of the active pairing session, or `nil` when there's no
    /// active session. Used to reject HTTP requests whose nonce doesn't
    /// match the currently-published QR payload.
    private var activeNonce: RemotePairingNonce?

    // MARK: Init

    public init(session: HostPairingSession) {
        self.session = session
    }

    // MARK: - UI-facing API

    /// Begins a new pairing session.
    ///
    /// If there was a prior active session, it is abandoned: the prior
    /// nonce becomes unknown and any outstanding `handleAwaitOutcome`
    /// callers receive `.cancelled`.
    ///
    /// TODO: schedule an internal expiry Task so waiters self-wake when
    /// wall-clock time passes `validFor` without an external `tick()`
    /// call. Today, host UI must call `tick()` periodically — otherwise
    /// the long-poll only resolves when the HTTP client times out.
    @discardableResult
    public func start(validFor: TimeInterval = 300) throws -> PairingPayload {
        resumeWaiters(with: .cancelled)
        let payload = try session.startPairing(validFor: validFor)
        activeNonce = payload.nonce
        return payload
    }

    /// User confirmed via the host UI. Wakes any awaiting clients.
    @discardableResult
    public func confirm() throws -> TrustedPeer {
        do {
            let peer = try session.confirm()
            broadcastIfTerminal()
            return peer
        } catch {
            broadcastIfTerminal()
            throw error
        }
    }

    /// User denied via the host UI. Wakes any awaiting clients.
    public func deny() {
        session.deny()
        broadcastIfTerminal()
    }

    /// User cancelled the pairing. Wakes any awaiting clients.
    public func cancel() {
        session.cancel()
        broadcastIfTerminal()
    }

    /// Polls the session for expiry; if a state change to a terminal
    /// state happens, wakes any awaiting clients. Call this from a UI
    /// timer or whenever wall-clock time matters.
    public func tick() {
        session.tick()
        broadcastIfTerminal()
    }

    /// Current session state — useful for SwiftUI bindings.
    public func currentState() -> HostPairingSessionState {
        session.state
    }

    /// Number of long-poll callers currently suspended in
    /// `handleAwaitOutcome`. Test-only — lets tests deterministically
    /// wait for waiter registration instead of a fixed sleep.
    public var pendingWaiterCount: Int {
        outcomeWaiters.count
    }

    // MARK: - HTTP-facing API

    /// Handles `POST /v1/pairing/introduce`.
    public func handleIntroduce(
        _ request: PairingIntroduceRequest
    ) -> Result<PairingIntroduceResponse, PairingErrorResponse> {
        guard request.version == 1 else {
            return .failure(PairingErrorResponse(
                code: .unsupportedVersion,
                error: "unsupported pairing protocol version: \(request.version)"
            ))
        }

        guard let active = activeNonce else {
            return .failure(PairingErrorResponse(
                code: .noActiveSession,
                error: "no pairing session is active"
            ))
        }
        guard active == request.nonce else {
            return .failure(PairingErrorResponse(
                code: .unknownNonce,
                error: "nonce does not match active pairing session"
            ))
        }

        do {
            try session.receiveClientIdentity(
                clientPublicKey: request.clientPublicKey,
                clientDeviceID: request.clientDeviceID,
                clientKind: request.clientKind,
                clientDisplayName: request.clientDisplayName
            )
        } catch HostPairingSession.Error.nonceExpired {
            broadcastIfTerminal()
            return .failure(PairingErrorResponse(
                code: .sessionExpired,
                error: "pairing session expired before client introduced"
            ))
        } catch HostPairingSession.Error.wrongState(let current) {
            return .failure(PairingErrorResponse(
                code: errorCode(forUnexpectedState: current),
                error: "pairing session is not awaiting a client (state: \(current))"
            ))
        } catch HostPairingSession.Error.noHostIdentity {
            return .failure(PairingErrorResponse(
                code: .internalError,
                error: "host identity missing"
            ))
        } catch {
            return .failure(PairingErrorResponse(
                code: .internalError,
                error: "unexpected error: \(error)"
            ))
        }

        let state = session.state
        guard case .pendingConfirmation(_, _, _, _, let transcript, _, let expiry) = state else {
            return .failure(PairingErrorResponse(
                code: .internalError,
                error: "unexpected post-introduce state: \(state)"
            ))
        }
        return .success(PairingIntroduceResponse(
            hostPublicKey: transcript.hostPublicKey,
            expiry: expiry
        ))
    }

    /// Handles `POST /v1/pairing/await-outcome`. Suspends until the
    /// session reaches a terminal state.
    public func handleAwaitOutcome(
        _ request: PairingAwaitOutcomeRequest
    ) async -> Result<PairingOutcomeResponse, PairingErrorResponse> {
        guard request.version == 1 else {
            return .failure(PairingErrorResponse(
                code: .unsupportedVersion,
                error: "unsupported pairing protocol version: \(request.version)"
            ))
        }
        guard let active = activeNonce else {
            return .failure(PairingErrorResponse(
                code: .noActiveSession,
                error: "no pairing session is active"
            ))
        }
        guard active == request.nonce else {
            return .failure(PairingErrorResponse(
                code: .unknownNonce,
                error: "nonce does not match active pairing session"
            ))
        }

        if let outcome = terminalOutcome(of: session.state) {
            return .success(PairingOutcomeResponse(outcome: outcome))
        }

        let waiterID = UUID()
        let outcome: PairingOutcome = await withTaskCancellationHandler {
            await withCheckedContinuation { cont in
                registerWaiter(id: waiterID, continuation: cont)
            }
        } onCancel: {
            Task {
                await self.cancelWaiter(id: waiterID)
            }
        }
        return .success(PairingOutcomeResponse(outcome: outcome))
    }

    // MARK: - Helpers

    /// If the session is in a terminal state, resume every waiter with
    /// that outcome. Otherwise no-op.
    private func broadcastIfTerminal() {
        guard let outcome = terminalOutcome(of: session.state) else { return }
        resumeWaiters(with: outcome)
    }

    private func resumeWaiters(with outcome: PairingOutcome) {
        guard !outcomeWaiters.isEmpty else { return }
        let waiters = outcomeWaiters
        outcomeWaiters.removeAll(keepingCapacity: true)
        for cont in waiters.values {
            cont.resume(returning: outcome)
        }
    }

    private func registerWaiter(
        id: UUID,
        continuation: CheckedContinuation<PairingOutcome, Never>
    ) {
        if cancelledOutcomeWaiterIDs.remove(id) != nil {
            continuation.resume(returning: .cancelled)
        } else {
            outcomeWaiters[id] = continuation
        }
    }

    private func cancelWaiter(id: UUID) {
        if let continuation = outcomeWaiters.removeValue(forKey: id) {
            continuation.resume(returning: .cancelled)
        } else {
            cancelledOutcomeWaiterIDs.insert(id)
        }
    }

    private func terminalOutcome(of state: HostPairingSessionState) -> PairingOutcome? {
        switch state {
        case .confirmed: return .confirmed
        case .denied: return .denied
        case .cancelled: return .cancelled
        case .expired: return .expired
        // `.failed` is an internal-error state. Surface as `.cancelled`
        // to the client so it stops waiting; the host UI is responsible
        // for surfacing the underlying message to the user.
        case .failed: return .cancelled
        case .idle, .awaitingClient, .pendingConfirmation: return nil
        }
    }

    private func errorCode(forUnexpectedState state: HostPairingSessionState) -> PairingErrorResponse.Code {
        switch state {
        case .expired: return .sessionExpired
        case .idle: return .noActiveSession
        default: return .wrongSessionState
        }
    }
}
