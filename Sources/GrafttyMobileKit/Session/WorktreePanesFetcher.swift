#if canImport(UIKit)
import Foundation
import GrafttyProtocol

/// `GET <baseURL>/worktrees/panes` → `[WorktreePanes]`. Mirrors
/// `SessionsFetcher`'s error discrimination: 403 is a distinct
/// "not-on-tailnet" signal so the UI can link to the Tailscale app;
/// everything else collapses into opaque http/transport/decode.
public enum WorktreePanesFetcher {

    public enum FetchError: Error, Equatable {
        case forbidden
        case http(Int)
        case decode
        case transport
    }

    public static func fetch(
        baseURL: URL,
        includeRemoteWorktrees: Bool = false,
        session: URLSession = .shared
    ) async throws -> [WorktreePanes] {
        guard let url = baseURL.appendingAPIPath("worktrees/panes") else { throw FetchError.transport }

        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if includeRemoteWorktrees {
            req.setValue(
                RemoteWorktreeFeatures.oneHopRelay,
                forHTTPHeaderField: RemoteWorktreeFeatures.headerName
            )
        }
        do {
            let (data, response) = try await session.data(for: req)
            guard let http = response as? HTTPURLResponse else { throw FetchError.transport }
            if http.statusCode == 403 { throw FetchError.forbidden }
            guard (200..<300).contains(http.statusCode) else { throw FetchError.http(http.statusCode) }
            do {
                return try JSONDecoder().decode([WorktreePanes].self, from: data)
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
#endif
