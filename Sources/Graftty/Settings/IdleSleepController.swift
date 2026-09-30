import Combine
import Foundation
import IOKit.pwr_mgt

/// Owns one process-scoped idle-sleep assertion. AppServices retains this
/// controller even when no Settings window is open. Used on the main thread.
final class IdleSleepController: ObservableObject {
    @Published private(set) var isEnabled: Bool
    @Published private(set) var errorMessage: String?

    private let defaults: UserDefaults
    private let createAssertion: (String) -> IOPMAssertionID?
    private let releaseAssertion: (IOPMAssertionID) -> Void
    private var assertionID: IOPMAssertionID?

    init(
        defaults: UserDefaults = .standard,
        createAssertion: @escaping (String) -> IOPMAssertionID? = IdleSleepController.createSystemAssertion,
        releaseAssertion: @escaping (IOPMAssertionID) -> Void = { _ = IOPMAssertionRelease($0) }
    ) {
        self.defaults = defaults
        self.createAssertion = createAssertion
        self.releaseAssertion = releaseAssertion
        self.isEnabled = defaults.bool(forKey: SettingsKeys.keepMacAwake)
        reconcile()
    }

    deinit {
        if let assertionID { releaseAssertion(assertionID) }
    }

    func setEnabled(_ enabled: Bool) {
        defaults.set(enabled, forKey: SettingsKeys.keepMacAwake)
        isEnabled = enabled
        reconcile()
    }

    private func reconcile() {
        errorMessage = nil
        if isEnabled {
            guard assertionID == nil else { return }
            assertionID = createAssertion(kIOPMAssertionTypePreventUserIdleSystemSleep)
            if assertionID == nil {
                errorMessage = "Could not keep this Mac awake. Turn this setting off and on to retry."
            }
        } else if let assertionID {
            releaseAssertion(assertionID)
            self.assertionID = nil
        }
    }

    private static func createSystemAssertion(_ type: String) -> IOPMAssertionID? {
        var id: IOPMAssertionID = 0
        let result = IOPMAssertionCreateWithName(
            type as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "Keep Graftty available for remote connections" as CFString,
            &id
        )
        return result == kIOReturnSuccess ? id : nil
    }
}
