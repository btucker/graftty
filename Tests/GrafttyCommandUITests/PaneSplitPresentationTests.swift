import GrafttyProtocol
import Testing
@testable import GrafttyCommandUI

@Suite("Shared pane-split presentation")
struct PaneSplitPresentationTests {
    @Test("""
    @spec IPAD-2.9: While the iPad detail toolbar offers Split Left, Split Right, Split Up, and Split Down, each button shall use a directional inset-filled rectangle whose filled half indicates where the new pane will be created, matching the Mac terminal context menu rather than using one indistinguishable axis-only icon per opposing pair.
    """)
    func filledHalfDistinguishesEverySplitDirection() {
        #expect(
            GhosttySplitDirection.left.filledPaneSystemImageName
                == "rectangle.leadinghalf.inset.filled"
        )
        #expect(
            GhosttySplitDirection.right.filledPaneSystemImageName
                == "rectangle.righthalf.inset.filled"
        )
        #expect(
            GhosttySplitDirection.up.filledPaneSystemImageName
                == "rectangle.tophalf.inset.filled"
        )
        #expect(
            GhosttySplitDirection.down.filledPaneSystemImageName
                == "rectangle.bottomhalf.inset.filled"
        )

        let iconNames = GhosttyCommandRegistry.macSplitActions.compactMap { entry -> String? in
            guard case .split(let direction) = entry.kind else { return nil }
            return direction.filledPaneSystemImageName
        }
        #expect(Set(iconNames).count == 4)
    }
}
