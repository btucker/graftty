import Foundation

public enum GitOriginHost {
    /// Parse a git remote URL into a `HostingOrigin`.
    /// Returns nil for local paths, `file://`, `git://`, or empty strings.
    /// Returns `HostingOrigin` with `.unsupported` provider for recognized-but-
    /// unsupported hosts (like bitbucket).
    public static func parse(remoteURL: String) -> HostingOrigin? {
        let trimmed = remoteURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if trimmed.hasPrefix("file://") || trimmed.hasPrefix("git://") || trimmed.hasPrefix("/") {
            return nil
        }

        let (host, path): (String, String)

        if trimmed.hasPrefix("git@") || trimmed.hasPrefix("ssh://") {
            let stripped: String
            if trimmed.hasPrefix("ssh://") {
                stripped = String(trimmed.dropFirst("ssh://".count))
            } else {
                stripped = String(trimmed.dropFirst("git@".count))
            }
            let separatorIdx: String.Index?
            if let colon = stripped.firstIndex(of: ":") {
                separatorIdx = colon
            } else if let slash = stripped.firstIndex(of: "/") {
                separatorIdx = slash
            } else {
                return nil
            }
            guard let sep = separatorIdx else { return nil }
            var rawHost = String(stripped[..<sep])
            if let at = rawHost.lastIndex(of: "@") {
                rawHost = String(rawHost[rawHost.index(after: at)...])
            }
            host = rawHost
            path = String(stripped[stripped.index(after: sep)...])
        } else if trimmed.hasPrefix("https://") || trimmed.hasPrefix("http://") {
            guard let url = URL(string: trimmed), let urlHost = url.host else { return nil }
            host = urlHost
            path = String(url.path.drop(while: { $0 == "/" }))
        } else {
            return nil
        }

        guard let slash = path.firstIndex(of: "/") else { return nil }
        let owner = String(path[..<slash])
        var repo = String(path[path.index(after: slash)...])
        if repo.hasSuffix(".git") { repo = String(repo.dropLast(".git".count)) }
        while repo.hasSuffix("/") { repo = String(repo.dropLast()) }

        guard !owner.isEmpty, !repo.isEmpty, !host.isEmpty else { return nil }

        let provider: HostingProvider
        if host.contains("github") {
            provider = .github
        } else if host.contains("gitlab") {
            provider = .gitlab
        } else {
            provider = .unsupported
        }

        return HostingOrigin(provider: provider, host: host, owner: owner, repo: repo)
    }
}
