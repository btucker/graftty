import Foundation
import GrafttyKit

/// @spec TEAM-IDLE-2.2
/// Records "user just typed" timestamps into PaneInputActivityRegistry.
/// Wired at the libghostty input boundary (`SurfaceNSView.keyDown`) so it
/// sees every user keystroke before it reaches the PTY. Read by
/// `IdleDeliveryService` for the 60s user-engaged gate.
///
/// The tap is passive: `recordKeystroke` never throws, never blocks
/// meaningfully (NSLock + dictionary write), and never consumes or alters
/// the event — callers see no behavioral change.
///
/// `onKeystroke` is an optional secondary side-effect hook injected at
/// construction time. The app wires it to resolve the pane's
/// `(worktree, runtime)` agent identity and drive the state registry
/// + engaged-grace timer.
final class PaneInputActivityObserver: @unchecked Sendable {
    private let registry: PaneInputActivityRegistry
    private let onKeystroke: ((UUID) -> Void)?

    init(
        registry: PaneInputActivityRegistry,
        onKeystroke: ((UUID) -> Void)? = nil
    ) {
        self.registry = registry
        self.onKeystroke = onKeystroke
    }

    /// Pure side-effect: stamp the pane's last-input timestamp. Never
    /// throws, never blocks meaningfully (NSLock + dictionary write).
    func recordKeystroke(paneID: UUID) {
        registry.recordKeystroke(paneID: paneID)
        onKeystroke?(paneID)
    }
}
