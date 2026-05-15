import Foundation

/// Per-provider host-CLI metadata + availability probe. Lives in
/// GrafttyKit so the decision can be exercised in tests without AppKit.
public enum HostCLIAvailability {
    public struct Metadata: Sendable, Equatable {
        public let cli: String
        public let displayName: String
        public let prTerm: String
        public let installURL: URL
        public let brewCommand: String
    }

    public static func metadata(for provider: HostingProvider) -> Metadata? {
        switch provider {
        case .github:
            return Metadata(
                cli: "gh",
                displayName: "GitHub",
                prTerm: "pull request",
                installURL: URL(string: "https://cli.github.com")!,
                brewCommand: "brew install gh"
            )
        case .gitlab:
            return Metadata(
                cli: "glab",
                displayName: "GitLab",
                prTerm: "merge request",
                installURL: URL(string: "https://gitlab.com/gitlab-org/cli#installation")!,
                brewCommand: "brew install glab"
            )
        case .unsupported:
            return nil
        }
    }

    /// Treats `CLIError.notFound` — and only that — as "missing".
    /// A present-but-erroring binary is "installed, just unhappy", which
    /// is not the case the nudge addresses.
    public static func isAvailable(
        command: String,
        executor: CLIExecutor = CLIRunner()
    ) async -> Bool {
        do {
            _ = try await executor.capture(
                command: command,
                args: ["--version"],
                at: NSTemporaryDirectory()
            )
            return true
        } catch CLIError.notFound {
            return false
        } catch {
            return true
        }
    }
}
