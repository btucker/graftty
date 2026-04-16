import Foundation

/// Pure logic for deciding *how* to install the CLI symlink. The GUI layer
/// (`EspalierApp.installCLI`) dispatches on the returned plan — either doing
/// the symlink directly or surfacing a shell command for the user to run
/// with sudo.
///
/// Extracted from the GUI so the decision can be exercised in tests without
/// AppKit / NSAlert.
public enum CLIInstaller {
    public enum Plan: Equatable, Sendable {
        /// The destination's parent directory is writable; the app can do
        /// the symlink itself.
        case directSymlink(source: String, destination: String)

        /// The parent isn't writable (e.g. /usr/local/bin owned by root).
        /// Surface `command` to the user so they can run it in Terminal.
        case showSudoCommand(command: String, destination: String)
    }

    /// Decide the install strategy for `(source -> destination)`.
    ///
    /// Uses `isWritableFile` on the destination's parent directory. This is
    /// a best-effort check — even a writable parent can fail to create the
    /// link if something unusual intervenes, so callers should still handle
    /// errors from the actual symlink call.
    public static func plan(
        source: String,
        destination: String,
        fileManager: FileManager = .default
    ) -> Plan {
        let parentDir = (destination as NSString).deletingLastPathComponent
        if fileManager.isWritableFile(atPath: parentDir) {
            return .directSymlink(source: source, destination: destination)
        }
        return .showSudoCommand(
            command: sudoSymlinkCommand(source: source, destination: destination),
            destination: destination
        )
    }

    /// Build a `sudo ln -sf` command, shell-escaping single quotes in each
    /// path by closing the quoted string, escaping the literal quote, and
    /// re-opening. (macOS app-bundle paths don't contain single quotes in
    /// practice, but we handle the edge case anyway.)
    public static func sudoSymlinkCommand(source: String, destination: String) -> String {
        "sudo ln -sf \(shellSingleQuote(source)) \(shellSingleQuote(destination))"
    }

    private static func shellSingleQuote(_ s: String) -> String {
        // 'foo' -> 'foo', 'it's' -> 'it'"'"'s'
        "'" + s.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }
}
