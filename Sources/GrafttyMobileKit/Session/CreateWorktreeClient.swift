#if canImport(UIKit)
import Foundation

public enum CreateWorktreeClient {

    public struct Request: Encodable, Sendable, Equatable {
        public let repoPath: String
        public let worktreeName: String
        public let branchName: String
        public let existing: Bool

        public init(
            repoPath: String,
            worktreeName: String,
            branchName: String,
            existing: Bool = false
        ) {
            self.repoPath = repoPath
            self.worktreeName = worktreeName
            self.branchName = branchName
            self.existing = existing
        }
    }

    public struct Response: Decodable, Sendable, Equatable {
        public let sessionName: String
        public let worktreePath: String

        public init(sessionName: String, worktreePath: String) {
            self.sessionName = sessionName
            self.worktreePath = worktreePath
        }
    }

    public enum CreateError: Error, Equatable {
        case invalid(String)
        case gitFailed(String)
        case serverInternal(String)
        case unavailable(String)
        case forbidden
        case http(Int)
        case decode
        case transport
    }

    public static func request(baseURL: URL, body: Request) throws -> URLRequest {
        guard let url = baseURL.appendingAPIPath("worktrees") else {
            throw CreateError.transport
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        do {
            req.httpBody = try JSONEncoder().encode(body)
        } catch {
            throw CreateError.transport
        }
        return req
    }

    public static func decodeErrorMessage(_ data: Data) -> String? {
        struct Envelope: Decodable { let error: String? }
        return (try? JSONDecoder().decode(Envelope.self, from: data))?.error
    }

    public static func decodeResponse(_ data: Data) throws -> Response {
        try JSONDecoder().decode(Response.self, from: data)
    }

    public static func create(
        baseURL: URL,
        body: Request,
        session: URLSession = .shared
    ) async throws -> Response {
        let req = try request(baseURL: baseURL, body: body)
        do {
            let (data, response) = try await session.data(for: req)
            guard let http = response as? HTTPURLResponse else { throw CreateError.transport }
            switch http.statusCode {
            case 200..<300:
                do {
                    return try decodeResponse(data)
                } catch {
                    throw CreateError.decode
                }
            case 400:
                throw CreateError.invalid(decodeErrorMessage(data) ?? "invalid request")
            case 403:
                throw CreateError.forbidden
            case 409:
                throw CreateError.gitFailed(decodeErrorMessage(data) ?? "git worktree add failed")
            case 500:
                throw CreateError.serverInternal(decodeErrorMessage(data) ?? "server error")
            case 503:
                throw CreateError.unavailable(decodeErrorMessage(data) ?? "worktree creation not available")
            default:
                throw CreateError.http(http.statusCode)
            }
        } catch let e as CreateError {
            throw e
        } catch {
            throw CreateError.transport
        }
    }
}

extension CreateWorktreeClient.CreateError {
    public var userMessage: String {
        switch self {
        case .invalid(let msg): return msg
        case .gitFailed(let msg): return msg
        case .serverInternal(let msg): return msg
        case .unavailable(let msg): return msg
        case .forbidden: return "Not authorized — is this device on your tailnet?"
        case .http(let code): return "HTTP \(code)"
        case .decode: return "The server sent a response this version can't read."
        case .transport: return "Couldn't reach the server."
        }
    }
}
#endif
