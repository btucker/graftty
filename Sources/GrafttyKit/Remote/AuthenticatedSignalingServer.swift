import CryptoKit
import Foundation
import GrafttyProtocol

/// Verifies paired-device keys before the host allocates WebRTC resources.
public actor AuthenticatedSignalingServer {
    public enum OfferDisposition: Sendable {
        case new(VerifiedOffer)
        case pending
        case cached(AuthenticatedSignalingAnswer)
    }

    public struct VerifiedOffer: Sendable {
        public let offer: AuthenticatedSignalingOffer

        fileprivate init(offer: AuthenticatedSignalingOffer) {
            self.offer = offer
        }
    }

    private struct ProbeKey: Hashable {
        var clientDeviceID: RemoteDeviceID
        var clientNonce: Data
    }

    private struct ChallengeRecord {
        var response: SignalingChallengeResponse
        var acceptedOffer: AuthenticatedSignalingOffer?
        var answer: AuthenticatedSignalingAnswer?
        var retentionDeadline: Date?
    }

    private let identityStore: HostIdentityStore
    private let peerStore: TrustedPeerStore
    private let hostDeviceID: RemoteDeviceID
    private let routesProvider: @Sendable () -> [RemoteConnectionRoute]
    private let now: @Sendable () -> Date
    private let challengeLifetime: TimeInterval
    private let acceptedOfferLifetime: TimeInterval
    private let maximumChallenges: Int

    private var challengesByHostNonce: [Data: ChallengeRecord] = [:]
    private var hostNonceByProbe: [ProbeKey: Data] = [:]

    public init(
        identityStore: HostIdentityStore,
        peerStore: TrustedPeerStore,
        hostDeviceID: RemoteDeviceID,
        routesProvider: @escaping @Sendable () -> [RemoteConnectionRoute],
        now: @escaping @Sendable () -> Date = { Date() },
        challengeLifetime: TimeInterval = 15,
        acceptedOfferLifetime: TimeInterval = 60,
        maximumChallenges: Int = 256
    ) {
        self.identityStore = identityStore
        self.peerStore = peerStore
        self.hostDeviceID = hostDeviceID
        self.routesProvider = routesProvider
        self.now = now
        self.challengeLifetime = challengeLifetime
        self.acceptedOfferLifetime = acceptedOfferLifetime
        self.maximumChallenges = max(1, maximumChallenges)
    }

    public func issueChallenge(
        _ request: SignalingChallengeRequest
    ) -> Result<SignalingChallengeResponse, PairingErrorResponse> {
        cleanupExpiredChallenges()
        guard request.version == RemoteAccessProtocol.version else {
            return .failure(error(.unsupportedVersion, "protocol v2 is required"))
        }
        guard let peer = try? peerStore.get(id: request.clientDeviceID),
            request.isValid(using: peer.publicKey)
        else {
            return .failure(error(.authenticationFailed, "paired client signature is invalid"))
        }

        let probeKey = ProbeKey(
            clientDeviceID: request.clientDeviceID,
            clientNonce: request.clientNonce
        )
        if let hostNonce = hostNonceByProbe[probeKey],
            let existing = challengesByHostNonce[hostNonce]
        {
            return .success(existing.response)
        }

        guard evictOldestUnusedChallengeIfNeeded() else {
            return .failure(error(.hostBusy, "too many signaling offers are active"))
        }
        do {
            let signingKey = try identityStore.loadOrGenerateAndPersist()
            let hostNonce = Self.randomNonce()
            // Pairing JSON uses whole-second ISO-8601 values. Normalize here
            // so signatures survive encode/decode without fractional loss.
            let issuedAt = floor(now().timeIntervalSince1970)
            let expiresAt = Date(
                timeIntervalSince1970: issuedAt + challengeLifetime
            )
            let response = try SignalingChallengeResponse(
                hostDeviceID: hostDeviceID,
                clientDeviceID: request.clientDeviceID,
                clientNonce: request.clientNonce,
                hostNonce: hostNonce,
                expiresAt: expiresAt,
                routes: Self.canonicalRoutes(routesProvider()),
                signingKey: signingKey
            )
            challengesByHostNonce[hostNonce] = ChallengeRecord(
                response: response,
                acceptedOffer: nil,
                answer: nil,
                retentionDeadline: nil
            )
            hostNonceByProbe[probeKey] = hostNonce
            return .success(response)
        } catch {
            return .failure(self.error(.internalError, "could not sign challenge"))
        }
    }

    /// Authenticates a signed offer before the caller allocates WebRTC.
    ///
    /// The first valid offer claims the challenge. Exact replays return either
    /// `.pending` or the cached signed answer; a different offer using the same
    /// challenge is rejected. This lets a client retry identical bytes over a
    /// second LAN/Tailscale route without allocating WebRTC twice.
    public func authenticateOffer(
        _ offer: AuthenticatedSignalingOffer
    ) -> Result<OfferDisposition, PairingErrorResponse> {
        cleanupExpiredChallenges()
        guard offer.version == RemoteAccessProtocol.version else {
            return .failure(error(.unsupportedVersion, "protocol v2 is required"))
        }
        guard offer.hostDeviceID == hostDeviceID else {
            return .failure(error(.authenticationFailed, "offer targets a different host"))
        }
        guard var record = challengesByHostNonce[offer.hostNonce] else {
            return .failure(error(.replayDetected, "challenge is unknown or already used"))
        }
        let response = record.response

        guard offer.expiresAt == response.expiresAt,
            offer.clientDeviceID == response.clientDeviceID,
            offer.clientNonce == response.clientNonce,
            let peer = try? peerStore.get(id: offer.clientDeviceID),
            offer.isValid(using: peer.publicKey)
        else {
            return .failure(
                error(.authenticationFailed, "signed offer does not match its challenge"))
        }
        if let acceptedOffer = record.acceptedOffer {
            guard acceptedOffer == offer else {
                return .failure(
                    error(.replayDetected, "challenge is already bound to another offer")
                )
            }
            if let answer = record.answer {
                return .success(.cached(answer))
            }
            return .success(.pending)
        }
        guard now() <= response.expiresAt else {
            return .failure(error(.replayDetected, "signaling challenge expired"))
        }

        record.acceptedOffer = offer
        record.retentionDeadline = now().addingTimeInterval(acceptedOfferLifetime)
        challengesByHostNonce[offer.hostNonce] = record
        return .success(.new(VerifiedOffer(offer: offer)))
    }

    public func makeAnswer(
        sdp: String,
        for verified: VerifiedOffer
    ) -> Result<AuthenticatedSignalingAnswer, PairingErrorResponse> {
        guard var record = challengesByHostNonce[verified.offer.hostNonce],
            record.acceptedOffer == verified.offer
        else {
            return .failure(
                error(.replayDetected, "signaling offer is no longer active")
            )
        }
        if let answer = record.answer {
            return .success(answer)
        }
        do {
            let signingKey = try identityStore.loadOrGenerateAndPersist()
            let answer = try AuthenticatedSignalingAnswer(
                offer: verified.offer,
                sdp: sdp,
                routes: Self.canonicalRoutes(routesProvider()),
                signingKey: signingKey
            )
            record.answer = answer
            record.retentionDeadline = now().addingTimeInterval(acceptedOfferLifetime)
            challengesByHostNonce[verified.offer.hostNonce] = record
            return .success(answer)
        } catch {
            return .failure(
                self.error(
                    .internalError,
                    "could not sign signaling answer"
                ))
        }
    }

    /// Waits for the first request handling an exact signed offer to publish
    /// its answer. A retry on another route uses this instead of allocating a
    /// second WebRTC negotiation while the original request finishes.
    public func awaitAnswer(
        for offer: AuthenticatedSignalingOffer,
        timeout: Duration = .seconds(8)
    ) async -> Result<AuthenticatedSignalingAnswer, PairingErrorResponse> {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !Task.isCancelled {
            cleanupExpiredChallenges()
            guard let record = challengesByHostNonce[offer.hostNonce],
                record.acceptedOffer == offer
            else {
                return .failure(
                    error(.replayDetected, "signaling offer is no longer active")
                )
            }
            if let answer = record.answer {
                return .success(answer)
            }
            guard clock.now < deadline else {
                return .failure(
                    error(.hostBusy, "the signed offer is still being answered")
                )
            }
            do {
                try await Task.sleep(for: .milliseconds(50))
            } catch {
                return .failure(
                    self.error(.hostBusy, "signaling answer wait was cancelled")
                )
            }
        }
        return .failure(
            error(.hostBusy, "signaling answer wait was cancelled")
        )
    }

    private func cleanupExpiredChallenges() {
        let instant = now()
        let expired = challengesByHostNonce.compactMap { hostNonce, record in
            let deadline = record.retentionDeadline ?? record.response.expiresAt
            return deadline < instant ? hostNonce : nil
        }
        for hostNonce in expired {
            removeChallenge(hostNonce)
        }
    }

    private func evictOldestUnusedChallengeIfNeeded() -> Bool {
        guard challengesByHostNonce.count >= maximumChallenges else {
            return true
        }
        guard let oldest = challengesByHostNonce
            .filter({ $0.value.acceptedOffer == nil })
            .min(by: {
                $0.value.response.expiresAt < $1.value.response.expiresAt
            })?.key
        else {
            return false
        }
        removeChallenge(oldest)
        return true
    }

    private func removeChallenge(_ hostNonce: Data) {
        guard let record = challengesByHostNonce.removeValue(forKey: hostNonce) else {
            return
        }
        hostNonceByProbe[
            ProbeKey(
                clientDeviceID: record.response.clientDeviceID,
                clientNonce: record.response.clientNonce
            )] = nil
    }

    private func error(
        _ code: PairingErrorResponse.Code,
        _ message: String
    ) -> PairingErrorResponse {
        PairingErrorResponse(code: code, error: message)
    }

    private static func randomNonce() -> Data {
        var bytes = [UInt8](repeating: 0, count: 32)
        for index in bytes.indices {
            bytes[index] = UInt8.random(in: .min ... .max)
        }
        return Data(bytes)
    }

    private static func canonicalRoutes(
        _ routes: [RemoteConnectionRoute]
    ) -> [RemoteConnectionRoute] {
        var seen = Set<URL>()
        return routes.filter { route in
            guard let scheme = route.baseURL.scheme?.lowercased(),
                scheme == "http" || scheme == "https"
            else {
                return false
            }
            return seen.insert(route.baseURL).inserted
        }
    }
}
