import Foundation

// MARK: - PairingRoutes

/// The two HTTP routes the local pairing ceremony serves, shared by the
/// host's `PairingHTTPServer` (route switch), `HostPairingCoordinator`
/// (constructing the QR-advertised `pairingURL`), and the client's
/// `LocalPairingClient` (path suffixes appended to that URL) so the
/// three can't drift apart.
public enum PairingRoutes {
    public static let basePath = "/v2/pairing"
    public static let introduce = "introduce"
    public static let awaitOutcome = "await-outcome"
}

// MARK: - PairingProtocolDefaults

/// Shared timing defaults for the local pairing ceremony.
public enum PairingProtocolDefaults {
    /// The LAN discovery bootstrap is a short request that only creates a
    /// host-side ceremony. It must not inherit the multi-minute timeout
    /// reserved for the user's confirmation long-poll.
    public static let bootstrapRequestTimeout: TimeInterval = 10

    /// How long a QR-published pairing session stays valid before its
    /// nonce expires. Matches `HostPairingSession.startPairing`'s and
    /// `HostPairingServer.start`'s default `validFor`.
    public static let sessionValidity: TimeInterval = 300

    /// The client's HTTP request timeout for the `await-outcome`
    /// long-poll. Must exceed `sessionValidity` (the host may
    /// legitimately hold the connection open for the full session
    /// window) with margin for network latency.
    public static let clientRequestTimeout: TimeInterval = sessionValidity + 20
}

// MARK: - PairingIntroduceRequest

/// Body of `POST /v2/pairing/introduce`.
///
/// The client publishes its identity to the host using the nonce baked into
/// the scanned QR payload. The host validates the nonce against its active
/// `HostPairingSession` and, on success, returns its full public key so the
/// client can build the transcript and display the verification code.
public struct PairingIntroduceRequest: Codable, Sendable, Equatable {
    /// Protocol version. Must match `RemoteAccessProtocol.version`.
    public let version: Int

    /// Nonce from the QR payload. Pins this request to a single pairing session.
    public let nonce: RemotePairingNonce

    public let clientPublicKey: RemoteIdentityPublicKey
    public let clientDeviceID: RemoteDeviceID
    public let clientKind: RemoteDeviceKind
    public let clientDisplayName: String

    public init(
        version: Int = RemoteAccessProtocol.version,
        nonce: RemotePairingNonce,
        clientPublicKey: RemoteIdentityPublicKey,
        clientDeviceID: RemoteDeviceID,
        clientKind: RemoteDeviceKind,
        clientDisplayName: String
    ) {
        self.version = version
        self.nonce = nonce
        self.clientPublicKey = clientPublicKey
        self.clientDeviceID = clientDeviceID
        self.clientKind = clientKind
        self.clientDisplayName = clientDisplayName
    }
}

// MARK: - PairingIntroduceResponse

/// Body of a successful response to `POST /v2/pairing/introduce`.
///
/// The host returns its full public key so the client can recompute the
/// pairing transcript and display the matching verification code. The
/// client validates `RemoteIdentityFingerprint(of: hostPublicKey)` against
/// the fingerprint pinned in the QR payload before continuing — REMOTE-1.2.
public struct PairingIntroduceResponse: Codable, Sendable, Equatable {
    public let hostPublicKey: RemoteIdentityPublicKey
    public let expiry: Date

    public init(hostPublicKey: RemoteIdentityPublicKey, expiry: Date) {
        self.hostPublicKey = hostPublicKey
        self.expiry = expiry
    }
}

// MARK: - PairingAwaitOutcomeRequest

/// Body of `POST /v2/pairing/await-outcome`.
///
/// The client long-polls this endpoint after `introduce` succeeded; the host
/// holds the response until the user confirms/denies in the host UI or the
/// session expires/is cancelled.
public struct PairingAwaitOutcomeRequest: Codable, Sendable, Equatable {
    public let version: Int
    public let nonce: RemotePairingNonce

    public init(version: Int = RemoteAccessProtocol.version, nonce: RemotePairingNonce) {
        self.version = version
        self.nonce = nonce
    }
}

// MARK: - PairingOutcome

/// Terminal outcomes the host can return to the awaiting client.
public enum PairingOutcome: String, Codable, Sendable, Equatable {
    case confirmed
    case denied
    case expired
    case cancelled
}

// MARK: - PairingOutcomeResponse

/// Body of a response to `POST /v2/pairing/await-outcome`.
public struct PairingOutcomeResponse: Codable, Sendable, Equatable {
    public let outcome: PairingOutcome

    public init(outcome: PairingOutcome) {
        self.outcome = outcome
    }
}

// MARK: - PairingErrorResponse

/// JSON shape returned with non-2xx pairing responses, mirroring the
/// `{ "error": "..." }` convention the existing `WebServer` uses.
public struct PairingErrorResponse: Codable, Sendable, Equatable, Error {
    public let error: String
    /// Machine-readable error code so clients can branch without
    /// regex-matching the human-readable message.
    public let code: Code

    public enum Code: String, Codable, Sendable, Equatable {
        case unsupportedVersion
        case unknownNonce
        case noActiveSession
        case sessionExpired
        /// The pairing session exists but is in a state that doesn't
        /// accept this request (e.g. introduce after confirm).
        case wrongSessionState
        /// A pairing session already exists and a new begin request would
        /// invalidate it.
        case pairingBusy
        /// The caller exceeded a route-level request limit and should back off.
        case rateLimited
        /// The host cannot accept a WebRTC offer right now.
        case hostBusy
        /// The request did not prove possession of a paired identity key.
        case authenticationFailed
        /// A single-use challenge was missing, expired, or already consumed.
        case replayDetected
        case internalError
    }

    public init(code: Code, error: String) {
        self.code = code
        self.error = error
    }
}
