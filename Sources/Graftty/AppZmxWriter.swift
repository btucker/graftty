import Foundation
import GrafttyKit

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

    nonisolated func write(sessionName: String, text: String) async throws {
        await MainActor.run {
            guard let handle = terminalManager?.handle(forSessionName: sessionName) else {
                NSLog("[Graftty] AppZmxWriter: no surface for session %@", sessionName)
                return
            }
            handle.typeText(text)
        }
    }
}
