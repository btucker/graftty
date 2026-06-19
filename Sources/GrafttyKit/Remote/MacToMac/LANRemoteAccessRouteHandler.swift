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
    case success(SignalingAnswer)
    case invalid(String)
    case unavailable(String)
    case hostBusy(String)
    case internalFailure(String)
}

public actor LANRemoteAccessRouteHandler {
    public typealias BeginPairing = @Sendable (TimeInterval, URL) async -> Result<PairingPayload, PairingErrorResponse>
    public typealias IntroduceHandler = @Sendable (PairingIntroduceRequest) async -> Result<PairingIntroduceResponse, PairingErrorResponse>
    public typealias AwaitOutcomeHandler = @Sendable (PairingAwaitOutcomeRequest) async -> Result<PairingOutcomeResponse, PairingErrorResponse>
    public typealias SignalingOfferHandler = @Sendable (SignalingOffer) async -> LANSignalingOfferResult

    private enum RateLimitBucket: Hashable {
        case pairingBootstrap
        case pairingIntroduce
        case pairingAwaitOutcome
        case rtcSignaling
    }

    private let lanBaseURLProvider: @Sendable () -> URL
    private let validFor: TimeInterval
    private let rateLimit: LANRemoteAccessRateLimit
    private let now: @Sendable () -> Date
    private let beginPairing: BeginPairing
    private let handleIntroduce: IntroduceHandler
    private let handleAwaitOutcome: AwaitOutcomeHandler
    private let handleSignalingOffer: SignalingOfferHandler

    private var recentLimitedRequests: [RateLimitBucket: [Date]] = [:]

    public init(
        lanBaseURLProvider: @escaping @Sendable () -> URL,
        validFor: TimeInterval = 300,
        rateLimit: LANRemoteAccessRateLimit = .disabled,
        now: @escaping @Sendable () -> Date = { Date() },
        beginPairing: @escaping BeginPairing,
        handleIntroduce: @escaping IntroduceHandler,
        handleAwaitOutcome: @escaping AwaitOutcomeHandler,
        handleSignalingOffer: @escaping SignalingOfferHandler
    ) {
        self.lanBaseURLProvider = lanBaseURLProvider
        self.validFor = validFor
        self.rateLimit = rateLimit
        self.now = now
        self.beginPairing = beginPairing
        self.handleIntroduce = handleIntroduce
        self.handleAwaitOutcome = handleAwaitOutcome
        self.handleSignalingOffer = handleSignalingOffer
    }

    public func handle(
        method: LANRemoteAccessMethod,
        path: String,
        body: Data,
        requestBaseURL: URL? = nil
    ) async -> LANRemoteAccessResponse {
        switch path {
        case "/v1/pairing/begin":
            guard method == .POST else {
                return Self.errorResponse(
                    status: 405,
                    code: .wrongSessionState,
                    message: "method not allowed"
                )
            }
            guard permitLimitedRequest(in: .pairingBootstrap) else {
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

        case "/v1/pairing/introduce":
            guard method == .POST else {
                return Self.errorResponse(
                    status: 405,
                    code: .wrongSessionState,
                    message: "method not allowed"
                )
            }
            guard permitLimitedRequest(in: .pairingIntroduce) else {
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

        case "/v1/pairing/await-outcome":
            guard method == .POST else {
                return Self.errorResponse(
                    status: 405,
                    code: .wrongSessionState,
                    message: "method not allowed"
                )
            }
            guard permitLimitedRequest(in: .pairingAwaitOutcome) else {
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

        case "/v1/rtc/offer":
            guard method == .POST else {
                return Self.errorResponse(
                    status: 405,
                    code: .wrongSessionState,
                    message: "method not allowed"
                )
            }
            guard permitLimitedRequest(in: .rtcSignaling) else {
                return Self.rateLimitedResponse()
            }
            return await handleRTCOffer(body: body)

        default:
            return Self.errorResponse(
                status: 404,
                code: .noActiveSession,
                message: "route not found"
            )
        }
    }

    private func handleRTCOffer(body: Data) async -> LANRemoteAccessResponse {
        let offer: SignalingOffer
        do {
            offer = try Self.decoder.decode(SignalingOffer.self, from: body)
        } catch {
            return Self.errorResponse(
                status: 400,
                code: .internalError,
                message: "malformed signaling offer: \(error.localizedDescription)"
            )
        }

        switch await handleSignalingOffer(offer) {
        case .success(let answer):
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

    private func permitLimitedRequest(in bucket: RateLimitBucket) -> Bool {
        guard rateLimit.maxRequests != Int.max else {
            return true
        }

        let instant = now()
        let earliestAllowed = instant.addingTimeInterval(-rateLimit.window)
        var bucketRequests = recentLimitedRequests[bucket] ?? []
        bucketRequests.removeAll { $0 < earliestAllowed }

        guard bucketRequests.count < rateLimit.maxRequests else {
            recentLimitedRequests[bucket] = bucketRequests
            return false
        }
        bucketRequests.append(instant)
        recentLimitedRequests[bucket] = bucketRequests
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
        if path == "/v1/pairing" {
            return components.url ?? baseURL
        }
        let trimmed = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if trimmed.isEmpty {
            components.path = "/v1/pairing"
        } else {
            components.path = "/" + trimmed + "/v1/pairing"
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
        case .unsupportedVersion, .unknownNonce, .noActiveSession, .sessionExpired, .internalError:
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
