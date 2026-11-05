import Foundation
import GrafttyProtocol
import Testing
@testable import GrafttyKit

private let firstDrawing = WorktreeDrawingSVGTests.svg("<circle cx=\"32\" cy=\"32\" r=\"20\" fill=\"primary\" stroke=\"ink\"/>")
private let secondDrawing = WorktreeDrawingSVGTests.svg("<rect x=\"8\" y=\"8\" width=\"48\" height=\"48\" fill=\"accent\"/>")

private func recap(icon: String?, purposeChanged: Bool? = nil) -> AttentionRecap {
    var recap = AttentionRecap(title: "Parser cache", completed: "Cached parses.", next: "Measure.", emoji: "🗃️",
                               purposeChanged: purposeChanged)
    recap.icon = icon
    return recap
}

private func repos() -> [RepoEntry] {
    [RepoEntry(path: "/repo", displayName: "Repo", worktrees: [
        WorktreeEntry(path: "/repo", branch: "main"),
        WorktreeEntry(path: "/repo/parser-cache", branch: "parser-cache"),
        WorktreeEntry(path: "/repo/lexer-speed", branch: "lexer-speed"),
    ])]
}

@Suite("@spec AGENT-3.34: When a valid recap carries a drawing for a linked worktree, the application shall adopt it if the worktree has none, replace it only when the same recap sets purposeChanged, keep its assigned hue across redraws, and ignore drawings for the home checkout.")
struct WorktreeDrawingAdoptionTests {
    @Test func adoptsFirstDrawing() throws {
        var repos = repos()
        SidebarHostNavigation.adoptReportedDrawing(recap(icon: firstDrawing), worktreePath: "/repo/parser-cache", projectHue: nil, in: &repos)
        let worktree = repos[0].worktrees[1]
        #expect(worktree.drawing?.svg == firstDrawing)
        #expect(worktree.drawingHue == 25)
        #expect(worktree.drawing?.revision.hasSuffix(":25") == true)
    }

    @Test func keepsDrawingWithoutPurposeChange() {
        var repos = repos()
        SidebarHostNavigation.adoptReportedDrawing(recap(icon: firstDrawing), worktreePath: "/repo/parser-cache", projectHue: nil, in: &repos)
        SidebarHostNavigation.adoptReportedDrawing(recap(icon: secondDrawing), worktreePath: "/repo/parser-cache", projectHue: nil, in: &repos)
        SidebarHostNavigation.adoptReportedDrawing(recap(icon: secondDrawing, purposeChanged: false), worktreePath: "/repo/parser-cache", projectHue: nil, in: &repos)
        #expect(repos[0].worktrees[1].drawing?.svg == firstDrawing)
    }

    @Test func replacesOnPurposeChange() {
        var repos = repos()
        SidebarHostNavigation.adoptReportedDrawing(recap(icon: firstDrawing), worktreePath: "/repo/parser-cache", projectHue: 200, in: &repos)
        let hue = repos[0].worktrees[1].drawingHue
        SidebarHostNavigation.adoptReportedDrawing(recap(icon: secondDrawing, purposeChanged: true), worktreePath: "/repo/parser-cache", projectHue: 90, in: &repos)
        #expect(repos[0].worktrees[1].drawing?.svg == secondDrawing)
        #expect(repos[0].worktrees[1].drawingHue == hue)
    }

    @Test func homeCheckoutIgnoresDrawing() {
        var repos = repos()
        SidebarHostNavigation.adoptReportedDrawing(recap(icon: firstDrawing), worktreePath: "/repo", projectHue: nil, in: &repos)
        #expect(repos[0].worktrees[0].drawing == nil)
    }

    @Test func rejectsUnsafeDrawing() {
        var repos = repos()
        let unsafe = WorktreeDrawingSVGTests.svg("<script>x()</script>")
        SidebarHostNavigation.adoptReportedDrawing(recap(icon: unsafe), worktreePath: "/repo/parser-cache", projectHue: nil, in: &repos)
        #expect(repos[0].worktrees[1].drawing == nil)
    }

    @Test func siblingsGetDistinctHues() {
        var repos = repos()
        SidebarHostNavigation.adoptReportedDrawing(recap(icon: firstDrawing), worktreePath: "/repo/parser-cache", projectHue: 250, in: &repos)
        SidebarHostNavigation.adoptReportedDrawing(recap(icon: secondDrawing), worktreePath: "/repo/lexer-speed", projectHue: 250, in: &repos)
        #expect(repos[0].worktrees[1].drawingHue == 70)
        #expect(repos[0].worktrees[2].drawingHue == 160)
    }

    @Test func decodesEntryWithoutDrawingKeys() throws {
        let legacy = try JSONEncoder().encode(WorktreeEntry(path: "/repo/parser-cache", branch: "parser-cache"))
        var object = try #require(JSONSerialization.jsonObject(with: legacy) as? [String: Any])
        object["drawing"] = nil; object["drawingHue"] = nil; object["emojiChosenByUser"] = nil
        let decoded = try JSONDecoder().decode(WorktreeEntry.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(decoded.drawing == nil)
        #expect(decoded.emojiChosenByUser == false)
    }

    @Test func userChoiceIsRecordedAndCleared() {
        var repos = repos()
        let id = repos[0].worktrees[1].id
        #expect(SidebarHostNavigation.setManualEmoji("🎱", worktreeID: id, in: &repos))
        #expect(repos[0].worktrees[1].emojiChosenByUser)
        SidebarHostNavigation.clearEmoji(worktreeID: id, in: &repos)
        #expect(!repos[0].worktrees[1].emojiChosenByUser)
    }
}

@Suite("@spec AGENT-3.35: When the application records a recap that carried a drawing, it shall store and broadcast that recap without the drawing.")
struct WorktreeDrawingRecapStrippingTests {
    @Test func stoppedTurnStripsIcon() {
        var state = AppState(repos: repos())
        _ = state.recordStoppedTurn(callerPath: "/repo/parser-cache", runtime: .codex, callerAgentID: "agent", sessionID: "session",
                                    paneSessionName: nil, recap: recap(icon: firstDrawing), stoppedAt: Date(), paneTitle: { _, _ in nil })
        let worktree = state.repos[0].worktrees[1]
        #expect(worktree.drawing?.svg == firstDrawing)
        #expect(worktree.lastAgentStop?.recap != nil)
        #expect(worktree.lastAgentStop?.recap?.icon == nil)
    }

    @Test func recordedRecapAdoptsDrawing() {
        var state = AppState(repos: repos())
        state.recordAgentRecap(recap(icon: firstDrawing), callerPath: "/repo/parser-cache", reportedAt: Date())
        #expect(state.repos[0].worktrees[1].drawing?.svg == firstDrawing)
    }
}
