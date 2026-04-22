#if canImport(UIKit)
import Foundation
import GrafttyProtocol

/// `GET <baseURL>/repos` → `[RepoInfo]`. Fetches the list of
/// repositories the Mac is tracking, for the "Add Worktree" flow's
/// repo picker. Mirrors `SessionsFetcher`'s error discrimination: 403
/// is a distinct "not-on-tailnet" signal; everything else collapses
/// into opaque http/transport/decode.
public enum ReposFetcher {

    public enum FetchError: Error, Equatable {
        case forbidden
        case http(Int)
        case decode
        case transport
    }

    public static func request(baseURL: URL) -> URLRequest {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        let existing = components?.path ?? ""
        components?.path = existing.hasSuffix("/") ? existing + "repos" : existing + "/repos"
        let url = components?.url ?? baseURL.appendingPathComponent("repos")
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        return req
    }

    public static func decode(_ data: Data) throws -> [RepoInfo] {
        try JSONDecoder().decode([RepoInfo].self, from: data)
    }

    public static func fetch(baseURL: URL, session: URLSession = .shared) async throws -> [RepoInfo] {
        let req = request(baseURL: baseURL)
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
#endif
