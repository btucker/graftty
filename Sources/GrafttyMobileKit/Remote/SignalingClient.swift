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
        case transport(String)
    }

    public func exchange(baseURL: URL, offer: SignalingOffer) async throws -> SignalingAnswer {
        let url = baseURL.appendingPathComponent("v1").appendingPathComponent("rtc").appendingPathComponent("offer")
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
        let (data, response) = try await URLSession.shared.upload(for: request, from: body)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        return (data, http)
    }
}
#endif
