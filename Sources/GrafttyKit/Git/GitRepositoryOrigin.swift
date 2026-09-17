import Foundation

/// Cross-Mac repository identity. Recognized GitHub/GitLab hosts share identity
/// across standard transports; generic SSH servers retain the login user and
/// absolute or home-relative path. Nonstandard ports retain their transport.
public struct GitRepositoryOrigin: Codable, Sendable, Equatable {
    public typealias Loader = @Sendable (String) async throws -> GitRepositoryOrigin?

    public let host: String
    public let path: String
    public let port: Int?
    public let transport: String?
    public let sshUser: String?

    public static func parse(_ remoteURL: String) -> Self? {
        let value = remoteURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let host: String
        let scheme: String
        var path: String
        var port: Int?
        var sshUser: String?
        if value.contains("://") {
            guard let url = URLComponents(string: value),
                  let parsedScheme = url.scheme?.lowercased(),
                  let defaultPort = ["ssh": 22, "https": 443, "http": 80, "git": 9418][parsedScheme],
                  let parsedHost = url.host, !parsedHost.isEmpty,
                  url.query == nil, url.fragment == nil else { return nil }
            host = parsedHost
            scheme = parsedScheme
            path = url.path
            if scheme == "ssh" {
                sshUser = url.user
                // Git's SSH URI form uses /~user/path for ~user/path.
                if path.hasPrefix("/~") { path.removeFirst() }
            }
            if let explicitPort = url.port, explicitPort != defaultPort {
                port = explicitPort
            }
        } else {
            // Git's scp form accepts usernames other than `git`, or no user.
            guard var colon = value.firstIndex(of: ":") else { return nil }
            if value[..<colon].contains("[") {
                guard let bracket = value.firstIndex(of: "]") else { return nil }
                colon = value.index(after: bracket)
                guard colon < value.endIndex, value[colon] == ":" else { return nil }
            }
            let authority = value[..<colon]
            guard !authority.isEmpty, !authority.contains("/"),
                  !authority.contains(where: { $0.isWhitespace }) else { return nil }
            if let separator = authority.lastIndex(of: "@") {
                sshUser = String(authority[..<separator])
                host = String(authority[authority.index(after: separator)...])
            } else {
                host = String(authority)
            }
            scheme = "ssh"
            path = String(value[value.index(after: colon)...])
            guard !path.hasPrefix(":"), !host.isEmpty else { return nil }
        }
        let forgePath = String(path.drop(while: { $0 == "/" }))
        let provider = GitOriginHost.parse(remoteURL: "https://\(host)/\(forgePath)")?.provider
        let isForge = port == nil && (provider == .github || provider == .gitlab)
        if isForge {
            path = forgePath
            sshUser = nil
        }
        while path.hasSuffix("/") { path.removeLast() }
        if isForge, path.hasSuffix(".git") { path.removeLast(4) }
        guard !path.isEmpty else { return nil }
        return Self(host: host.lowercased(), path: path, port: port,
                    transport: isForge && port == nil ? nil : scheme, sshUser: sshUser)
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
