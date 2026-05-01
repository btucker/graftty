import Testing
@testable import Graftty

@Suite("App visibility surface policy")
struct AppVisibilitySurfacePolicyTests {
    @Test("""
@spec PERF-1.4: When macOS hides the app, the selected worktree's terminal surfaces shall be marked not visible so libghostty can stop repaint work that is not reaching the screen.
""")
    func hidingAppHidesSelectedWorktreeSurfaces() {
        #expect(
            AppVisibilitySurfacePolicy.action(
                selectedWorktreePath: "/repo/wt",
                appIsVisible: false
            ) == .setSelectedWorktreeVisible(path: "/repo/wt", visible: false)
        )
    }

    @Test("""
@spec PERF-1.5: When macOS unhides the app, the selected worktree's terminal surfaces shall be marked visible again so the terminal gets a clean repaint.
""")
    func unhidingAppShowsSelectedWorktreeSurfaces() {
        #expect(
            AppVisibilitySurfacePolicy.action(
                selectedWorktreePath: "/repo/wt",
                appIsVisible: true
            ) == .setSelectedWorktreeVisible(path: "/repo/wt", visible: true)
        )
    }

    @Test("No selected worktree means app visibility changes do not touch terminal surfaces")
    func noSelectedWorktreeNoops() {
        #expect(AppVisibilitySurfacePolicy.action(selectedWorktreePath: nil, appIsVisible: false) == nil)
    }
}
