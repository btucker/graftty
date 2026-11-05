import Testing
@testable import GrafttyKit

@Suite("@spec LAYOUT-2.199: When a linked worktree first receives a drawing, the application shall assign it a permanent OKLCH hue farthest from the hues of the other drawn worktrees in its project and from the project icon's dominant hue.")
struct WorktreeColorAssignmentTests {
    @Test func firstHueIsWarmDefault() {
        #expect(WorktreeColorAssignment.hue(avoiding: []) == 25)
    }

    @Test func oppositeOfSingle() {
        #expect(WorktreeColorAssignment.hue(avoiding: [250]) == 70)
    }

    @Test func fillsLargestGap() {
        #expect(WorktreeColorAssignment.hue(avoiding: [0, 120, 240]) == 60)
    }

    @Test func distanceWraps() {
        #expect(WorktreeColorAssignment.hueDistance(350, 10) == 20)
    }
}
