import Foundation
import GrafttyKit

enum AppZmxWriterError: Error {
    case noSurfaceForSession(String)
    case terminalManagerUnavailable
}

/// Production `ZmxWriter` adapter. Resolves the session name to a
/// `SurfaceHandle` via `TerminalManager.handle(forSessionName:)` and
/// injects the text directly into the pane's PTY using
/// `SurfaceHandle.typeText(_:)` — the same in-process PTY-write path
/// used for default-command injection and programmatic pane automation.
///
/// Must be called on the main actor because `TerminalManager` is
/// `@MainActor`-isolated and `SurfaceHandle.typeText` touches libghostty.
@MainActor
struct AppZmxWriter: ZmxWriter {
    weak var terminalManager: TerminalManager?

    nonisolated func write(sessionName: String, text: String, submit: Bool) async throws {
        try await MainActor.run {
            guard let terminalManager else {
                throw AppZmxWriterError.terminalManagerUnavailable
            }
            guard let handle = terminalManager.handle(forSessionName: sessionName) else {
                throw AppZmxWriterError.noSurfaceForSession(sessionName)
            }
            // Idle-agent delivery is automation. Leave IOS-12.1's
            // silent gate closed; the receiving pane's first human
            // keystroke is what should engage.
            handle.typeText(text, claimEngagement: false)
            // Idle-agent delivery is automation. pressReturn synthesizes
            // a key event that libghostty re-emits via receiveBufferCallback —
            // pass claimEngagement: false so the IOS-12.1 silent gate stays
            // closed, matching the behavior of the preceding typeText call.
            if submit { handle.pressReturn(claimEngagement: false) }
        }
    }
}
