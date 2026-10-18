import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import GrafttyProtocol

/// Account-authenticated HTTPS API for the existing Graftty-server relay.
/// Device credentials are distinct from local paired-host identities.
public struct PushRelayClient: Sendable {
    public typealias Transport = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)
    public enum Failure: Error, Equatable {
        case invalidServerURL
        case invalidCredential
        case httpStatus(Int)
        case invalidResponse
    }
    public enum DeviceKind: String, Encodable, Sendable { case mac, phone }
    public struct Registration: Decodable, Sendable {
        public let deviceID: String
        public let deviceToken: String
        enum CodingKeys: String, CodingKey {
            case deviceID = "device_id", deviceToken = "device_token"
        }
    }
    public struct AccountStatus: Decodable, Sendable {
        public struct Phone: Decodable, Sendable {
            public let deviceID: String
            public let displayName: String
            public let publicKey: Data
            enum CodingKeys: String, CodingKey {
                case deviceID = "device_id", displayName = "display_name", publicKey = "hpke_pub"
            }
        }
        public let phones: [Phone]
    }

    private let baseURL: URL
    private let transport: Transport

    public init(baseURL: URL, transport: @escaping Transport = Self.defaultTransport) throws {
        guard baseURL.scheme?.lowercased() == "https", baseURL.host?.isEmpty == false,
              baseURL.user == nil, baseURL.password == nil, baseURL.query == nil, baseURL.fragment == nil,
              baseURL.path.isEmpty || baseURL.path == "/" else { throw Failure.invalidServerURL }
        self.baseURL = baseURL
        self.transport = transport
    }

    public func register(enrollmentToken: String, kind: DeviceKind, displayName: String,
                         apnsToken: String? = nil, publicKey: Data? = nil) async throws -> Registration {
        struct Body: Encodable {
            let kind: DeviceKind
            let display_name: String
            let apns_token: String?
            let hpke_pub_b64: Data?
        }
        let data = try JSONEncoder().encode(Body(kind: kind, display_name: displayName,
            apns_token: apnsToken, hpke_pub_b64: publicKey))
        let result: Registration = try await decode(method: "POST", path: "v1/devices/register",
            token: enrollmentToken, body: data)
        guard !result.deviceID.isEmpty, !result.deviceToken.isEmpty else { throw Failure.invalidResponse }
        return result
    }

    public func updatePhone(deviceID: String, deviceToken: String, apnsToken: String,
                            publicKey: Data) async throws {
        // IDs are opaque path components; reject path/query delimiters rather
        // than allowing a compromised response to choose a different endpoint.
        guard !deviceID.isEmpty, deviceID.utf8.allSatisfy({
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45
        }) else { throw Failure.invalidResponse }
        struct Body: Encodable { let apns_token: String; let hpke_pub: Data }
        let data = try JSONEncoder().encode(Body(apns_token: apnsToken, hpke_pub: publicKey))
        _ = try await execute(method: "PATCH", path: "v1/devices/" + deviceID, token: deviceToken, body: data)
    }

    public func status(deviceToken: String) async throws -> AccountStatus {
        try await decode(method: "GET", path: "v1/status", token: deviceToken)
    }

    public func send(_ push: PushRelayRequest, deviceToken: String) async throws -> PushRelayResponse {
        try await decode(method: "POST", path: "v1/push", token: deviceToken, body: JSONEncoder().encode(push))
    }

    private func decode<T: Decodable>(method: String, path: String, token: String, body: Data? = nil) async throws -> T {
        try await JSONDecoder().decode(T.self, from: execute(method: method, path: path, token: token, body: body))
    }

    private func execute(method: String, path: String, token: String, body: Data?) async throws -> Data {
        guard !token.isEmpty, !token.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.union(.controlCharacters).contains($0) })
        else { throw Failure.invalidCredential }
        var request = URLRequest(url: baseURL.appendingPathComponent(path), cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.httpMethod = method
        request.httpBody = body
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let (data, response) = try await transport(request)
        guard (200..<300).contains(response.statusCode) else { throw Failure.httpStatus(response.statusCode) }
        return data
    }

    public static func defaultTransport(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let session = URLSession(configuration: .ephemeral, delegate: RejectRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw Failure.invalidResponse }
        return (data, http)
    }
}

private final class RejectRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
