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
final class PaneInputActivityObserver: @unchecked Sendable {
    private let registry: PaneInputActivityRegistry

    init(registry: PaneInputActivityRegistry) {
        self.registry = registry
    }

    /// Pure side-effect: stamp the pane's last-input timestamp. Never
    /// throws, never blocks meaningfully (NSLock + dictionary write).
    func recordKeystroke(paneID: UUID) {
        registry.recordKeystroke(paneID: paneID)
    }
}
