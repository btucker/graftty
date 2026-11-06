import Foundation
import GrafttyProtocol
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

    @Test func projectIconHueIsAvoided() {
        let repo = RepoEntry(path: "/repo", displayName: "Repo", worktrees: [
            WorktreeEntry(path: "/repo", branch: "main"), WorktreeEntry(path: "/repo/parser-cache", branch: "parser-cache")])
        ProjectHueRegistry.shared.set(250, for: repo.id)
        defer { ProjectHueRegistry.shared.set(nil, for: repo.id) }
        var state = AppState(repos: [repo])
        var recap = AttentionRecap(title: "Parser cache", completed: "Cached.", next: "Measure.", emoji: "🗃️")
        recap.icon = WorktreeDrawingSVGTests.svg("<circle cx=\"32\" cy=\"32\" r=\"9\" fill=\"primary\"/>")
        state.recordAgentRecap(recap, callerPath: "/repo/parser-cache", reportedAt: Date())
        #expect(state.repos[0].worktrees[1].drawingHue == 70)
    }
}
