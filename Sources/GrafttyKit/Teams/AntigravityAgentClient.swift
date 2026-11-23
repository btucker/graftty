import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum AntigravityAgentClientError: Error, Equatable, CustomStringConvertible {
    case http(status: Int, body: String)
    case invalidResponse

    public var description: String {
        switch self {
        case .http(let status, let body):
            return body.isEmpty ? "HTTP \(status)" : "HTTP \(status): \(body)"
        case .invalidResponse:
            return "invalid response"
        }
    }
}

public protocol AntigravityAgentClienting: Sendable {
    /// Adds `content` to the conversation's inbox. The agent wakes if idle
    /// and reads the message at its next step if busy.
    func send(content: String, title: String, conversationID: String, port: Int, token: String) async throws
}

/// Client for the Connect-RPC server every `agy` process runs on a loopback
/// port. The endpoints are undocumented provider internals, observed on AGY
/// 1.5.13; callers keep hook delivery as the fallback when a call fails.
public struct AntigravityAgentClient: AntigravityAgentClienting {
    static let service = "exa.language_server_pb.LanguageServerService"
    static let tokenHeader = "x-codeium-csrf-token"

    public init() {}

    public func send(content: String, title: String, conversationID: String, port: Int, token: String) async throws {
        let request = try Self.sendRequest(
            content: content, title: title, conversationID: conversationID, port: port, token: token
        )
        let (data, response) = try await Self.session.data(for: request)
        try Self.validate(response, data: data)
    }

    /// Whether the server on `port` accepts `token` and knows the
    /// conversation. Blocks the calling thread; only for hook processes.
    public static func servesConversation(
        _ conversationID: String,
        port: Int,
        token: String,
        timeout: TimeInterval = 1
    ) -> Bool {
        guard var request = try? request(
            method: "GetConversationMetadata", body: ["conversationId": conversationID], port: port, token: token
        ) else { return false }
        request.timeoutInterval = timeout
        let done = DispatchSemaphore(value: 0)
        let accepted = Accepted()
        let task = session.dataTask(with: request) { _, response, _ in
            accepted.set((response as? HTTPURLResponse)?.statusCode == 200)
            done.signal()
        }
        task.resume()
        if done.wait(timeout: .now() + timeout + 0.5) == .timedOut { task.cancel() }
        return accepted.value
    }

    static func sendRequest(
        content: String,
        title: String,
        conversationID: String,
        port: Int,
        token: String
    ) throws -> URLRequest {
        try request(method: "SendAgentMessage", body: [
            "content": content,
            "recipient": conversationID,
            "senderId": "graftty",
            "displayTitle": title,
        ], port: port, token: token)
    }

    private static func request(method: String, body: [String: String], port: Int, token: String) throws -> URLRequest {
        guard let url = URL(string: "http://127.0.0.1:\(port)/\(service)/\(method)") else {
            throw AntigravityAgentClientError.invalidResponse
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(token, forHTTPHeaderField: tokenHeader)
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        return request
    }

    private static func validate(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else { throw AntigravityAgentClientError.invalidResponse }
        guard http.statusCode == 200 else {
            throw AntigravityAgentClientError.http(
                status: http.statusCode,
                body: String(String(decoding: data, as: UTF8.self).prefix(200))
            )
        }
    }

    /// No cache, cookies, or proxy: the only peer is a loopback server.
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        return URLSession(configuration: configuration)
    }()

    private final class Accepted: @unchecked Sendable {
        private let lock = NSLock()
        private var accepted = false
        func set(_ value: Bool) { lock.withLock { accepted = value } }
        var value: Bool { lock.withLock { accepted } }
    }
}
