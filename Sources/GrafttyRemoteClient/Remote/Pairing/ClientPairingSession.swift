import Foundation
import GrafttyProtocol

// MARK: - ClientPairingSessionState

/// The state of an in-progress client-side pairing ceremony.
public enum ClientPairingSessionState: Sendable, Equatable {
    /// No pairing is in progress.
    case idle
    /// A valid QR payload has been scanned; ready to POST to the host.
    case readyToConnect(payload: PairingPayload)
    /// POSTed client identity to the host; waiting for host to confirm.
    case awaitingHostConfirmation(
        transcript: RemotePairingTranscript,
        verificationCode: RemoteVerificationCode,
        payload: PairingPayload
    )
    /// Host confirmed; pinned host persisted.
    case confirmed(pinnedHost: PinnedHost)
    /// Host denied the pairing request.
    case denied
    /// Client cancelled before completion.
    case cancelled
    /// QR payload or session expired.
    case expired
    /// An unexpected error terminated the session.
    case failed(message: String)
}

// MARK: - ClientPairingSession

/// Pure state machine for one client-side pairing ceremony.
///
/// Does NOT contain network connection logic. The network layer (deferred to
/// `LocalPairingClient`) drives the state machine by calling `consume`,
/// `markAwaitingConfirmation`, and `confirm`/`handleDenied`.
///
/// REMOTE-1.2 enforcement (client side): `confirm(hostPublicKey:)` validates
/// that the received host public key produces the same fingerprint as the QR
/// payload's `hostPublicKeyFingerprint`. If they don't match,
/// `.fingerprintMismatch` is thrown and nothing is pinned.
public final class ClientPairingSession: @unchecked Sendable {

    // MARK: Errors

    public enum Error: Swift.Error, Equatable {
        case wrongState(current: ClientPairingSessionState)
        case expired
        /// The host returned a public key whose fingerprint doesn't match the QR payload.
        case fingerprintMismatch
        case unsupportedPayloadVersion(Int)
        case pinnedHostStoreFailed(underlying: String)

        public static func == (lhs: ClientPairingSession.Error, rhs: ClientPairingSession.Error) -> Bool {
            switch (lhs, rhs) {
            case (.expired, .expired): return true
            case (.fingerprintMismatch, .fingerprintMismatch): return true
            case let (.wrongState(l), .wrongState(r)): return l == r
            case let (.unsupportedPayloadVersion(l), .unsupportedPayloadVersion(r)): return l == r
            case let (.pinnedHostStoreFailed(l), .pinnedHostStoreFailed(r)): return l == r
            default: return false
            }
        }
    }

    // MARK: Dependencies

    private let identityStore: ClientIdentityStore
    private let pinnedHostStore: PinnedHostStore
    private let now: () -> Date

    /// Client device metadata exposed so `LocalPairingClient` (and other
    /// network adapters) can build wire-shape requests without taking
    /// duplicate copies of the same values.
    public let clientDeviceID: RemoteDeviceID
    public let clientKind: RemoteDeviceKind
    public let clientDisplayName: String

    // MARK: State

    private let lock = NSLock()
    private var _state: ClientPairingSessionState = .idle

    public var state: ClientPairingSessionState {
        lock.lock()
        defer { lock.unlock() }
        return _state
    }

    // MARK: Init

    public init(
        identityStore: ClientIdentityStore,
        pinnedHostStore: PinnedHostStore,
        now: @escaping () -> Date = { Date() },
        clientDeviceID: RemoteDeviceID,
        clientKind: RemoteDeviceKind,
        clientDisplayName: String
    ) {
        self.identityStore = identityStore
        self.pinnedHostStore = pinnedHostStore
        self.now = now
        self.clientDeviceID = clientDeviceID
        self.clientKind = clientKind
        self.clientDisplayName = clientDisplayName
    }

    // MARK: - Public API

    /// Starts pairing from a scanned QR payload. Validates the payload version
    /// and expiry, then transitions to `.readyToConnect`.
    ///
    /// Throws `.unsupportedPayloadVersion` for version != 1.
    /// Throws `.expired` if the payload's expiry has already passed.
    public func consume(payload: PairingPayload) throws {
        lock.lock()
        defer { lock.unlock() }

        guard payload.version == 1 else {
            throw Error.unsupportedPayloadVersion(payload.version)
        }

        if now() > payload.expiry {
            _state = .expired
            throw Error.expired
        }

        _state = .readyToConnect(payload: payload)
    }

    /// Called by the network layer after successfully POSTing the client's
    /// identity to the host. Builds the transcript and computes the verification
    /// code for display; transitions to `.awaitingHostConfirmation`.
    ///
    /// Requires `.readyToConnect` state.
    public func markAwaitingConfirmation(transcript: RemotePairingTranscript) throws {
        lock.lock()
        defer { lock.unlock() }

        guard case .readyToConnect(let payload) = _state else {
            throw Error.wrongState(current: _state)
        }

        let code = transcript.verificationCode()
        _state = .awaitingHostConfirmation(transcript: transcript, verificationCode: code, payload: payload)
    }

    /// Called when the host's HTTPS response confirms pairing and delivers the
    /// full host public key.
    ///
    /// REMOTE-1.2 (client side): validates the received `hostPublicKey` produces
    /// the same fingerprint that was in the originally scanned QR payload. If
    /// they differ, throws `.fingerprintMismatch` and does NOT pin the host.
    ///
    /// On success, persists a `PinnedHost` and transitions to `.confirmed`.
    @discardableResult
    public func confirm(hostPublicKey: RemoteIdentityPublicKey) throws -> PinnedHost {
        lock.lock()
        defer { lock.unlock() }

        guard case .awaitingHostConfirmation(_, _, let payload) = _state else {
            throw Error.wrongState(current: _state)
        }

        // REMOTE-1.2: fingerprint check — anti-MITM guard
        let receivedFingerprint = RemoteIdentityFingerprint(of: hostPublicKey)
        guard receivedFingerprint == payload.hostPublicKeyFingerprint else {
            _state = .failed(message: "Fingerprint mismatch: received key does not match QR payload")
            throw Error.fingerprintMismatch
        }

        let currentTime = now()
        let host = PinnedHost(
            id: payload.hostDeviceID,
            kind: payload.hostKind,
            publicKey: hostPublicKey,
            displayName: payload.hostDisplayName,
            pinnedAt: currentTime,
            lastConnectedAt: currentTime,
            pairingURL: payload.pairingURL
        )

        do {
            try pinnedHostStore.add(host)
        } catch {
            _state = .failed(message: "\(error)")
            throw Error.pinnedHostStoreFailed(underlying: "\(error)")
        }

        _state = .confirmed(pinnedHost: host)
        return host
    }

    /// Called when the host explicitly denies the pairing request.
    ///
    /// Only transitions from `.awaitingHostConfirmation`. No-op from terminal states
    /// (`.confirmed`, `.denied`, `.cancelled`, `.expired`, `.failed`) to prevent a
    /// delayed network callback from clobbering an already-completed session.
    public func handleDenied() {
        lock.lock()
        defer { lock.unlock() }
        guard case .awaitingHostConfirmation = _state else { return }
        _state = .denied
    }

    /// Called when a network failure occurs during the ceremony.
    public func handleNetworkFailure(message: String) {
        lock.lock()
        defer { lock.unlock() }
        _state = .failed(message: message)
    }

    /// Client cancels the pairing before it completes.
    ///
    /// No-op from terminal states (`.confirmed`, `.denied`, `.cancelled`,
    /// `.expired`, `.failed`) to prevent a delayed cancel from overwriting
    /// an already-completed session.
    public func cancel() {
        lock.lock()
        defer { lock.unlock() }
        switch _state {
        case .idle, .confirmed, .denied, .cancelled, .expired, .failed:
            return
        case .readyToConnect, .awaitingHostConfirmation:
            break
        }
        _state = .cancelled
    }

    /// Polls for expiry. Call from a UI timer or before attempting to connect.
    public func tick() {
        lock.lock()
        defer { lock.unlock() }
        switch _state {
        case .readyToConnect(let payload):
            if now() > payload.expiry {
                _state = .expired
            }
        case .awaitingHostConfirmation(_, _, let payload):
            if now() > payload.expiry {
                _state = .expired
            }
        default:
            break
        }
    }
}
