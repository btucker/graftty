import Foundation
import GrafttyProtocol

// MARK: - HostPairingSessionState

/// The state of an in-progress host-side pairing ceremony.
public enum HostPairingSessionState: Sendable, Equatable {
    /// No pairing is in progress.
    case idle
    /// QR code has been published; waiting for the client to connect.
    case awaitingClient(payload: PairingPayload, expiry: Date)
    /// Client has sent their public key; host needs to confirm or deny.
    case pendingConfirmation(
        clientPublicKey: RemoteIdentityPublicKey,
        clientDeviceID: RemoteDeviceID,
        clientKind: RemoteDeviceKind,
        clientDisplayName: String,
        transcript: RemotePairingTranscript,
        verificationCode: RemoteVerificationCode,
        expiry: Date
    )
    /// Host confirmed; peer persisted.
    case confirmed(trustedPeer: TrustedPeer)
    /// Host denied the pairing request.
    case denied
    /// Host cancelled before the client connected.
    case cancelled
    /// Nonce expired before the ceremony completed.
    case expired
    /// An unexpected error terminated the session.
    case failed(message: String)

    /// True for the terminal states `.confirmed`, `.denied`,
    /// `.cancelled`, `.expired`, and `.failed` — the states from which
    /// the ceremony never resumes. Drives the coordinator's tick-task
    /// teardown decision and `HostPairingServer.terminalOutcome(of:)`'s
    /// outcome mapping.
    public var isTerminal: Bool {
        switch self {
        case .confirmed, .denied, .cancelled, .expired, .failed:
            return true
        case .idle, .awaitingClient, .pendingConfirmation:
            return false
        }
    }
}

// MARK: - HostPairingSession

/// @spec REMOTE-1.2
/// Pure state machine for one host-side pairing ceremony.
///
/// Does NOT contain network connection logic. The network layer (deferred to
/// `HostPairingServer`) drives the state machine by calling `receiveClientIdentity`
/// and `confirm`/`deny`.
///
/// REMOTE-1.2 enforcement: `confirm()` is the only path that inserts the peer
/// into `peerStore`. The peer is only reachable after `receiveClientIdentity`
/// transitions to `.pendingConfirmation` — which itself requires the session to
/// be in `.awaitingClient` with a non-expired nonce.  Denying skips the insert
/// entirely.
public final class HostPairingSession: @unchecked Sendable {

    // MARK: Errors

    public enum Error: Swift.Error, Equatable {
        case noHostIdentity
        case wrongState(current: HostPairingSessionState)
        case expired
        case nonceExpired
        case peerStoreFailed(underlying: String)

        public static func == (lhs: HostPairingSession.Error, rhs: HostPairingSession.Error) -> Bool {
            switch (lhs, rhs) {
            case (.noHostIdentity, .noHostIdentity): return true
            case (.expired, .expired): return true
            case (.nonceExpired, .nonceExpired): return true
            case (.wrongState(let l), .wrongState(let r)): return l == r
            case (.peerStoreFailed(let l), .peerStoreFailed(let r)): return l == r
            default: return false
            }
        }
    }

    // MARK: Dependencies

    private let identityStore: HostIdentityStore
    private let peerStore: TrustedPeerStore
    private let now: () -> Date
    private let nonceGenerator: () -> RemotePairingNonce
    private let hostDeviceID: RemoteDeviceID
    private let hostKind: RemoteDeviceKind
    private let hostDisplayName: String
    private let pairingURLProvider: () -> URL
    private let connectionRoutesProvider: (() -> [RemoteConnectionRoute])?

    // MARK: State

    private let lock = NSLock()
    private var _state: HostPairingSessionState = .idle

    public var state: HostPairingSessionState {
        lock.lock()
        defer { lock.unlock() }
        return _state
    }

    // MARK: Init

    public init(
        identityStore: HostIdentityStore,
        peerStore: TrustedPeerStore,
        now: @escaping () -> Date = { Date() },
        nonceGenerator: @escaping () -> RemotePairingNonce = { RemotePairingNonce.generate() },
        hostDeviceID: RemoteDeviceID,
        hostKind: RemoteDeviceKind,
        hostDisplayName: String,

        pairingURLProvider: @escaping () -> URL,
        connectionRoutesProvider: (() -> [RemoteConnectionRoute])? = nil
    ) {
        self.identityStore = identityStore
        self.peerStore = peerStore
        self.now = now
        self.nonceGenerator = nonceGenerator
        self.hostDeviceID = hostDeviceID
        self.hostKind = hostKind
        self.hostDisplayName = hostDisplayName
        self.pairingURLProvider = pairingURLProvider
        self.connectionRoutesProvider = connectionRoutesProvider
    }

    // MARK: - Public API

    /// Begins a new pairing session. Generates a fresh nonce and produces the QR payload.
    ///
    /// Throws `.noHostIdentity` if no host identity key has been generated yet
    /// (REMOTE-1.1: identity must exist before accepting pairing requests).
    ///
    /// If a pairing is already in progress (`.awaitingClient` or
    /// `.pendingConfirmation`), calling `startPairing` again abandons
    /// it and starts a fresh nonce. The prior nonce will be rejected
    /// by `receiveClientIdentity` when an old client connects.
    public func startPairing(
        validFor: TimeInterval = PairingProtocolDefaults.sessionValidity,
        pairingURL: URL? = nil,
        connectionRoutes: [RemoteConnectionRoute]? = nil
    ) throws -> PairingPayload {
        lock.lock()
        defer { lock.unlock() }

        guard let hostPublicKey = try identityStore.currentPublicKey() else {
            throw Error.noHostIdentity
        }

        let nonce = nonceGenerator()
        let expiry = Date(
            timeIntervalSince1970: Double(
                Int64(now().addingTimeInterval(validFor).timeIntervalSince1970)
            )
        )
        let fingerprint = RemoteIdentityFingerprint(of: hostPublicKey)

        let pairingURL = pairingURL ?? pairingURLProvider()
        let payload = PairingPayload(
            version: RemoteAccessProtocol.version,
            hostDeviceID: hostDeviceID,
            hostKind: hostKind,
            hostDisplayName: hostDisplayName,
            hostPublicKeyFingerprint: fingerprint,
            nonce: nonce,
            expiry: expiry,
            pairingURL: pairingURL,
            routes: connectionRoutes ?? connectionRoutesProvider?() ?? [
                RemoteConnectionRoute(
                    kind: .lan,
                    baseURL: Self.baseURL(fromPairingURL: pairingURL)
                )
            ]
        )
        _state = .awaitingClient(payload: payload, expiry: expiry)
        return payload
    }

    private static func baseURL(fromPairingURL pairingURL: URL) -> URL {
        guard
            var components = URLComponents(
                url: pairingURL,
                resolvingAgainstBaseURL: false
            )
        else {
            return pairingURL
        }
        components.path = ""
        components.query = nil
        components.fragment = nil
        return components.url ?? pairingURL
    }

    /// Called when a client POSTs their identity to the host.
    ///
    /// Transitions from `.awaitingClient` to `.pendingConfirmation`. The
    /// verification code in `.pendingConfirmation` is derived from the full
    /// transcript so the user can confirm both sides are looking at the same code.
    ///
    /// Throws if the session is not in `.awaitingClient` or the nonce has
    /// expired.
    public func receiveClientIdentity(
        clientPublicKey: RemoteIdentityPublicKey,
        clientDeviceID: RemoteDeviceID,
        clientKind: RemoteDeviceKind,
        clientDisplayName: String
    ) throws {
        lock.lock()
        defer { lock.unlock() }

        guard case .awaitingClient(let payload, let expiry) = _state else {
            throw Error.wrongState(current: _state)
        }

        if now() > expiry {
            _state = .expired
            throw Error.nonceExpired
        }

        // Load the host's public key to build the transcript.
        guard let hostPublicKey = try identityStore.currentPublicKey() else {
            _state = .failed(message: "Host identity missing when client arrived")
            throw Error.noHostIdentity
        }

        let transcript = RemotePairingTranscript(
            hostPublicKey: hostPublicKey,
            clientPublicKey: clientPublicKey,
            payload: payload
        )
        let code = transcript.verificationCode()

        _state = .pendingConfirmation(
            clientPublicKey: clientPublicKey,
            clientDeviceID: clientDeviceID,
            clientKind: clientKind,
            clientDisplayName: clientDisplayName,
            transcript: transcript,
            verificationCode: code,
            expiry: expiry
        )
    }

    /// User confirms via the host UI. Persists the new trusted peer.
    ///
    /// Requires `.pendingConfirmation` state.
    /// REMOTE-1.2: this is the only path that inserts into `peerStore`.
    @discardableResult
    public func confirm() throws -> TrustedPeer {
        lock.lock()
        defer { lock.unlock() }

        guard case .pendingConfirmation(
            let clientPublicKey,
            let clientDeviceID,
            let clientKind,
            let clientDisplayName,
            _,
            _,
            let expiry
        ) = _state else {
            throw Error.wrongState(current: _state)
        }

        if now() > expiry {
            _state = .expired
            throw Error.expired
        }

        let peer = TrustedPeer(
            id: clientDeviceID,
            kind: clientKind,
            publicKey: clientPublicKey,
            displayName: clientDisplayName,
            capabilities: .defaultsAfterPairing,
            pairedAt: now(),
            lastSeenAt: nil
        )

        do {
            try peerStore.add(peer)
        } catch {
            _state = .failed(message: "\(error)")
            throw Error.peerStoreFailed(underlying: "\(error)")
        }

        _state = .confirmed(trustedPeer: peer)
        return peer
    }

    /// User denies the pairing request. Transitions to `.denied` without
    /// inserting anything into the peer store.
    ///
    /// Only transitions from `.pendingConfirmation`. No-op from terminal states
    /// (`.confirmed`, `.denied`, `.cancelled`, `.expired`, `.failed`) to prevent
    /// a delayed UI action from clobbering an already-completed session.
    public func deny() {
        lock.lock()
        defer { lock.unlock() }
        guard case .pendingConfirmation = _state else { return }
        _state = .denied
    }

    /// User cancels before the client connects. Transitions to `.cancelled`.
    ///
    /// No-op from terminal states (`.idle`, `.confirmed`, `.denied`,
    /// `.cancelled`, `.expired`, `.failed`) — only active states
    /// (`.awaitingClient`, `.pendingConfirmation`) are cancellable.
    public func cancel() {
        lock.lock()
        defer { lock.unlock() }
        switch _state {
        case .idle, .confirmed, .denied, .cancelled, .expired, .failed:
            return
        case .awaitingClient, .pendingConfirmation:
            break
        }
        _state = .cancelled
    }

    /// Polls for expiry. Call from a UI timer or before serving the QR payload.
    /// Transitions to `.expired` if the session deadline has passed.
    public func tick() {
        lock.lock()
        defer { lock.unlock() }
        switch _state {
        case .awaitingClient(_, let expiry), .pendingConfirmation(_, _, _, _, _, _, let expiry):
            if now() > expiry {
                _state = .expired
            }
        default:
            break
        }
    }
}
