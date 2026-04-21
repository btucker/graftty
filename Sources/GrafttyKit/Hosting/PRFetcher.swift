import Foundation

public protocol PRFetcher: Sendable {
    /// Returns the PR/MR for `branch`. Prefers open; falls back to
    /// most-recent merged. Never returns closed-unmerged.
    /// Returns nil if no matching PR/MR exists.
    /// Throws `CLIError` on CLI failure (including auth / network / rate limit).
    func fetch(origin: HostingOrigin, branch: String) async throws -> PRInfo?
}
