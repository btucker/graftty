import CoreGraphics
import Testing
@testable import GrafttyCommandUI

struct AgentGalleryDensityTests {
    @Test("@spec IOS-13.32: While the phone gallery is open, the application shall fill the screen with tiles two by two or two stacked, move between those two sizes when the user pinches, go no further in either direction, and remember the size it was left at.")
    func pinchMovesBetweenTwoSizes() {
        #expect(AgentGalleryDensity.four.after(pinchScale: 1.4) == .two)
        #expect(AgentGalleryDensity.two.after(pinchScale: 1.4) == .two)
        #expect(AgentGalleryDensity.two.after(pinchScale: 0.7) == .four)
        #expect(AgentGalleryDensity.four.after(pinchScale: 0.7) == .four)
        #expect(AgentGalleryDensity.four.after(pinchScale: 1.05) == .four)
        let screen = CGSize(width: 390, height: 700)
        #expect(AgentGalleryDensity.four.tileSize(in: screen, spacing: 10) == CGSize(width: 190, height: 345))
        #expect(AgentGalleryDensity.two.tileSize(in: screen, spacing: 10) == CGSize(width: 390, height: 345))
        #expect(AgentGalleryDensity(rawValue: AgentGalleryDensity.two.rawValue) == .two)
    }

    @Test func tilesNeverGetANegativeSizeBeforeLayout() {
        // The phone gallery subtracts its padding from a GeometryReader that can first report zero.
        for density in AgentGalleryDensity.allCases {
            let size = density.tileSize(in: CGSize(width: -24, height: -12), spacing: 10)
            #expect(size.width >= 0 && size.height >= 0)
        }
    }

    @Test("@spec IOS-13.33: While the phone gallery shows more agents than it can keep live, the application shall show live terminals only for visible tiles up to its limit, in tile order, and show the rest by caption and status alone.")
    func liveBudget() {
        let sessions = ["a", "b", "c", "d", "e", "f"]
        #expect(AgentGalleryPreviewBudget.live(sessions: sessions, visible: ["b", "c", "d", "e", "f"], limit: 4) == ["b", "c", "d", "e"])
        #expect(AgentGalleryPreviewBudget.live(sessions: sessions, visible: ["f", "a"], limit: 4) == ["a", "f"])
        #expect(AgentGalleryPreviewBudget.live(sessions: sessions, visible: [], limit: 4).isEmpty)
    }
}
