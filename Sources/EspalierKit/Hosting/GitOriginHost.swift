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

        if trimmed.hasPrefix("git@") {
            // scp-style: `git@host:path` (no port, single colon separates host from path).
            let stripped = String(trimmed.dropFirst("git@".count))
            guard let colon = stripped.firstIndex(of: ":") else { return nil }
            host = String(stripped[..<colon])
            path = String(stripped[stripped.index(after: colon)...])
        } else if trimmed.hasPrefix("https://") || trimmed.hasPrefix("http://") || trimmed.hasPrefix("ssh://") {
            guard let url = URL(string: trimmed), let urlHost = url.host else { return nil }
            host = urlHost
            path = String(url.path.drop(while: { $0 == "/" }))
        } else {
            return nil
        }

        guard let slash = path.firstIndex(of: "/") else { return nil }
        let owner = String(path[..<slash])
        var repo = String(path[path.index(after: slash)...])
        // `PR-5.6`: trailing `/` before `.git` so `repo.git/` →
        // `repo` rather than `repo.git`.
        while repo.hasSuffix("/") { repo = String(repo.dropLast()) }
        if repo.hasSuffix(".git") { repo = String(repo.dropLast(".git".count)) }

        guard !owner.isEmpty, !repo.isEmpty, !host.isEmpty else { return nil }

        let hostLower = host.lowercased()
        let provider: HostingProvider
        if hostLower == "github.com" || hostLower.hasSuffix(".github.com") || hostLower.hasPrefix("github.") {
            provider = .github
        } else if hostLower == "gitlab.com" || hostLower.hasSuffix(".gitlab.com") || hostLower.hasPrefix("gitlab.") {
            provider = .gitlab
        } else {
            provider = .unsupported
        }

        return HostingOrigin(provider: provider, host: host, owner: owner, repo: repo)
    }
}

extension GitOriginHost {
    /// Resolves the repo's `origin` remote URL and parses it.
    /// Returns nil only when git reports `origin` does not exist — a
    /// legitimate "no origin remote" answer that `PR-7.11` permits the
    /// store to cache. `PR-4.4`: every other `nonZeroExit` (transient
    /// failures like a concurrent `git worktree add` rewriting
    /// `.git/config`, a brief lock contention, or an FSEvents-driven
    /// re-read mid-pack-operation) is rethrown so the store's
    /// don't-cache-on-throw safeguard kicks in — otherwise a single
    /// transient nil poisons `hostByRepo` for the whole session and
    /// the repo's PR status never resolves until Espalier relaunches.
    public static func detect(repoPath: String) async throws -> HostingOrigin? {
        let output: String
        do {
            output = try await GitRunner.run(args: ["remote", "get-url", "origin"], at: repoPath)
        } catch CLIError.nonZeroExit(_, _, let stderr)
            where stderr.range(of: "no such remote", options: .caseInsensitive) != nil {
            return nil
        }
        return parse(remoteURL: output)
    }
}
