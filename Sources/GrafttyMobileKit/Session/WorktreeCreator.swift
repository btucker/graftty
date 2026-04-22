#if canImport(UIKit)
import Foundation
import GrafttyProtocol

/// `POST <baseURL>/worktrees` with a `CreateWorktreeRequest` body →
/// `CreateWorktreeResponse`. Mirrors the native Mac sheet: on success
/// the caller navigates into the new worktree's first pane.
///
/// Error discrimination: `git worktree add` failures (branch already
/// exists, ref-format rejection) come back as HTTP 409 with
/// `{error: "<stderr>"}`. We surface the stderr string verbatim so the
/// form can show the user what git complained about; all other non-2xx
/// responses collapse into a generic `http(code, message)` with the
/// body's `error` field when present, or a placeholder otherwise.
public enum WorktreeCreator {

    public enum CreateError: Error, Equatable {
        case forbidden
        case invalidResponse
        case http(Int, String)
        case decode
        case transport
    }

    public static func request(
        baseURL: URL,
        body: CreateWorktreeRequest
    ) throws -> URLRequest {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        let existing = components?.path ?? ""
        components?.path = existing.hasSuffix("/") ? existing + "worktrees" : existing + "/worktrees"
        guard let url = components?.url else {
            throw CreateError.invalidResponse
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.httpBody = try JSONEncoder().encode(body)
        return req
    }

    public static func decodeSuccess(_ data: Data) throws -> CreateWorktreeResponse {
        try JSONDecoder().decode(CreateWorktreeResponse.self, from: data)
    }

    /// Parse the `{error: "<msg>"}` body and return the raw message, or
    /// nil if the body isn't the expected shape. A malformed error body
    /// shouldn't mask the status-code-level failure, so callers fall
    /// back to the HTTP code when this returns nil.
    public static func decodeError(_ data: Data) -> String? {
        guard let body = try? JSONDecoder().decode(CreateWorktreeErrorBody.self, from: data) else {
            return nil
        }
        return body.error
    }

    public static func create(
        baseURL: URL,
        body: CreateWorktreeRequest,
        session: URLSession = .shared
    ) async throws -> CreateWorktreeResponse {
        let req: URLRequest
        do {
            req = try request(baseURL: baseURL, body: body)
        } catch {
            throw CreateError.transport
        }
        do {
            let (data, response) = try await session.data(for: req)
            guard let http = response as? HTTPURLResponse else { throw CreateError.transport }
            if http.statusCode == 403 { throw CreateError.forbidden }
            if (200..<300).contains(http.statusCode) {
                do {
                    return try decodeSuccess(data)
                } catch {
                    throw CreateError.decode
                }
            }
            let msg = decodeError(data) ?? "HTTP \(http.statusCode)"
            throw CreateError.http(http.statusCode, msg)
        } catch let e as CreateError {
            throw e
        } catch {
            throw CreateError.transport
        }
    }
}
#endif
