import Foundation

/// Single source of truth for how Graftty components resolve the
/// control-socket path. Both the CLI (for sending messages) and the
/// app (for exposing `GRAFTTY_SOCK` to spawned shells) should agree.
///
/// Policy:
///   - If `$GRAFTTY_SOCK` is set AND non-empty, use that value.
///   - Otherwise, fall back to `<ApplicationSupport>/Graftty/graftty.sock`.
///
/// The non-empty check matters because shells treat `export FOO=""` as
/// "FOO exists as empty string" — sourcing a `.env` with a blank
/// `GRAFTTY_SOCK=` line previously made the CLI try to `connect()` to
/// `""`, which fails with ENOENT and surfaces as the misleading
/// "Graftty is not running" message (per `ATTN-3.1`). Treating empty
/// as unset matches Andy's obvious intent.
public enum SocketPathResolver {
    public static func resolve(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        defaultDirectory: URL = AppState.defaultDirectory
    ) -> String {
        if let v = environment["GRAFTTY_SOCK"], !v.isEmpty {
            return v
        }
        return defaultDirectory.appendingPathComponent("graftty.sock").path
    }
}
