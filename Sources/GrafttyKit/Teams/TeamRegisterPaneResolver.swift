import Foundation

/// @spec TEAM-IDLE-2.9
/// @spec TEAM-IDLE-2.10
/// Pure helper extracted for unit-testing the env -> paneSessionName mapping
/// used by `graftty team register` / `graftty team unregister`.
/// Production callers pass `ProcessInfo.processInfo.environment`; tests
/// supply a synthetic dictionary.
///
/// Lives in `GrafttyKit` rather than `GrafttyCLI` so the `GrafttyTests`
/// target (which depends on `Graftty` -> `GrafttyKit`, not `GrafttyCLI`)
/// can import and exercise it directly.
public enum TeamRegisterPaneResolver {
    public static func paneSessionName(env: [String: String]) -> String? {
        guard let raw = env["ZMX_SESSION"], !raw.isEmpty else { return nil }
        return raw
    }
}
