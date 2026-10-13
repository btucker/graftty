#if canImport(UIKit)
import Foundation
import GrafttyProtocol

enum AgentCompletionsFetcher {
    enum FetchError: Error, Equatable {
        case invalidResponse
        case http(Int)
        case server(String)
    }

    static func request(baseURL: URL, worktreePath: String? = nil) throws -> URLRequest {
        guard let url = baseURL.appendingAPIPath("agent-completions") else {
            throw FetchError.invalidResponse
        }
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw FetchError.invalidResponse
        }
        if let worktreePath {
            components.queryItems = (components.queryItems ?? []).filter { $0.name != "worktree" }
                + [URLQueryItem(name: "worktree", value: worktreePath)]
        }
        guard let requestURL = components.url else { throw FetchError.invalidResponse }
        var request = URLRequest(url: requestURL)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    static func candidates(from response: WorktreeManagementResponse) throws -> [AgentCompletionCandidate] {
        switch response {
        case .agentCompletions(let candidates): return candidates
        case .error(_, let message, _, _): throw FetchError.server(message)
        default: throw FetchError.invalidResponse
        }
    }

    static func fetch(
        baseURL: URL,
        provider: RemoteConnectionProvider?,
        worktreePath: String? = nil,
        session: URLSession = .shared
    ) async throws -> [AgentCompletionCandidate] {
        if let provider {
            let request = managementRequest(worktreePath: worktreePath)
            return try candidates(from: await RelayedWorktreeManagementClient.send(
                request, using: provider
            ))
        }
        let (data, response) = try await session.data(for: request(baseURL: baseURL, worktreePath: worktreePath))
        guard let response = response as? HTTPURLResponse else { throw FetchError.invalidResponse }
        guard (200..<300).contains(response.statusCode) else { throw FetchError.http(response.statusCode) }
        return try JSONDecoder().decode([AgentCompletionCandidate].self, from: data)
    }

    static func managementRequest(worktreePath: String?) -> WorktreeManagementRequest {
        if let worktreePath { return .worktreeAgentCompletions(worktreeID: worktreePath) }
        return .agentCompletions
    }
}
#endif
