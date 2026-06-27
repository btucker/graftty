import Testing
@testable import GrafttyMobileKit

@Suite("@spec IOS-4.19: While a `PaneTile` already has a `TerminalController` whose font was last sized from real authoritative grid columns, the application shall not re-apply a font computed from the `PanePreviewFontSizing.defaultColumns` fallback when the underlying `SessionClient` is replaced and its new authoritative grid is briefly nil (background↔foreground, navigate-away-and-back, or any pool rebuild). The previously-applied font shall be preserved until the next authoritative grid arrives, so the preview does not visibly grow on every refresh before the server publishes the first ownership/grid snapshot.")
@MainActor
struct PanePreviewFontApplicationTests {

    @Test
    func initialFrameWithNoControllerCreatesOneSizedForDefaultColsWhenColsNil() {
        let action = PanePreviewFontApplication.decide(
            tileWidth: 200,
            authoritativeCols: nil,
            hasController: false,
            sourceConfigMatches: false,
            lastAppliedFontSize: nil
        )
        let expected = PanePreviewFontSizing.fontSize(tileWidth: 200, authoritativeCols: nil)
        #expect(action == .recreateController(fontSize: expected))
    }

    @Test
    func initialFrameWithRealColsCreatesControllerSizedForThoseCols() {
        let action = PanePreviewFontApplication.decide(
            tileWidth: 200,
            authoritativeCols: 120,
            hasController: false,
            sourceConfigMatches: false,
            lastAppliedFontSize: nil
        )
        let expected = PanePreviewFontSizing.fontSize(tileWidth: 200, authoritativeCols: 120)
        #expect(action == .recreateController(fontSize: expected))
    }

    @Test
    func realColsChangeAppliesNewFontWithoutRecreating() {
        let previous = PanePreviewFontSizing.fontSize(tileWidth: 200, authoritativeCols: 200)
        let action = PanePreviewFontApplication.decide(
            tileWidth: 200,
            authoritativeCols: 120,
            hasController: true,
            sourceConfigMatches: true,
            lastAppliedFontSize: previous
        )
        let expected = PanePreviewFontSizing.fontSize(tileWidth: 200, authoritativeCols: 120)
        #expect(action == .applyFont(expected))
    }

    @Test
    func identicalFontSizeIsIdempotent() {
        let same = PanePreviewFontSizing.fontSize(tileWidth: 200, authoritativeCols: 120)
        let action = PanePreviewFontApplication.decide(
            tileWidth: 200,
            authoritativeCols: 120,
            hasController: true,
            sourceConfigMatches: true,
            lastAppliedFontSize: same
        )
        #expect(action == .nothing)
    }

    @Test
    func newClientWithNilGridDoesNotResetFontToDefaultColsFallback() {
        let previous = PanePreviewFontSizing.fontSize(tileWidth: 200, authoritativeCols: 200)
        let fallback = PanePreviewFontSizing.fontSize(tileWidth: 200, authoritativeCols: nil)
        #expect(fallback > previous)

        let action = PanePreviewFontApplication.decide(
            tileWidth: 200,
            authoritativeCols: nil,
            hasController: true,
            sourceConfigMatches: true,
            lastAppliedFontSize: previous
        )
        #expect(action == .nothing)
    }

    @Test
    func baseConfigChangeStillRecreatesEvenWithColsNil() {
        let action = PanePreviewFontApplication.decide(
            tileWidth: 200,
            authoritativeCols: nil,
            hasController: true,
            sourceConfigMatches: false,
            lastAppliedFontSize: 4.0
        )
        let expected = PanePreviewFontSizing.fontSize(tileWidth: 200, authoritativeCols: nil)
        #expect(action == .recreateController(fontSize: expected))
    }
}
