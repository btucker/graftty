import Foundation
import GrafttyProtocol

enum WorktreePortClient {
    struct AuthenticationPreview: Identifiable {
        let id = UUID()
        let url: URL
        let callbackHost: String
    }
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static func authenticate(_ url: URL, in worktreeID: String,
                             send: (WorktreeManagementRequest) async throws -> WorktreeManagementResponse) async throws -> AuthenticationPreview {
        guard !worktreeID.hasPrefix("relay-worktree-") else {
            throw Failure(message: "Connect directly to this worktree's Mac to complete sign-in.")
        }
        guard let authentication = WorktreeAuthenticationURL(url: url),
              !WorktreeAuthenticationURL.isLoopbackHost(url.host ?? "") else {
            throw Failure(message: "This link has no supported local sign-in callback.")
        }
        let response = try await send(.openResource(worktreeID: worktreeID, request: .authenticate(url)))
        switch response {
        case .openResource(.authentication(let approvedURL, let callbackHost))
            where approvedURL == url && authentication.resolveCallbackHost(in: [
                WorktreePort(port: authentication.callbackPort, scope: .loopback, processName: "", host: callbackHost)
            ]) == callbackHost:
            return AuthenticationPreview(url: url, callbackHost: callbackHost)
        case .error(_, let message, _, _): throw Failure(message: message)
        default: throw Failure(message: "The host could not prepare sign-in. Update Graftty on the Mac and try again.")
        }
    }

    static func open(_ port: WorktreePort, in worktree: WorktreePanes,
                     send: (WorktreeManagementRequest) async throws -> WorktreeManagementResponse) async throws -> URL {
        guard worktree.route == nil, (worktree.origin?.relayDepth ?? 0) == 0 else {
            throw Failure(message: "Connect directly to this worktree's Mac to open its ports.")
        }
        guard port.port > 0, worktree.ports.contains(port), let expectedURL = port.url else {
            throw Failure(message: "This port is no longer listening in this worktree.")
        }
        let response = try await send(.openResource(worktreeID: worktree.path, request: .port(port.port)))
        switch response {
        case .openResource(.url(let url)) where url == expectedURL: return url
        case .error(_, let message, _, _): throw Failure(message: message)
        default: throw Failure(message: "The host could not open this worktree port. Update Graftty on the Mac and try again.")
        }
    }
}
