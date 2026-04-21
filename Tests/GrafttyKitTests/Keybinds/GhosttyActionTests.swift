import Testing
@testable import GrafttyKit

@Suite("GhosttyAction — action-name contract")
struct GhosttyActionTests {
    @Test func rawValuesMatchGhosttyConfigSyntax() {
        #expect(GhosttyAction.newSplitRight.rawValue == "new_split:right")
        #expect(GhosttyAction.newSplitLeft.rawValue  == "new_split:left")
        #expect(GhosttyAction.newSplitUp.rawValue    == "new_split:up")
        #expect(GhosttyAction.newSplitDown.rawValue  == "new_split:down")
        #expect(GhosttyAction.closeSurface.rawValue  == "close_surface")
        #expect(GhosttyAction.gotoSplitLeft.rawValue   == "goto_split:left")
        #expect(GhosttyAction.gotoSplitRight.rawValue  == "goto_split:right")
        #expect(GhosttyAction.gotoSplitUp.rawValue   == "goto_split:up")
        #expect(GhosttyAction.gotoSplitDown.rawValue == "goto_split:down")
        #expect(GhosttyAction.gotoSplitPrevious.rawValue == "goto_split:previous")
        #expect(GhosttyAction.gotoSplitNext.rawValue     == "goto_split:next")
        #expect(GhosttyAction.toggleSplitZoom.rawValue == "toggle_split_zoom")
        #expect(GhosttyAction.equalizeSplits.rawValue  == "equalize_splits")
        #expect(GhosttyAction.reloadConfig.rawValue    == "reload_config")
        #expect(GhosttyAction.openConfig.rawValue      == "open_config")
    }

    @Test func allCasesCountMatchesEnumSize() {
        #expect(GhosttyAction.allCases.count == 15)
    }
}
