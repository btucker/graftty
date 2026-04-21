import AppKit

/// Shared wrapper for the `clearContents` + `setString(_:forType:)` dance
/// every "Copy …" button in the app would otherwise inline. The pair must
/// happen together — `setString` without `clearContents` leaves stale typed
/// data (e.g. a prior RTF flavor) attached to the same pasteboard — so the
/// helper keeps them paired.
enum Pasteboard {
    static func copy(_ string: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(string, forType: .string)
    }
}
