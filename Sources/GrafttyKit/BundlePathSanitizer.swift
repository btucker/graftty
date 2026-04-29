import Foundation

/// Fixes the case-insensitive collision between the bundled GUI binary
/// `Graftty.app/Contents/MacOS/Graftty` and the desired CLI invocation
/// `graftty` when the bundle's `MacOS` directory ends up on `$PATH`
/// for spawned shells.
///
/// macOS's case-insensitive default APFS volume resolves a `graftty`
/// lookup to `Graftty` (the GUI binary) when both could match. When
/// `Contents/MacOS` is on PATH (libghostty embeds the bundle's MacOS
/// dir for surface spawns; some launch paths inherit it), `which
/// graftty` returns the GUI executable rather than the actual CLI at
/// `Contents/Helpers/graftty`. Running the GUI binary with `--help`
/// silently exits 0 — confusing to users.
///
/// `scripts/bundle.sh` already moved the CLI from `MacOS/` to
/// `Helpers/` to dodge the collision. This is the runtime companion
/// that ensures any PATH-based `graftty` lookup inside a Graftty
/// pane resolves to the CLI.
public enum BundlePathSanitizer {
    /// Pure helper: produce a corrected PATH string by removing the
    /// bundle's `Contents/MacOS` directory wherever it appears and
    /// prepending `Contents/Helpers` so the CLI wins.
    ///
    /// Idempotent: a second call with the same arguments returns the
    /// same string (Helpers stays at index 0; nothing left to strip).
    /// Exact-match strip — unrelated `Contents/MacOS` dirs from other
    /// bundles in the user's PATH are left alone.
    public static func sanitized(currentPath: String, bundleURL: URL) -> String {
        let macosDir = bundleURL.appendingPathComponent("Contents/MacOS").path
        let helpersDir = bundleURL.appendingPathComponent("Contents/Helpers").path

        var entries: [String] = currentPath.isEmpty
            ? []
            : currentPath
                .split(separator: ":", omittingEmptySubsequences: false)
                .map(String.init)

        entries.removeAll { $0 == macosDir || $0 == helpersDir }
        entries.insert(helpersDir, at: 0)

        return entries.joined(separator: ":")
    }
}
