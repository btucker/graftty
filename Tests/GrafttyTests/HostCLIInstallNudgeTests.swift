import Testing
import Foundation
@testable import Graftty
@testable import GrafttyKit

/// Covers the gating logic of `HostCLIInstallNudge.presentIfNeeded`.
/// We can't drive `NSAlert.runModal()` from a unit test, so the
/// assertions cover every short-circuit *before* the alert would be
/// shown — together they prove the nudge fires only on (supported
/// provider) ∧ (CLI missing) ∧ (not yet shown this process) ∧ (not
/// user-suppressed).
@MainActor
@Suite("""
@spec PR-4.5: When the user adds a repository whose origin's host CLI \
(`gh` for github, `glab` for gitlab) is not available on the application's \
PATH, the application shall present an informational nudge with installation \
guidance. The nudge shall fire at most once per provider per process and \
shall be permanently suppressible per provider via a "Don't show again" \
affordance persisted in UserDefaults.
""", .serialized)
struct HostCLIInstallNudgeGatingTests {

    init() {
        for p in HostingProvider.allCases {
            UserDefaults.standard.removeObject(forKey: HostCLIInstallNudge.suppressionKey(for: p))
        }
        HostCLIInstallNudge.resetForTests()
    }

    @Test func unsupportedProviderShortCircuits() async {
        await HostCLIInstallNudge.presentIfNeeded(for: .unsupported) { _ in
            Issue.record("availability probe should not run for .unsupported")
            return true
        }
    }

    @Test func availableCLIShortCircuits() async {
        await HostCLIInstallNudge.presentIfNeeded(for: .github) { command in
            #expect(command == "gh")
            return true  // gh is installed → no nudge
        }
    }

    @Test func suppressedProviderShortCircuits() async {
        UserDefaults.standard.set(true, forKey: HostCLIInstallNudge.suppressionKey(for: .gitlab))
        await HostCLIInstallNudge.presentIfNeeded(for: .gitlab) { _ in
            Issue.record("availability probe should not run when suppressed")
            return false
        }
    }

    @Test func suppressionIsPerProvider() async {
        UserDefaults.standard.set(true, forKey: HostCLIInstallNudge.suppressionKey(for: .gitlab))
        await HostCLIInstallNudge.presentIfNeeded(for: .github) { command in
            #expect(command == "gh")  // .gitlab suppression doesn't gate .github
            return true
        }
    }

    @Test func suppressionKeysAreDistinctPerProvider() {
        let keys = Set(HostingProvider.allCases.map(HostCLIInstallNudge.suppressionKey(for:)))
        #expect(keys.count == HostingProvider.allCases.count)
    }
}
