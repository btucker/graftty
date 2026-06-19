import Foundation
import GrafttyProtocol

// MARK: - LocalPairingClient

/// Drives the client side of the local pairing ceremony.
///
/// Wraps:
///   1. POST `<pairingURL>/introduce` with the client's identity bytes
///      and the QR nonce. Returns the host's full public key + expiry.
///   2. POST `<pairingURL>/await-outcome` — long-poll for the host's
///      user-confirmation decision.
///
/// REMOTE-1.2 (client side) is enforced inside `ClientPairingSession.confirm`,
/// which verifies the received host public key derives to the same
/// fingerprint pinned in the QR payload. If the host returns a different
/// key the session throws `.fingerprintMismatch` and nothing is pinned —
/// `runPairing` propagates that error to the caller.
public actor LocalPairingClient {

    // MARK: Types

    /// Async function from a URLRequest to a (data, http response) pair.
    /// Injectable so tests can stub the transport without URLProtocol.
    public typealias Transport = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

    public enum Error: Swift.Error, Equatable {
        /// Network/transport failure (DNS, TLS, connection reset, …).
        case transport(String)
        /// HTTP returned a non-2xx status with a body the server's
        /// `PairingErrorResponse` shape could be decoded from.
        case serverError(PairingErrorResponse)
        /// HTTP returned a non-2xx status whose body did not decode to
        /// `PairingErrorResponse` — surface the status code so callers
        /// can still distinguish 5xx from 4xx.
        case httpStatus(Int)
        /// 2xx response whose body was not the expected JSON shape.
        case decode
        /// Host responded with `outcome=denied`.
        case denied
        /// Host responded with `outcome=expired`.
        case expired
        /// Host responded with `outcome=cancelled`.
        case cancelled
        /// `payload.pairingURL` produced an invalid URL when extended
        /// with `/introduce` or `/await-outcome`.
        case malformedPairingURL
    }

    // MARK: Dependencies

    private let session: ClientPairingSession
    private let identityStore: ClientIdentityStore
    private let transport: Transport

    // MARK: Init

    public init(
        session: ClientPairingSession,
        identityStore: ClientIdentityStore,
        transport: @escaping Transport = LocalPairingClient.defaultTransport
    ) {
        self.session = session
        self.identityStore = identityStore
        self.transport = transport
    }

    // MARK: Default transport

    public static let defaultTransport: Transport = { request in
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        return (data, http)
    }

    // MARK: - Public API

    /// Runs the full pairing flow against the host described by the
    /// scanned QR payload. Returns the pinned host on success.
    ///
    /// Flow: load client identity → validate payload → POST introduce →
    /// build transcript and show pending confirmation → POST await-outcome
    /// (long-poll) → transition session to its terminal state.
    public func runPairing(payload: PairingPayload) async throws -> PinnedHost {
        let privateKey = try identityStore.loadOrGenerateAndPersist()
        let clientPublicKey = try RemoteIdentityPublicKey(
            rawRepresentation: privateKey.publicKey.rawRepresentation
        )

        try session.consume(payload: payload)

        let introduceResponse = try await postIntroduce(
            payload: payload,
            clientPublicKey: clientPublicKey
        )

        let transcript = RemotePairingTranscript(
            hostPublicKey: introduceResponse.hostPublicKey,
            clientPublicKey: clientPublicKey,
            nonce: payload.nonce,
            expiry: introduceResponse.expiry
        )
        try session.markAwaitingConfirmation(transcript: transcript)

        let outcomeResponse = try await postAwaitOutcome(payload: payload)

        switch outcomeResponse.outcome {
        case .confirmed:
            return try session.confirm(hostPublicKey: introduceResponse.hostPublicKey)
        case .denied:
            session.handleDenied()
            throw Error.denied
        case .expired:
            session.tick()
            throw Error.expired
        case .cancelled:
            session.cancel()
            throw Error.cancelled
        }
    }

    // MARK: - HTTP helpers

    private static let encoder = JSONEncoder.iso8601()
    private static let decoder = JSONDecoder.iso8601()

    private func postIntroduce(
        payload: PairingPayload,
        clientPublicKey: RemoteIdentityPublicKey
    ) async throws -> PairingIntroduceResponse {
        let body = PairingIntroduceRequest(
            nonce: payload.nonce,
            clientPublicKey: clientPublicKey,
            clientDeviceID: session.clientDeviceID,
            clientKind: session.clientKind,
            clientDisplayName: session.clientDisplayName
        )
        return try await postJSON(pathSuffix: "introduce", pairingURL: payload.pairingURL, body: body)
    }

    private func postAwaitOutcome(
        payload: PairingPayload
    ) async throws -> PairingOutcomeResponse {
        let body = PairingAwaitOutcomeRequest(nonce: payload.nonce)
        return try await postJSON(pathSuffix: "await-outcome", pairingURL: payload.pairingURL, body: body)
    }

    private func postJSON<Request: Encodable, Response: Decodable>(
        pathSuffix: String,
        pairingURL: URL,
        body: Request
    ) async throws -> Response {
        guard let url = pairingURL.appendingAPIPath(pathSuffix) else {
            throw Error.malformedPairingURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try Self.encoder.encode(body)

        let data: Data
        let http: HTTPURLResponse
        do {
            (data, http) = try await transport(request)
        } catch {
            throw Error.transport("\(error)")
        }

        if (200..<300).contains(http.statusCode) {
            do {
                return try Self.decoder.decode(Response.self, from: data)
            } catch {
                throw Error.decode
            }
        }

        if let parsed = try? Self.decoder.decode(PairingErrorResponse.self, from: data) {
            throw Error.serverError(parsed)
        }
        throw Error.httpStatus(http.statusCode)
    }
}
