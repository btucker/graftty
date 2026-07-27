#if canImport(UIKit)
import Foundation
import GrafttyProtocol

public enum ReposFetcher {

    public struct RepoInfo: Codable, Sendable, Equatable {
        public let path: String
        public let displayName: String
        public let origin: WorktreeOrigin?

        public init(
            path: String,
            displayName: String,
            origin: WorktreeOrigin? = nil
        ) {
            self.path = path
            self.displayName = displayName
            self.origin = origin
        }
    }

    public enum FetchError: Error, Equatable {
        case forbidden
        case http(Int)
        case decode
        case transport
    }

    public static func request(
        baseURL: URL,
        includeRemoteWorktrees: Bool = false
    ) throws -> URLRequest {
        guard let url = baseURL.appendingAPIPath("repos") else { throw FetchError.transport }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if includeRemoteWorktrees {
            req.setValue(
                RemoteWorktreeFeatures.oneHopRelay,
                forHTTPHeaderField: RemoteWorktreeFeatures.headerName
            )
        }
        return req
    }

    public static func decode(_ data: Data) throws -> [RepoInfo] {
        try JSONDecoder().decode([RepoInfo].self, from: data)
    }

    public static func fetch(
        baseURL: URL,
        includeRemoteWorktrees: Bool = false,
        session: URLSession = .shared
    ) async throws -> [RepoInfo] {
        let req = try request(
            baseURL: baseURL,
            includeRemoteWorktrees: includeRemoteWorktrees
        )
        do {
            let (data, response) = try await session.data(for: req)
            guard let http = response as? HTTPURLResponse else { throw FetchError.transport }
            if http.statusCode == 403 { throw FetchError.forbidden }
            guard (200..<300).contains(http.statusCode) else { throw FetchError.http(http.statusCode) }
            do {
                return try decode(data)
            } catch {
                throw FetchError.decode
            }
        } catch let e as FetchError {
            throw e
        } catch {
            throw FetchError.transport
        }
    }
}

extension ReposFetcher.FetchError {
    public var userMessage: String {
        switch self {
        case .forbidden: return "Not authorized — is this device on your tailnet?"
        case .http(let code): return "HTTP \(code)"
        case .decode: return "The server sent a response this version can't read."
        case .transport: return "Couldn't reach the server."
        }
    }
}
#endif
