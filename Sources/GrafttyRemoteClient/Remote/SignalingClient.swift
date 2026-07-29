import CryptoKit
import Foundation
import GrafttyProtocol

/// Exchanges authenticated signaling messages with the host's paired-access
/// listener. The legacy `exchange` method remains an internal unit-test seam;
/// production connections use `authenticatedExchange`.
public struct SignalingClient: Sendable {
    public struct AuthenticatedExchange: Sendable {
        public let answer: AuthenticatedSignalingAnswer
        public let route: RemoteConnectionRoute

        public init(
            answer: AuthenticatedSignalingAnswer,
            route: RemoteConnectionRoute
        ) {
            self.answer = answer
            self.route = route
        }
    }

    public typealias Transport = @Sendable (URLRequest, Data) async throws -> (Data, HTTPURLResponse)

    private let transport: Transport

    public init(transport: @escaping Transport = SignalingClient.defaultTransport) {
        self.transport = transport
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

    public func exchange(baseURL: URL, offer: SignalingOffer) async throws -> SignalingAnswer {
        guard let url = baseURL.appendingAPIPath("v1/rtc/offer") else {
            throw Error.transport("could not construct offer URL from \(baseURL)")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.addValue("application/json", forHTTPHeaderField: "Accept")
        let body: Data
        do {
            body = try JSONEncoder().encode(offer)
        } catch {
            throw Error.transport("encode offer: \(error)")
        }
        let (data, response): (Data, HTTPURLResponse)
        do {
            (data, response) = try await transport(request, body)
        } catch {
            throw Error.transport(String(describing: error))
        }
        guard (200..<300).contains(response.statusCode) else {
            let bodyString = String(data: data, encoding: .utf8) ?? ""
            throw Error.http(status: response.statusCode, body: bodyString)
        }
        do {
            return try JSONDecoder().decode(SignalingAnswer.self, from: data)
        } catch {
            throw Error.decode(String(describing: error))
        }
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
        now: @escaping @Sendable () -> Date = { Date() }
    ) async throws -> AuthenticatedExchange {
        let uniqueRoutes = Self.uniqueHTTPRoutes(routes)
        guard !uniqueRoutes.isEmpty else {
            throw Error.transport("paired host has no usable routes")
        }

        let clientNonce = Self.randomNonce()
        let probe = try SignalingChallengeRequest(
            clientDeviceID: clientDeviceID,
            clientNonce: clientNonce,
            signingKey: clientKey
        )
        guard
            let (route, challenge) = await firstValidChallenge(
                routes: uniqueRoutes,
                request: probe,
                hostDeviceID: hostDeviceID,
                hostPublicKey: hostPublicKey,
                now: now
            )
        else {
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
        var lastError: Error?
        for offerRoute in offerRoutes {
            do {
                let answer: AuthenticatedSignalingAnswer = try await post(
                    path: RemoteAccessProtocol.offerPath,
                    baseURL: offerRoute.baseURL,
                    body: offer
                )
                guard answer.isValid(for: offer, using: hostPublicKey) else {
                    throw Error.authentication("host answer signature is invalid")
                }
                return AuthenticatedExchange(answer: answer, route: offerRoute)
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as Error {
                lastError = error
            } catch {
                lastError = .transport(String(describing: error))
            }
        }
        throw lastError ?? Error.transport("all authenticated signaling routes failed")
    }

    private func firstValidChallenge(
        routes: [RemoteConnectionRoute],
        request: SignalingChallengeRequest,
        hostDeviceID: RemoteDeviceID,
        hostPublicKey: RemoteIdentityPublicKey,
        now: @escaping @Sendable () -> Date
    ) async -> (RemoteConnectionRoute, SignalingChallengeResponse)? {
        await withTaskGroup(
            of: (RemoteConnectionRoute, SignalingChallengeResponse)?.self
        ) { group in
            for route in routes {
                group.addTask {
                    guard
                        let response: SignalingChallengeResponse = try? await post(
                            path: RemoteAccessProtocol.challengePath,
                            baseURL: route.baseURL,
                            body: request
                        ),
                        response.isValid(
                            expectedHostID: hostDeviceID,
                            expectedClientID: request.clientDeviceID,
                            expectedClientNonce: request.clientNonce,
                            now: now(),
                            using: hostPublicKey
                        )
                    else {
                        return nil
                    }
                    return (route, response)
                }
            }
            while let candidate = await group.next() {
                if let candidate {
                    group.cancelAll()
                    return candidate
                }
            }
            return nil
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
