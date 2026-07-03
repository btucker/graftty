#if canImport(UIKit)
import Foundation
import GrafttyProtocol

/// Posts a `SignalingOffer` JSON to the host's `/v1/rtc/offer` endpoint
/// and decodes the `SignalingAnswer` reply. Pure HTTP transport — no
/// WebRTC types — so the type can be unit-tested by injecting a fake
/// `URLSession`-like callable.
public struct SignalingClient: Sendable {

    public typealias Transport = @Sendable (URLRequest, Data) async throws -> (Data, HTTPURLResponse)

    private let transport: Transport

    public init(transport: @escaping Transport = SignalingClient.defaultTransport) {
        self.transport = transport
    }

    public enum Error: Swift.Error, Equatable, Sendable {
        case http(status: Int, body: String)
        case decode(String)
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
    /// `/v1/rtc/offer` in well under a second. 10s is generous headroom
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
#endif
