import Foundation
import GrafttyProtocol

public enum LANRemoteAccessMethod: Sendable, Equatable {
    case GET
    case POST
}

public struct LANRemoteAccessResponse: Sendable, Equatable {
    public var status: Int
    public var body: Data
    public var contentType: String

    public init(status: Int, body: Data, contentType: String) {
        self.status = status
        self.body = body
        self.contentType = contentType
    }
}

public struct LANRemoteAccessRateLimit: Sendable, Equatable {
    public let maxRequests: Int
    public let window: TimeInterval

    public static let disabled = LANRemoteAccessRateLimit(maxRequests: .max, window: .infinity)

    public init(maxRequests: Int, window: TimeInterval) {
        self.maxRequests = maxRequests
        self.window = window
    }
}

public enum LANSignalingOfferResult: Sendable {
    case authenticatedSuccess(AuthenticatedSignalingAnswer)
    case invalid(String)
    case unavailable(String)
    case hostBusy(String)
    case internalFailure(String)
}

public actor LANRemoteAccessRouteHandler {
    public typealias BeginPairing = @Sendable (TimeInterval, URL) async -> Result<PairingPayload, PairingErrorResponse>
    public typealias IntroduceHandler = @Sendable (PairingIntroduceRequest) async -> Result<PairingIntroduceResponse, PairingErrorResponse>
    public typealias AwaitOutcomeHandler = @Sendable (PairingAwaitOutcomeRequest) async -> Result<PairingOutcomeResponse, PairingErrorResponse>
    public typealias CancelPairingHandler = @Sendable (PairingCancelRequest) async -> Result<PairingOutcomeResponse, PairingErrorResponse>
    public typealias SignalingChallengeHandler =
        @Sendable (SignalingChallengeRequest) async -> Result<
            SignalingChallengeResponse, PairingErrorResponse
        >
    public typealias SignalingOfferHandler = @Sendable (AuthenticatedSignalingOffer) async -> LANSignalingOfferResult

    private enum RateLimitBucket: Hashable {
        case pairingBootstrap
        case pairingIntroduce
        case pairingAwaitOutcome
        case rtcChallenge
        case rtcSignaling
    }

    private struct RateLimitKey: Hashable {
        var bucket: RateLimitBucket
        var source: String
    }

    private let lanBaseURLProvider: @Sendable () -> URL
    private let validFor: TimeInterval
    private let rateLimit: LANRemoteAccessRateLimit
    private let now: @Sendable () -> Date
    private let beginPairing: BeginPairing
    private let handleIntroduce: IntroduceHandler
    private let handleAwaitOutcome: AwaitOutcomeHandler
    private let handleCancelPairing: CancelPairingHandler
    private let handleSignalingChallenge: SignalingChallengeHandler
    private let handleSignalingOffer: SignalingOfferHandler

    private var recentLimitedRequests: [RateLimitKey: [Date]] = [:]
    private static let maxTrackedRateLimitKeys = 1_024

    public init(
        lanBaseURLProvider: @escaping @Sendable () -> URL,
        validFor: TimeInterval = 300,
        rateLimit: LANRemoteAccessRateLimit = .disabled,
        now: @escaping @Sendable () -> Date = { Date() },
        beginPairing: @escaping BeginPairing,
        handleIntroduce: @escaping IntroduceHandler,
        handleAwaitOutcome: @escaping AwaitOutcomeHandler,
        handleCancelPairing: @escaping CancelPairingHandler = { _ in
            .failure(PairingErrorResponse(
                code: .noActiveSession,
                error: "no pairing session is active"
            ))
        },
        handleSignalingChallenge: @escaping SignalingChallengeHandler,
        handleSignalingOffer: @escaping SignalingOfferHandler
    ) {
        self.lanBaseURLProvider = lanBaseURLProvider
        self.validFor = validFor
        self.rateLimit = rateLimit
        self.now = now
        self.beginPairing = beginPairing
        self.handleIntroduce = handleIntroduce
        self.handleAwaitOutcome = handleAwaitOutcome
        self.handleCancelPairing = handleCancelPairing
        self.handleSignalingChallenge = handleSignalingChallenge
        self.handleSignalingOffer = handleSignalingOffer
    }

    public func handle(
        method: LANRemoteAccessMethod,
        path: String,
        body: Data,
        requestBaseURL: URL? = nil,
        source: String = "unknown"
    ) async -> LANRemoteAccessResponse {
        switch path {
        case "/v2/pairing/begin":
            guard method == .POST else {
                return Self.errorResponse(
                    status: 405,
                    code: .wrongSessionState,
                    message: "method not allowed"
                )
            }
            guard permitLimitedRequest(in: .pairingBootstrap, source: source) else {
                return Self.rateLimitedResponse()
            }
            let requestPairingRouteBase = requestBaseURL.map { Self.pairingRouteBase(from: $0) }
            let pairingRouteBase: URL
            if let requestPairingRouteBase, Self.isClientReachable(requestPairingRouteBase) {
                pairingRouteBase = requestPairingRouteBase
            } else {
                pairingRouteBase = Self.pairingRouteBase(from: lanBaseURLProvider())
            }
            guard Self.isClientReachable(pairingRouteBase) else {
                return Self.errorResponse(
                    status: 500,
                    code: .internalError,
                    message: "LAN pairing base URL is not client-reachable"
                )
            }
            let result = await beginPairing(validFor, pairingRouteBase)
            return Self.pairingResultResponse(result, successStatus: 200)

        case "/v2/pairing/introduce":
            guard method == .POST else {
                return Self.errorResponse(
                    status: 405,
                    code: .wrongSessionState,
                    message: "method not allowed"
                )
            }
            guard permitLimitedRequest(in: .pairingIntroduce, source: source) else {
                return Self.rateLimitedResponse()
            }
            let request: PairingIntroduceRequest
            do {
                request = try Self.decoder.decode(PairingIntroduceRequest.self, from: body)
            } catch {
                return Self.errorResponse(
                    status: 400,
                    code: .internalError,
                    message: "malformed pairing introduce request: \(error.localizedDescription)"
                )
            }
            let result = await handleIntroduce(request)
            return Self.pairingResultResponse(result, successStatus: 200)

        case "/v2/pairing/await-outcome":
            guard method == .POST else {
                return Self.errorResponse(
                    status: 405,
                    code: .wrongSessionState,
                    message: "method not allowed"
                )
            }
            guard permitLimitedRequest(in: .pairingAwaitOutcome, source: source) else {
                return Self.rateLimitedResponse()
            }
            let request: PairingAwaitOutcomeRequest
            do {
                request = try Self.decoder.decode(PairingAwaitOutcomeRequest.self, from: body)
            } catch {
                return Self.errorResponse(
                    status: 400,
                    code: .internalError,
                    message: "malformed pairing await-outcome request: \(error.localizedDescription)"
                )
            }
            let result = await handleAwaitOutcome(request)
            return Self.pairingResultResponse(result, successStatus: 200)

        case "/v2/pairing/cancel":
            guard method == .POST else {
                return Self.errorResponse(
                    status: 405,
                    code: .wrongSessionState,
                    message: "method not allowed"
                )
            }
            let request: PairingCancelRequest
            do {
                request = try Self.decoder.decode(PairingCancelRequest.self, from: body)
            } catch {
                return Self.errorResponse(
                    status: 400,
                    code: .internalError,
                    message: "malformed pairing cancel request"
                )
            }
            return Self.pairingResultResponse(
                await handleCancelPairing(request),
                successStatus: 200
            )

        case "/v2/rtc/challenge":
            guard method == .POST else {
                return Self.errorResponse(
                    status: 405,
                    code: .wrongSessionState,
                    message: "method not allowed"
                )
            }
            guard permitLimitedRequest(in: .rtcChallenge, source: source) else {
                return Self.rateLimitedResponse()
            }
            return await handleRTCChallenge(body: body)

        case "/v2/rtc/offer":
            guard method == .POST else {
                return Self.errorResponse(
                    status: 405,
                    code: .wrongSessionState,
                    message: "method not allowed"
                )
            }
            guard permitLimitedRequest(in: .rtcSignaling, source: source) else {
                return Self.rateLimitedResponse()
            }
            return await handleRTCOffer(body: body)

        case "/v1/rtc/offer":
            return Self.errorResponse(
                status: 426,
                code: .unsupportedVersion,
                message: "protocol v2 and a new pairing are required"
            )

        default:
            return Self.errorResponse(
                status: 404,
                code: .noActiveSession,
                message: "route not found"
            )
        }
    }

    private func handleRTCChallenge(body: Data) async -> LANRemoteAccessResponse {
        let request: SignalingChallengeRequest
        do {
            request = try Self.decoder.decode(SignalingChallengeRequest.self, from: body)
        } catch {
            return Self.errorResponse(
                status: 400,
                code: .authenticationFailed,
                message: "malformed signaling challenge request"
            )
        }
        return Self.pairingResultResponse(
            await handleSignalingChallenge(request),
            successStatus: 200
        )
    }

    private func handleRTCOffer(body: Data) async -> LANRemoteAccessResponse {
        let offer: AuthenticatedSignalingOffer
        do {
            offer = try Self.decoder.decode(AuthenticatedSignalingOffer.self, from: body)
        } catch {
            return Self.errorResponse(
                status: 400,
                code: .authenticationFailed,
                message: "malformed signaling offer: \(error.localizedDescription)"
            )
        }

        switch await handleSignalingOffer(offer) {
        case .authenticatedSuccess(let answer):
            return Self.jsonResponse(status: 200, value: answer)
        case .invalid(let message):
            return Self.errorResponse(status: 400, code: .internalError, message: message)
        case .unavailable(let message):
            return Self.errorResponse(status: 503, code: .hostBusy, message: message)
        case .hostBusy(let message):
            return Self.errorResponse(status: 503, code: .hostBusy, message: message)
        case .internalFailure(let message):
            return Self.errorResponse(status: 500, code: .internalError, message: message)
        }
    }

    private func permitLimitedRequest(
        in bucket: RateLimitBucket,
        source: String
    ) -> Bool {
        guard rateLimit.maxRequests != Int.max else {
            return true
        }

        let instant = now()
        let earliestAllowed = instant.addingTimeInterval(-rateLimit.window)
        let key = RateLimitKey(bucket: bucket, source: source)
        if recentLimitedRequests[key] == nil,
           recentLimitedRequests.count >= Self.maxTrackedRateLimitKeys,
           let oldestKey = recentLimitedRequests.min(by: {
               ($0.value.last ?? .distantPast) < ($1.value.last ?? .distantPast)
           })?.key {
            recentLimitedRequests[oldestKey] = nil
        }
        var bucketRequests = recentLimitedRequests[key] ?? []
        bucketRequests.removeAll { $0 < earliestAllowed }

        guard bucketRequests.count < rateLimit.maxRequests else {
            recentLimitedRequests[key] = bucketRequests
            return false
        }
        bucketRequests.append(instant)
        recentLimitedRequests[key] = bucketRequests
        return true
    }

    private static let encoder = JSONEncoder.iso8601()
    private static let decoder = JSONDecoder.iso8601()

    private static func pairingRouteBase(from baseURL: URL) -> URL {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            return baseURL
        }

        components.query = nil
        components.fragment = nil
        let path = components.path
        if path == PairingRoutes.basePath {
            return components.url ?? baseURL
        }
        let trimmed = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if trimmed.isEmpty {
            components.path = PairingRoutes.basePath
        } else {
            components.path = "/" + trimmed + PairingRoutes.basePath
        }
        return components.url ?? baseURL
    }

    private static func isClientReachable(_ url: URL) -> Bool {
        guard let host = url.host(percentEncoded: false)?.lowercased() else {
            return false
        }
        guard host != "0.0.0.0", host != "::", host != "localhost" else {
            return false
        }
        guard !host.hasPrefix("127.") else {
            return false
        }
        return host != "::1"
    }

    private static func pairingResultResponse<T: Encodable>(
        _ result: Result<T, PairingErrorResponse>,
        successStatus: Int
    ) -> LANRemoteAccessResponse {
        switch result {
        case .success(let value):
            return jsonResponse(status: successStatus, value: value)
        case .failure(let error):
            return errorResponse(status: status(for: error.code), error: error)
        }
    }

    private static func status(for code: PairingErrorResponse.Code) -> Int {
        switch code {
        case .pairingBusy, .wrongSessionState:
            return 409
        case .rateLimited:
            return 429
        case .hostBusy:
            return 503
        case .authenticationFailed:
            return 401
        case .replayDetected:
            return 409
        case .unsupportedVersion:
            return 426
        case .unknownNonce, .noActiveSession, .sessionExpired, .internalError:
            return 400
        }
    }

    private static func rateLimitedResponse() -> LANRemoteAccessResponse {
        errorResponse(
            status: 429,
            code: .rateLimited,
            message: "too many LAN remote access requests; retry later"
        )
    }

    private static func errorResponse(
        status: Int,
        code: PairingErrorResponse.Code,
        message: String
    ) -> LANRemoteAccessResponse {
        errorResponse(
            status: status,
            error: PairingErrorResponse(code: code, error: message)
        )
    }

    private static func errorResponse(status: Int, error: PairingErrorResponse) -> LANRemoteAccessResponse {
        jsonResponse(status: status, value: error)
    }

    private static func jsonResponse<T: Encodable>(status: Int, value: T) -> LANRemoteAccessResponse {
        do {
            let data = try encoder.encode(value)
            return LANRemoteAccessResponse(
                status: status,
                body: data,
                contentType: "application/json; charset=utf-8"
            )
        } catch {
            let fallback = #"{"code":"internalError","error":"encoding error"}"#.data(using: .utf8) ?? Data()
            return LANRemoteAccessResponse(
                status: 500,
                body: fallback,
                contentType: "application/json; charset=utf-8"
            )
        }
    }
}
