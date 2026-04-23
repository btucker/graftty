import Foundation
import SwiftUI
import Sparkle

/// Swift-facing wrapper around `SPUStandardUpdaterController` that exposes
/// the state the titlebar badge observes.
///
/// - In live mode, the controller owns an `SPUStandardUpdaterController`
///   and registers itself as the `userDriverDelegate` (see
///   `UpdaterController+Delegate.swift`). Sparkle's scheduled checks
///   consult `standardUserDriverShouldHandleShowingScheduledUpdate` to
///   ask whether to show a modal — we return `false` so the check stays
///   silent and surfaces via the titlebar badge instead. A user click on
///   the badge calls `showPendingUpdate()`, which re-kicks
///   `updater.checkForUpdates(nil)` — this time Sparkle treats the check
///   as user-initiated and the standard driver shows its dialog.
/// - In test mode (`forTesting()`), the Sparkle machinery is not
///   instantiated. Tests call the `notify…` hooks directly.
@MainActor
public final class UpdaterController: NSObject, ObservableObject {

    @Published public private(set) var updateAvailable: Bool = false
    @Published public private(set) var availableVersion: String?

    /// Nil in test mode; populated in live mode once `start()` succeeds.
    /// The outer `Wiring` box keeps the live-mode init to a single
    /// `let`-like assignment after `super.init` so the delegate
    /// self-reference is safe.
    private var wiring: Wiring?

    struct Wiring {
        let standardController: SPUStandardUpdaterController
    }

    /// Production initializer. Wires `SPUStandardUpdaterController` with
    /// `self` as the `userDriverDelegate`, so
    /// `SPUStandardUserDriverDelegate` callbacks fire on this object.
    /// The conformance lives in `UpdaterController+Delegate.swift`.
    public override init() {
        super.init()
        let controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: self
        )
        self.wiring = Wiring(standardController: controller)
    }

    /// Test-only: skips Sparkle wiring. The published state is still
    /// reachable through the `notify…` hooks.
    public static func forTesting() -> UpdaterController {
        UpdaterController(skipWiring: ())
    }

    private init(skipWiring: Void) {
        super.init()
        self.wiring = nil
    }

    public var canCheckForUpdates: Bool {
        wiring?.standardController.updater.canCheckForUpdates ?? false
    }

    /// User-initiated check via `Graftty → Check for Updates…`. Always
    /// surfaces Sparkle's standard dialog regardless of whether an
    /// update exists. When a pending scheduled-check result is waiting
    /// on us, this also resurfaces that result — `immediateFocus` will
    /// be `true`, so the delegate returns `true` and Sparkle shows the
    /// modal.
    public func checkForUpdatesWithUI() {
        wiring?.standardController.checkForUpdates(nil)
    }

    /// Invoked by the titlebar badge click. Triggers a fresh check whose
    /// `immediateFocus` flag is set — Sparkle re-surfaces the same
    /// pending update through the standard driver's modal. The appcast
    /// is re-fetched (one HTTP GET) but that cost is fine at this
    /// cadence; it also ensures the user sees the freshest version if
    /// we've raced a new release.
    public func showPendingUpdate() {
        wiring?.standardController.checkForUpdates(nil)
    }

    // MARK: - State-transition hooks called from the delegate extension

    /// Published so tests can drive state directly without faking Sparkle.
    /// The delegate extension is the only live-mode caller.
    public func notifyPendingUpdateDiscovered(version: String) {
        availableVersion = version
        updateAvailable = true
    }

    public func notifyPendingUpdateCleared() {
        availableVersion = nil
        updateAvailable = false
    }

    /// Access to the underlying updater for the delegate extension only.
    /// Internal, not public — outside code uses `checkForUpdatesWithUI`
    /// and `showPendingUpdate`.
    var underlyingUpdater: SPUUpdater? {
        wiring?.standardController.updater
    }
}
