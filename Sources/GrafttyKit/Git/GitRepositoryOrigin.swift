import Foundation

/// Cross-Mac repository identity, independent of credentials and the usual
/// SSH/HTTPS transport choice. Nonstandard ports retain their transport so
/// separate services on the same host cannot accidentally match.
public struct GitRepositoryOrigin: Codable, Sendable, Equatable {
    public typealias Loader = @Sendable (String) async throws -> GitRepositoryOrigin?

    public let host: String
    public let path: String
    public let port: Int?
    public let transport: String?

    public static func parse(_ remoteURL: String) -> Self? {
        let value = remoteURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let host: String
        var path: String
        var port: Int?
        var transport: String?
        if value.contains("://") {
            guard let url = URLComponents(string: value),
                  let scheme = url.scheme?.lowercased(),
                  let defaultPort = ["ssh": 22, "https": 443, "http": 80, "git": 9418][scheme],
                  let parsedHost = url.host, !parsedHost.isEmpty,
                  url.query == nil, url.fragment == nil else { return nil }
            host = parsedHost
            path = url.path
            if let explicitPort = url.port, explicitPort != defaultPort {
                port = explicitPort
                transport = scheme
            }
        } else {
            // Git's scp form accepts usernames other than `git`, or no user.
            guard let colon = value.firstIndex(of: ":") else { return nil }
            let authority = value[..<colon]
            guard !authority.isEmpty, !authority.contains("/"),
                  !authority.contains(where: { $0.isWhitespace }) else { return nil }
            host = String(authority.split(separator: "@", omittingEmptySubsequences: false).last ?? "")
            path = String(value[value.index(after: colon)...])
            guard !path.hasPrefix(":"), !host.isEmpty else { return nil }
        }
        path = String(path.drop(while: { $0 == "/" }))
        while path.hasSuffix("/") { path.removeLast() }
        if path.hasSuffix(".git") { path.removeLast(4) }
        guard !path.isEmpty else { return nil }
        return Self(host: host.lowercased(), path: path, port: port, transport: transport)
    }

    public static func detect(repoPath: String) async throws -> Self? {
        do {
            return parse(try await GitRunner.run(
                args: ["remote", "get-url", "origin"], at: repoPath,
                timeout: .seconds(2), using: CLIRunner()))
        } catch CLIError.nonZeroExit(_, _, let stderr)
            where stderr.range(of: "no such remote", options: .caseInsensitive) != nil {
            return nil
        }
    }
}
