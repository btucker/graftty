import Testing
@testable import GrafttyCommandUI

struct AgentTileStatusTests {
    private func status(needsInput: Bool = false, isBusy: Bool = false, isCompleted: Bool = false, isCached: Bool = false,
                        question: String? = nil, result: String? = nil) -> AgentTileStatus {
        AgentTileStatus(needsInput: needsInput, isBusy: isBusy, isCompleted: isCompleted, isCached: isCached,
                        question: question, result: result, statusLabel: "Running")
    }

    @Test("@spec LAYOUT-2.251: While an agent is shown as a gallery tile, the application shall show an orange dot before its name only while it asks for user input, a pulsing blue dot while it works, dim it once it has finished or while its host sleeps, and caption it with its question, else its result, else its status.")
    func tileStatus() {
        #expect(status(needsInput: true, isBusy: true, question: "Retry?").dot == .asking)
        #expect(status(needsInput: true, isBusy: true, question: "Retry?").caption == "Retry?")
        #expect(status(isBusy: true).dot == .working)
        #expect(status().dot == nil)
        #expect(status().caption == "Running")
        let finished = status(isCompleted: true, result: "212 pass")
        #expect(finished.dot == nil && finished.isDimmed)
        #expect(finished.caption == "212 pass")
        let asleep = status(needsInput: true, isBusy: true, isCached: true)
        #expect(asleep.dot == nil && asleep.isDimmed)
        #expect(!status(isBusy: true).isDimmed)
    }

    @Test("@spec LAYOUT-2.262: While a worktree's gallery holds agents that have finished, the application shall list them in their tile order after the tile for adding an agent, under a Finished heading that gives their count and stays collapsed until the user opens it, and shall show each as its name and result with no terminal miniature.")
    func finishedAgentsLeaveTheLiveTiles() {
        let tiles = [("a", status(isBusy: true)), ("b", status(isCompleted: true, result: "Done")),
                     ("c", status(isCached: true)), ("d", status(isCompleted: true))]
        let split = AgentGalleryFinished.split(tiles) { $0.1 }
        #expect(split.active.map(\.0) == ["a", "c"])
        #expect(split.finished.map(\.0) == ["b", "d"])
        #expect(AgentGalleryFinished.title(count: 2) == "Finished · 2")
    }
}
