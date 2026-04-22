#if canImport(UIKit)
import Foundation
import GrafttyProtocol

public enum SessionsFetcher {

    public enum FetchError: Error, Equatable {
        case forbidden
        case http(Int)
        case decode
        case transport
    }

    public static func request(baseURL: URL) -> URLRequest {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        let existing = components?.path ?? ""
        let newPath: String
        if existing.hasSuffix("/") {
            newPath = existing + "sessions"
        } else {
            newPath = existing + "/sessions"
        }
        components?.path = newPath
        let url = components?.url ?? baseURL.appendingPathComponent("sessions")
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        return req
    }

    public static func decode(_ data: Data) throws -> [SessionInfo] {
        try JSONDecoder().decode([SessionInfo].self, from: data)
    }

    public static func fetch(baseURL: URL, session: URLSession = .shared) async throws -> [SessionInfo] {
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
