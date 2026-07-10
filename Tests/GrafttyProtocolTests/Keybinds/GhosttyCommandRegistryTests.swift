import Testing
@testable import GrafttyProtocol

@Suite("GhosttyCommandRegistry")
struct GhosttyCommandRegistryTests {
    @Test("allActions covers every Ghostty action in declaration order")
    func allActionsCoversEveryGhosttyAction() {
        #expect(GhosttyCommandRegistry.allActions.map(\.action) == GhosttyAction.allCases)
    }

    @Test("iPad supported actions are the first-pass pane and worktree commands")
    func iPadSupportedActions() {
        #expect(GhosttyCommandRegistry.iPadSupportedActions == [
            .newSplitRight, .newSplitDown, .newSplitLeft, .newSplitUp,
            .closeSurface,
            .gotoSplitLeft, .gotoSplitRight, .gotoSplitUp, .gotoSplitDown,
            .gotoSplitPrevious, .gotoSplitNext,
            .nextTab, .previousTab,
        ])
        #expect(GhosttyCommandRegistry.iPadSupportedActions.contains(.toggleSplitZoom) == false)
        #expect(GhosttyCommandRegistry.iPadSupportedActions.contains(.equalizeSplits) == false)
        #expect(GhosttyCommandRegistry.iPadSupportedActions.contains(.reloadConfig) == false)
        #expect(GhosttyCommandRegistry.iPadSupportedActions.contains(.openConfig) == false)
    }

    @Test("registry maps Ghostty actions to UI-free command kinds")
    func commandKinds() {
        #expect(GhosttyCommandRegistry[.newSplitRight]?.kind == .split(.right))
        #expect(GhosttyCommandRegistry[.newSplitDown]?.kind == .split(.down))
        #expect(GhosttyCommandRegistry[.closeSurface]?.kind == .closePane)
        #expect(GhosttyCommandRegistry[.gotoSplitLeft]?.kind == .focusPane(.left))
        #expect(GhosttyCommandRegistry[.gotoSplitNext]?.kind == .focusPaneByOrder(forward: true))
        #expect(GhosttyCommandRegistry[.gotoSplitPrevious]?.kind == .focusPaneByOrder(forward: false))
        #expect(GhosttyCommandRegistry[.nextTab]?.kind == .focusPaneByOrder(forward: true))
        #expect(GhosttyCommandRegistry[.previousTab]?.kind == .focusPaneByOrder(forward: false))
        #expect(GhosttyCommandRegistry.allActions.contains { entry in
            if case .navigateWorktree = entry.kind { return true }
            return false
        } == false)
        #expect(GhosttyCommandRegistry[.toggleSplitZoom]?.kind == .unsupported)
    }

    @Test("registry exposes shared labels and iPad availability")
    func metadata() {
        #expect(GhosttyCommandRegistry[.newSplitRight]?.label == "Split Right")
        #expect(GhosttyCommandRegistry[.closeSurface]?.label == "Close Pane")
        #expect(GhosttyCommandRegistry[.nextTab]?.label == "Next Pane")
        #expect(GhosttyCommandRegistry[.previousTab]?.label == "Previous Pane")
        #expect(GhosttyCommandRegistry[.openConfig]?.label == "Open Ghostty Settings")
        #expect(GhosttyCommandRegistry[.newSplitRight]?.isSupportedOniPad == true)
        #expect(GhosttyCommandRegistry[.toggleSplitZoom]?.isSupportedOniPad == false)
    }

    @Test("registry owns Mac menu grouping order")
    func macMenuGrouping() {
        #expect(GhosttyCommandRegistry.macSplitActions.map(\.action) == [
            .newSplitRight, .newSplitLeft, .newSplitDown, .newSplitUp,
        ])
        #expect(GhosttyCommandRegistry.macPaneFocusActions.map(\.action) == [
            .gotoSplitLeft, .gotoSplitRight, .gotoSplitUp, .gotoSplitDown,
            .gotoSplitPrevious, .gotoSplitNext,
            .nextTab, .previousTab,
        ])
        #expect(GhosttyCommandRegistry.macWorktreeNavigationActions.isEmpty)
        #expect(GhosttyCommandRegistry.macPaneLayoutActions.map(\.action) == [
            .toggleSplitZoom, .equalizeSplits,
        ])
        #expect(GhosttyCommandRegistry.macPaneLifecycleActions.map(\.action) == [
            .closeSurface,
        ])
        #expect(GhosttyCommandRegistry.macSettingsActions.map(\.action) == [
            .openConfig, .reloadConfig,
        ])
    }
}
