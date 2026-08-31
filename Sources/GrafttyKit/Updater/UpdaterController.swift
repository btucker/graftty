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
///   instantiated. Tests drive state via the internal `notify…` hooks.
@MainActor
public final class UpdaterController: NSObject, ObservableObject {

    public static let prereleaseChannel = "prerelease"
    public static let prereleaseUpdatesDefaultsKey = "prereleaseUpdatesEnabled"

    /// Non-nil iff a newer version has been announced by Sparkle and not
    /// yet acted on. Badge visibility and label both derive from this.
    @Published public private(set) var availableVersion: String?

    @Published private var storedPrereleaseUpdatesEnabled: Bool

    private let userDefaults: UserDefaults

    /// Nil in test mode; populated in live mode after `super.init` so the
    /// delegate self-reference is legal.
    private var standardController: SPUStandardUpdaterController?

    public override init() {
        let defaults = UserDefaults.standard
        self.userDefaults = defaults
        self.storedPrereleaseUpdatesEnabled = defaults.bool(
            forKey: Self.prereleaseUpdatesDefaultsKey
        )
        super.init()
        self.standardController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: self,
            userDriverDelegate: self
        )
    }

    public static func forTesting(userDefaults: UserDefaults = .standard) -> UpdaterController {
        UpdaterController(skipWiring: (), userDefaults: userDefaults)
    }

    private init(skipWiring: Void, userDefaults: UserDefaults) {
        self.userDefaults = userDefaults
        self.storedPrereleaseUpdatesEnabled = userDefaults.bool(
            forKey: Self.prereleaseUpdatesDefaultsKey
        )
        super.init()
    }

    /// Whether this installation also receives items on Sparkle's prerelease
    /// channel. Sparkle always includes its default stable channel.
    public var prereleaseUpdatesEnabled: Bool {
        get { storedPrereleaseUpdatesEnabled }
        set {
            guard newValue != storedPrereleaseUpdatesEnabled else { return }
            storedPrereleaseUpdatesEnabled = newValue
            userDefaults.set(newValue, forKey: Self.prereleaseUpdatesDefaultsKey)
            standardController?.updater.resetUpdateCycleAfterShortDelay()
        }
    }

    public var allowedUpdateChannels: Set<String> {
        prereleaseUpdatesEnabled ? [Self.prereleaseChannel] : []
    }

    public var canCheckForUpdates: Bool {
        standardController?.updater.canCheckForUpdates ?? false
    }

    public var automaticallyChecksForUpdates: Bool {
        get { standardController?.updater.automaticallyChecksForUpdates ?? true }
        set { standardController?.updater.automaticallyChecksForUpdates = newValue }
    }

    public func checkForUpdatesWithUI() {
        standardController?.checkForUpdates(nil)
    }

    /// Invoked by the titlebar badge click. Triggers a user-initiated
    /// check whose `immediateFocus` flag is set, so the delegate returns
    /// `true` and Sparkle's standard driver shows its install dialog.
    public func showPendingUpdate() {
        standardController?.checkForUpdates(nil)
    }

    // MARK: - State-transition hooks

    func notifyPendingUpdateDiscovered(version: String) {
        availableVersion = version
    }

    func notifyPendingUpdateCleared() {
        availableVersion = nil
    }
}
