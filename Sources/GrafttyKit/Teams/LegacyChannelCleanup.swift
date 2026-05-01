import Foundation
import os

/// One-shot cleanup of the legacy `graftty-channel` MCP integration that
/// was retired in the channels-to-inbox migration. Runs idempotently on
/// every app launch for ~3 release versions; subsequently deleted.
public enum LegacyChannelCleanup {
    private static let logger = Logger(
        subsystem: "com.btucker.graftty",
        category: "LegacyChannelCleanup"
    )
    static let serverName = "graftty-channel"

    /// Run the three side-effecting cleanup steps in sequence (the
    /// `defaultCommand` scrub lives separately so the caller can present
    /// the resulting alert on the main actor). Logs failures, never
    /// throws. Additional steps land in subsequent commits.
    public static func run(executor: CLIExecutor = CLIRunner()) async {
        await unregisterMCPServer(executor: executor)
    }

    /// Best-effort `claude mcp remove graftty-channel`. Tolerates missing
    /// `claude` CLI and non-zero exit codes (e.g. server not registered).
    static func unregisterMCPServer(executor: CLIExecutor) async {
        do {
            _ = try await executor.capture(
                command: "claude",
                args: ["mcp", "remove", serverName],
                at: "/"
            )
        } catch {
            logger.info("legacy MCP unregister skipped: \(String(describing: error), privacy: .public)")
        }
    }
}
