import CryptoKit
import Foundation
import GrafttyProtocol

/// Exchanges authenticated signaling messages with the host's paired-access
/// listener.
public struct SignalingClient: Sendable {
    public struct AuthenticatedExchange: Sendable {
        public let answer: AuthenticatedSignalingAnswer
        public let route: RemoteConnectionRoute
        public let wakeOnLAN: WakeOnLANAdvertisement?

        public init(
            answer: AuthenticatedSignalingAnswer,
            route: RemoteConnectionRoute,
            wakeOnLAN: WakeOnLANAdvertisement? = nil
        ) {
            self.answer = answer
            self.route = route
            self.wakeOnLAN = wakeOnLAN
        }
    }

    public typealias Transport = @Sendable (URLRequest, Data) async throws -> (Data, HTTPURLResponse)
    public typealias Wake = @Sendable ([WakeOnLANTarget]) async -> Bool

    private let transport: Transport
    private let wake: Wake
    private let wakeRetryDelay: @Sendable () async throws -> Void

    public init(
        transport: @escaping Transport = SignalingClient.defaultTransport,
        wake: Wake? = nil,
        wakeRetryDelay: @escaping @Sendable () async throws -> Void = {
            try await Task.sleep(for: .seconds(5))
        }
    ) {
        self.transport = transport
        self.wake = wake ?? { await WakeOnLANClient.send($0) }
        self.wakeRetryDelay = wakeRetryDelay
    }

    public enum Error: Swift.Error, Equatable, Sendable {
        case http(status: Int, body: String)
        case decode(String)
        case authentication(String)
        /// `String` rather than `Swift.Error` so the enum stays
        /// `Equatable` for test assertions and switch-case clarity.
        /// The string carries `String(describing:)` of the underlying
        /// error, which is sufficient for logging but not for typed
        /// recovery — callers needing the original error must rebuild
        /// from the message string.
        case transport(String)
    }

    private enum OfferAttempt: Sendable {
        case success(AuthenticatedExchange)
        case failure(Error)
    }

    private enum ChallengeAttempt: Sendable {
        case success(RemoteConnectionRoute, SignalingChallengeResponse)
        case unreachable
        case rejected
    }

    /// Races key-authenticated reachability probes, then sends one unique
    /// signed SDP offer. If transport fails, the same signed offer is retried
    /// over the remaining routes; the host binds the challenge to that offer
    /// and caches its answer, so failover cannot allocate WebRTC twice.
    public func authenticatedExchange(
        routes: [RemoteConnectionRoute],
        hostDeviceID: RemoteDeviceID,
        hostPublicKey: RemoteIdentityPublicKey,
        clientDeviceID: RemoteDeviceID,
        clientKey: Curve25519.Signing.PrivateKey,
        sdp: String,
        wakeOnLAN: WakeOnLANAdvertisement? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) async throws -> AuthenticatedExchange {
        let uniqueRoutes = Self.uniqueHTTPRoutes(routes)
        guard !uniqueRoutes.isEmpty else {
            throw Error.transport("paired host has no usable routes")
        }

        try Task.checkCancellation()
        var sentWake = false
        if let wakeOnLAN, wakeOnLAN.isValid(for: hostDeviceID, using: hostPublicKey) {
            sentWake = await wake(wakeOnLAN.targets)
        }
        var selected: (RemoteConnectionRoute, SignalingChallengeResponse)?
        for attempt in 0..<(sentWake ? 3 : 1) {
            try Task.checkCancellation()
            if attempt > 0 { try await wakeRetryDelay() }
            try Task.checkCancellation()
            // A fresh nonce avoids reusing a challenge that expired during wake.
            let probe = try SignalingChallengeRequest(
                clientDeviceID: clientDeviceID,
                clientNonce: Self.randomNonce(),
                signingKey: clientKey
            )
            let result = await firstValidChallenge(
                routes: uniqueRoutes,
                request: probe,
                hostDeviceID: hostDeviceID,
                hostPublicKey: hostPublicKey,
                now: now
            )
            try Task.checkCancellation()
            selected = result.candidate
            if selected != nil || result.rejected { break }
        }
        guard let (route, challenge) = selected else {
            throw Error.authentication("no route returned a valid host challenge")
        }

        let offer = try AuthenticatedSignalingOffer(
            challenge: challenge,
            sdp: sdp,
            signingKey: clientKey
        )
        let offerRoutes = [route] + uniqueRoutes.filter {
            $0.baseURL != route.baseURL
        }
        let result: Result<AuthenticatedExchange, Error> = await withTaskGroup(
            of: OfferAttempt.self
        ) { group in
            for offerRoute in offerRoutes {
                group.addTask {
                    do {
                        let answer: AuthenticatedSignalingAnswer = try await post(
                            path: RemoteAccessProtocol.offerPath,
                            baseURL: offerRoute.baseURL,
                            body: offer
                        )
                        guard answer.isValid(for: offer, using: hostPublicKey) else {
                            return .failure(
                                .authentication("host answer signature is invalid")
                            )
                        }
                        return .success(AuthenticatedExchange(
                            answer: answer,
                            route: offerRoute,
                            wakeOnLAN: answer.wakeOnLAN.flatMap {
                                $0.isValid(for: hostDeviceID, using: hostPublicKey) ? $0 : nil
                            }
                        ))
                    } catch let error as Error {
                        return .failure(error)
                    } catch {
                        return .failure(.transport(String(describing: error)))
                    }
                }
            }

            var lastError: Error?
            while let attempt = await group.next() {
                switch attempt {
                case .success(let exchange):
                    group.cancelAll()
                    return .success(exchange)
                case .failure(let error):
                    lastError = error
                }
            }
            return .failure(lastError ?? Error.transport(
                "all authenticated signaling routes failed"
            ))
        }
        return try result.get()
    }

    private func firstValidChallenge(
        routes: [RemoteConnectionRoute],
        request: SignalingChallengeRequest,
        hostDeviceID: RemoteDeviceID,
        hostPublicKey: RemoteIdentityPublicKey,
        now: @escaping @Sendable () -> Date
    ) async -> (candidate: (RemoteConnectionRoute, SignalingChallengeResponse)?, rejected: Bool) {
        await withTaskGroup(
            of: ChallengeAttempt.self
        ) { group in
            for route in routes {
                group.addTask {
                    do {
                        let response: SignalingChallengeResponse = try await post(
                            path: RemoteAccessProtocol.challengePath,
                            baseURL: route.baseURL,
                            body: request
                        )
                        guard response.isValid(
                            expectedHostID: hostDeviceID,
                            expectedClientID: request.clientDeviceID,
                            expectedClientNonce: request.clientNonce,
                            now: now(),
                            using: hostPublicKey
                        ) else { return .rejected }
                        return .success(route, response)
                    } catch Error.transport {
                        return .unreachable
                    } catch {
                        return .rejected
                    }
                }
            }
            var rejected = false
            while let candidate = await group.next() {
                switch candidate {
                case .success(let route, let response):
                    group.cancelAll()
                    return ((route, response), false)
                case .rejected:
                    rejected = true
                case .unreachable:
                    break
                }
            }
            return (nil, rejected)
        }
    }

    private func post<Request: Encodable, Response: Decodable>(
        path: String,
        baseURL: URL,
        body value: Request
    ) async throws -> Response {
        guard let url = baseURL.appendingAPIPath(path) else {
            throw Error.transport("could not construct \(path) URL from \(baseURL)")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.addValue("application/json", forHTTPHeaderField: "Accept")
        let body: Data
        do {
            body = try JSONEncoder.iso8601().encode(value)
        } catch {
            throw Error.transport("encode \(path): \(error)")
        }

        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await transport(request, body)
        } catch {
            throw Error.transport(String(describing: error))
        }
        guard (200..<300).contains(response.statusCode) else {
            throw Error.http(
                status: response.statusCode,
                body: String(data: data, encoding: .utf8) ?? ""
            )
        }
        do {
            return try JSONDecoder.iso8601().decode(Response.self, from: data)
        } catch {
            throw Error.decode(String(describing: error))
        }
    }

    private static func uniqueHTTPRoutes(
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

    private static func randomNonce() -> Data {
        Data((0..<32).map { _ in UInt8.random(in: .min ... .max) })
    }

    public static let defaultTransport: Transport = { request, body in
        let (data, response) = try await Self.session.upload(for: request, from: body)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        return (data, http)
    }

    /// A dedicated session — NEVER `URLSession.shared` — so this timeout
    /// can't leak onto other callers that happen to share the process's
    /// default session, and so this file doesn't mutate shared, ambient
    /// state as a side effect of being imported.
    ///
    /// Signaling is LAN/tailnet-local: a healthy host answers
    /// `/v2/rtc/challenge` and `/v2/rtc/offer` in well under a second.
    /// 10s is generous headroom
    /// above that normal case while still failing fast enough that a
    /// hung request (dropped Wi-Fi, a host that vanished mid-request)
    /// doesn't stall negotiation indefinitely — paired with
    /// `RemoteConnectionCoordinator`'s per-host failure cooldown, which
    /// only starts once this timeout (or any other failure) actually
    /// surfaces.
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 10
        return URLSession(configuration: config)
    }()
}
