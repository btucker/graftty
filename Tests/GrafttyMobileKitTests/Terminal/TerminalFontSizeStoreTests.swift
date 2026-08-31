#if canImport(UIKit)
import Foundation
import Testing
@testable import GrafttyMobileKit

@MainActor
@Suite("""
@spec IOS-6.21: When the user pinch-zooms an owner terminal, the application shall persist the resulting font size by host and worktree path, use it as the live base through ownership changes, and restore it for every terminal in that worktree when the worktree is reopened.
""")
struct TerminalFontSizeStoreTests {
    private func freshDefaults() -> UserDefaults {
        let suiteName = "TerminalFontSizeStoreTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    @Test
    func savedSizeSurvivesStoreRecreation() {
        let defaults = freshDefaults()
        let hostID = UUID()
        let first = TerminalFontSizeStore(defaults: defaults)

        first.setFontSize(8.2, hostID: hostID, worktreePath: "/repo/feature")

        let restored = TerminalFontSizeStore(defaults: defaults)
        #expect(restored.fontSize(
            hostID: hostID,
            worktreePath: "/repo/feature"
        ) == 8.2)
    }

    @Test
    func hostAndWorktreeTogetherIdentifyTheSetting() {
        let defaults = freshDefaults()
        let firstHost = UUID()
        let secondHost = UUID()
        let store = TerminalFontSizeStore(defaults: defaults)

        store.setFontSize(8, hostID: firstHost, worktreePath: "/repo/feature")
        store.setFontSize(10, hostID: firstHost, worktreePath: "/repo/other")
        store.setFontSize(12, hostID: secondHost, worktreePath: "/repo/feature")

        #expect(store.fontSize(hostID: firstHost, worktreePath: "/repo/feature") == 8)
        #expect(store.fontSize(hostID: firstHost, worktreePath: "/repo/other") == 10)
        #expect(store.fontSize(hostID: secondHost, worktreePath: "/repo/feature") == 12)
    }

    @Test
    func pinchStepsTrackTheEffectiveSizeWithinGhosttyBounds() {
        #expect(TerminalFontSizeAdjustment.apply(steps: -2, to: 11.2) == 9.2)
        #expect(TerminalFontSizeAdjustment.apply(steps: -20, to: 11.2) == 4)
        #expect(TerminalFontSizeAdjustment.apply(steps: 80, to: 11.2) == 64)
    }

    @Test
    func ownerPinchObservationPublishesTheAdjustedSize() {
        let container = TerminalInputContainerView(frame: .zero)
        var observed: [Float] = []
        container.configureFontSizeObservation(
            initialFontSize: 11.2,
            onChange: { observed.append($0) }
        )

        container.applyObservedFontSizeStepsForTesting(-2)

        #expect(observed == [9.2])
    }

    @Test
    func swiftUIEchoDoesNotResetAnActivePinchBaseline() {
        let container = TerminalInputContainerView(frame: .zero)
        var observed: [Float] = []
        container.configureFontSizeObservation(
            initialFontSize: 11.2,
            onChange: { observed.append($0) }
        )

        let afterStep = container.applyObservedFontSizeStepsForTesting(
            1,
            pinchScale: 1.1
        )
        container.configureFontSizeObservation(
            initialFontSize: 12.2,
            onChange: { observed.append($0) }
        )
        let afterEcho = container.applyObservedFontSizeStepsForTesting(0)

        #expect(observed == [12.2])
        #expect(afterStep.configuredFontSize == 12.2)
        #expect(afterEcho.pinchScale == 1.1)
    }

    @Test
    func followerPinchDoesNotPublishAWorktreePreference() {
        let container = TerminalInputContainerView(frame: .zero)
        var observed: [Float] = []
        container.configureFontSizeObservation(
            initialFontSize: 11.2,
            onChange: { observed.append($0) }
        )
        container.applyObservedFontSizeStepsForTesting(-1)

        container.configureFontSizeObservation(
            initialFontSize: 11.2,
            onChange: nil
        )
        container.applyObservedFontSizeStepsForTesting(-2)

        #expect(observed == [10.2])
    }

    @Test
    func savedSizeOverridesTheScaledBaseline() {
        let configured = GhosttyConfigFetcher.terminalConfig(
            macConfig: "font-size = 14\n",
            savedFontSize: 8.2
        )

        #expect(GhosttyConfigFetcher.lastFontSize(in: configured) == 8.2)
    }

    @Test
    func selectedSizeBecomesTheLiveBaseForOwnerRestoration() {
        let initial = GhosttyConfigFetcher.terminalConfig(
            macConfig: "font-size = 14\n",
            savedFontSize: nil
        )

        let updated = SingleSessionView.configByApplyingFontPreference(
            8.2,
            to: initial
        )

        #expect(GhosttyConfigFetcher.lastFontSize(in: updated) == 8.2)
    }
}
#endif
