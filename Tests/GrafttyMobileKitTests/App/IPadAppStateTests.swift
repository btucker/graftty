#if canImport(UIKit)
import Testing
import Foundation
@testable import GrafttyProtocol
@testable import GrafttyMobileKit

@MainActor
@Suite("IPadAppState — selection state + UserDefaults persistence")
struct IPadAppStateTests {

    private func freshDefaults() -> UserDefaults {
        let suiteName = "IPadAppStateTests-\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: suiteName)!
        suite.removePersistentDomain(forName: suiteName)
        return suite
    }

    @Test("defaults: nil host, nil worktree, nil pane, 320 sidebar width, fallback theme")
    func defaults() {
        let defaults = freshDefaults()
        let state = IPadAppState(defaults: defaults)
        #expect(state.selectedHostId == nil)
        #expect(state.selectedWorktreePath == nil)
        #expect(state.focusedPaneId == nil)
        #expect(state.sidebarWidth == 320)
        #expect(state.theme == GhosttyThemeColors.fallback)
    }

    @Test("writing selectedHostId persists across instantiation")
    func selectedHostIdRoundTrip() {
        let defaults = freshDefaults()
        let id = UUID()
        let a = IPadAppState(defaults: defaults)
        a.selectedHostId = id

        let b = IPadAppState(defaults: defaults)
        #expect(b.selectedHostId == id)
    }

    @Test("writing sidebarWidth persists across instantiation")
    func sidebarWidthRoundTrip() {
        let defaults = freshDefaults()
        let a = IPadAppState(defaults: defaults)
        a.sidebarWidth = 412.5

        let b = IPadAppState(defaults: defaults)
        #expect(b.sidebarWidth == 412.5)
    }

    @Test("selectedWorktreePath, focusedPaneId, and theme are in-memory only")
    func inMemoryFieldsResetOnRecreate() {
        let defaults = freshDefaults()
        let a = IPadAppState(defaults: defaults)
        a.selectedWorktreePath = "/Users/me/projects/foo"
        a.focusedPaneId = "session-xyz"
        a.theme = GhosttyThemeColors(
            backgroundRGB: .init(r: 0.1, g: 0.2, b: 0.3),
            foregroundRGB: .init(r: 0.9, g: 0.9, b: 0.9)
        )

        let b = IPadAppState(defaults: defaults)
        #expect(b.selectedWorktreePath == nil)
        #expect(b.focusedPaneId == nil)
        #expect(b.theme == GhosttyThemeColors.fallback)
    }

    @Test("nil-ing selectedHostId removes it from defaults")
    func nilSelectedHostIdClears() {
        let defaults = freshDefaults()
        let a = IPadAppState(defaults: defaults)
        a.selectedHostId = UUID()
        a.selectedHostId = nil

        let b = IPadAppState(defaults: defaults)
        #expect(b.selectedHostId == nil)
    }
}
#endif
