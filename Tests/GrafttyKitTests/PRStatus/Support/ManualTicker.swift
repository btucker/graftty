import Foundation
@testable import GrafttyKit

/// Test double for `PollingTickerLike`. Captures the tick closure
/// but never fires it on its own — the test drives ticks manually
/// (or just skips them and uses `refresh` directly). Centralized
/// so the seven `PRStatusStore*Tests` files don't each redeclare
/// it.
@MainActor
final class ManualTicker: PollingTickerLike {
    private var onTick: (@MainActor () async -> Void)?

    func start(onTick: @MainActor @escaping () async -> Void) { self.onTick = onTick }
    func stop() { onTick = nil }
    func pulse() {}

    /// Synchronously invoke the captured tick handler. Used by
    /// tests that need to exercise the polling path explicitly
    /// (e.g. RemoteGate tests).
    func fire() async { await onTick?() }
}
