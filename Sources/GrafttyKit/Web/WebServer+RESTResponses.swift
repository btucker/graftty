import Foundation
import NIOHTTP1

extension WebServer {
    /// One HTTP answer, before it is written to the channel.
    struct RESTResponse: Equatable, Sendable {
        let status: HTTPResponseStatus
        let body: Data
        let contentType: String

        static let jsonContentType = "application/json; charset=utf-8"

        /// `{"error": "<msg>"}`. The client always gets JSON even for 4xx/5xx
        /// so it can render the error inline next to the form field without
        /// special-casing content type.
        static func error(_ status: HTTPResponseStatus, _ message: String) -> RESTResponse {
            struct ErrorBody: Codable { let error: String }
            let body = (try? JSONEncoder().encode(ErrorBody(error: message))) ?? Data(#"{"error":"unknown"}"#.utf8)
            return RESTResponse(status: status, body: body, contentType: jsonContentType)
        }

        /// `value` encoded as JSON, or a 500 if it cannot be.
        static func json<T: Encodable>(_ value: T, status: HTTPResponseStatus = .ok) -> RESTResponse {
            guard let body = try? JSONEncoder().encode(value) else { return error(.internalServerError, "encoding error") }
            return RESTResponse(status: status, body: body, contentType: jsonContentType)
        }

        static func text(_ text: String, status: HTTPResponseStatus = .ok) -> RESTResponse {
            RESTResponse(status: status, body: Data(text.utf8), contentType: "text/plain; charset=utf-8")
        }
    }
}

extension WebServer.CreateWorktreeOutcome {
    /// `POST /worktrees` (WEB-7.2).
    var restResponse: WebServer.RESTResponse {
        switch self {
        case .success(let response): .json(response)
        case .invalid(let message): .error(.badRequest, message)
        case .gitFailed(let message), .conflict(let message): .error(.conflict, message)
        case .internalFailure(let message): .error(.internalServerError, message)
        }
    }
}

extension WebServer.PullDefaultBranchOutcome {
    /// `POST /repos/default-branch/pull` (WEB-7.12).
    var restResponse: WebServer.RESTResponse {
        switch self {
        case .success(let response): .json(response)
        case .invalid(let message): .error(.badRequest, message)
        case .gitFailed(let message): .error(.conflict, message)
        case .internalFailure(let message): .error(.internalServerError, message)
        }
    }
}

extension WebServer.DeleteWorktreeOutcome {
    /// `POST /worktrees/delete` (WEB-7.8). A 409 says whether Force Delete
    /// can resolve it (`forceAllowed`) and, when it can, carries the
    /// `git status --short` the confirmation shows.
    var restResponse: WebServer.RESTResponse {
        struct ForceableBody: Codable { let error: String; let forceAllowed: Bool; let shortStatus: String }
        struct FinalBody: Codable { let error: String; let forceAllowed: Bool }
        switch self {
        case .success(let response): return .json(response)
        case .invalid(let message): return .error(.badRequest, message)
        case .notFound(let message): return .error(.notFound, message)
        case .gitFailedForceable(let stderr, let shortStatus):
            return .json(ForceableBody(error: stderr, forceAllowed: true, shortStatus: shortStatus), status: .conflict)
        case .gitFailedFinal(let stderr):
            return .json(FinalBody(error: stderr, forceAllowed: false), status: .conflict)
        case .internalFailure(let message): return .error(.internalServerError, message)
        }
    }
}
