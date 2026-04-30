import Testing
@testable import GrafttyKit

@Suite("paneCloseAction")
struct PaneCloseActionTests {

    /// TERM-5.3 regression guard for commit `0a553d1` (ZMX-7.2).
    ///
    /// When the user types `exit` in a pane, shell exit ends the zmx
    /// daemon; `isSessionMissing` flips true; Graftty never marked the
    /// close as intentional. The decision function must still route to
    /// `.closePane` — rebuilding the surface would leave a ghost pane.
    /// See the file-level doc on `paneCloseAction()` for why there is no
    /// distinguishing signal today.
    @Test("""
    @spec TERM-5.3: When a terminal pane's child process exits, the application shall automatically remove the pane from the split tree and free its surface without requiring user action.
    """)
    func closeSurfaceCallbackRoutesToClosePane() {
        #expect(paneCloseAction() == .closePane)
    }
}
