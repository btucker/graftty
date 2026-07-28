#if canImport(UIKit)
import Foundation
import GrafttyProtocol

public enum DeleteWorktreeClient {

    public struct Request: Encodable, Sendable, Equatable {
        public let worktreePath: String
        public let force: Bool

        public init(worktreePath: String, force: Bool) {
            self.worktreePath = worktreePath
            self.force = force
        }
    }

    public struct Response: Decodable, Sendable, Equatable {
        public let dismissed: Bool

        public init(dismissed: Bool) {
            self.dismissed = dismissed
        }
    }

    /// Conflict-response shape (HTTP 409). `forceAllowed: true` means
    /// the failure is one `--force` could resolve and the client should
    /// surface a Force Delete confirmation; `false` means the failure
    /// is terminal for this attempt.
    public struct ConflictBody: Decodable, Sendable, Equatable {
        public let error: String
        public let forceAllowed: Bool
        public let shortStatus: String?
    }

    public enum DeleteError: Error, Equatable {
        case invalid(String)
        case notFound
        /// 409 with `forceAllowed: true` — caller should present a
        /// Force Delete confirmation and retry with `force: true`.
        case gitFailedForceable(stderr: String, shortStatus: String)
        /// 409 with `forceAllowed: false` — non-retryable; surface
        /// `stderr` to the user as a terminal error.
        case gitFailedFinal(String)
        case serverInternal(String)
        case unavailable(String)
        case forbidden
        case http(Int)
        case decode
        case transport
    }

    public static func request(baseURL: URL, body: Request) throws -> URLRequest {
        guard let url = baseURL.appendingAPIPath("worktrees/delete") else {
            throw DeleteError.transport
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(
            RemoteWorktreeFeatures.oneHopRelay,
            forHTTPHeaderField: RemoteWorktreeFeatures.headerName
        )
        do {
            req.httpBody = try JSONEncoder().encode(body)
        } catch {
            throw DeleteError.transport
        }
        return req
    }

    public static func decodeResponse(_ data: Data) throws -> Response {
        try JSONDecoder().decode(Response.self, from: data)
    }

    public static func decodeConflict(_ data: Data) -> ConflictBody? {
        try? JSONDecoder().decode(ConflictBody.self, from: data)
    }

    public static func decodeErrorMessage(_ data: Data) -> String? {
        APIErrorEnvelope.decode(data)
    }

    public static func delete(
        baseURL: URL,
        body: Request,
        session: URLSession = .shared
    ) async throws -> Response {
        let req = try request(baseURL: baseURL, body: body)
        do {
            let (data, response) = try await session.data(for: req)
            guard let http = response as? HTTPURLResponse else { throw DeleteError.transport }
            switch http.statusCode {
            case 200..<300:
                do {
                    return try decodeResponse(data)
                } catch {
                    throw DeleteError.decode
                }
            case 400:
                throw DeleteError.invalid(decodeErrorMessage(data) ?? "invalid request")
            case 403:
                throw DeleteError.forbidden
            case 404:
                throw DeleteError.notFound
            case 409:
                guard let conflict = decodeConflict(data) else {
                    throw DeleteError.gitFailedFinal(
                        decodeErrorMessage(data) ?? "git worktree remove failed"
                    )
                }
                if conflict.forceAllowed {
                    throw DeleteError.gitFailedForceable(
                        stderr: conflict.error,
                        shortStatus: conflict.shortStatus ?? ""
                    )
                }
                throw DeleteError.gitFailedFinal(conflict.error)
            case 500:
                throw DeleteError.serverInternal(decodeErrorMessage(data) ?? "server error")
            case 503:
                throw DeleteError.unavailable(decodeErrorMessage(data) ?? "worktree deletion not available")
            default:
                throw DeleteError.http(http.statusCode)
            }
        } catch let e as DeleteError {
            throw e
        } catch {
            throw DeleteError.transport
        }
    }
}

extension DeleteWorktreeClient.DeleteError {
    /// User-facing message for inline toasts. `gitFailedForceable`
    /// returns nil because callers render a Force Delete dialog instead
    /// of a flat toast.
    public var userMessage: String? {
        switch self {
        case .invalid(let m): return m
        case .gitFailedFinal(let m): return m
        case .serverInternal(let m): return m
        case .unavailable(let m): return m
        case .notFound: return "Worktree no longer exists."
        case .forbidden: return "Not authorized — is this device on your tailnet?"
        case .http(let code): return "HTTP \(code)"
        case .decode: return "The server sent a response this version can't read."
        case .transport: return "Couldn't reach the server."
        case .gitFailedForceable: return nil
        }
    }
}
#endif
