import AppKit
import GrafttyKit

/// One-time non-blocking alert presented at app launch when
/// `SocketServer.start()` fails. Without it, the user sees a running
/// Graftty whose `graftty notify` CLI reports "not listening" — a
/// diagnostic trail that relies on them actually trying the CLI. This
/// banner tells them up front. Mirrors `ZmxFallbackBanner`'s shape and
/// one-shot lifecycle.
///
/// State is process-local; a relaunch re-presents the alert if the
/// server still fails. ATTN-2.7.
enum NotifySocketBanner {

    private static var hasShown = false

    @MainActor
    static func presentIfNeeded(error: SocketServerError) {
        guard !hasShown else { return }
        hasShown = true

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Notify socket unavailable"
        alert.informativeText = """
            Graftty couldn't start its control socket, so `graftty notify`, \
            `graftty pane list`, `graftty pane add`, and `graftty pane close` \
            won't reach this instance. Terminals still work.

            Underlying error: \(Self.describe(error))

            Try quitting and relaunching Graftty. If the problem persists, \
            `GRAFTTY_SOCK` may be set to an unwritable location — unset it \
            or point it somewhere shorter than 103 bytes.
            """
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private static func describe(_ error: SocketServerError) -> String {
        switch error {
        case .socketCreationFailed:
            return "socket() returned an error"
        case .bindFailed(let errno):
            return "bind() failed (errno \(errno))"
        case .listenFailed(let errno):
            return "listen() failed (errno \(errno))"
        case .socketPathTooLong(let bytes, let maxBytes):
            return "socket path is \(bytes) bytes, exceeds macOS sockaddr_un limit of \(maxBytes)"
        }
    }
}
