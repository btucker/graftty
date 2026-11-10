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

@Suite("@spec AGENT-3.34: When a valid recap newer than the worktree's brief carries a drawing for a linked worktree, the application shall adopt it if the worktree has none, replace it only when the same recap sets purposeChanged, keep its assigned hue across redraws, and ignore drawings for the home checkout.")
struct WorktreeDrawingAdoptionTests {
    @Test func staleRecapKeepsNewerDrawing() {
        var state = AppState(repos: repos())
        let now = Date()
        state.recordAgentRecap(recap(icon: secondDrawing), callerPath: "/repo/parser-cache", reportedAt: now)
        state.recordAgentRecap(recap(icon: firstDrawing, purposeChanged: true), callerPath: "/repo/parser-cache",
                               reportedAt: now.addingTimeInterval(-60))
        #expect(state.repos[0].worktrees[1].drawing?.svg == secondDrawing)
    }

    @Test func droppedStopKeepsNewerDrawing() {
        var state = AppState(repos: repos())
        let now = Date()
        for (icon, stoppedAt) in [(secondDrawing, now), (firstDrawing, now.addingTimeInterval(-60))] {
            _ = state.recordStoppedTurn(callerPath: "/repo/parser-cache", runtime: .codex, callerAgentID: "agent",
                                        sessionID: "session", paneSessionName: nil, recap: recap(icon: icon, purposeChanged: true),
                                        stoppedAt: stoppedAt, paneTitle: { _, _ in nil })
        }
        #expect(state.repos[0].worktrees[1].drawing?.svg == secondDrawing)
    }

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

@Suite("@spec LAYOUT-2.204: If a host cannot render worktree drawings, then the application shall not advertise their revisions, so clients keep showing the emoji instead of requesting images the host cannot serve.")
struct WorktreeDrawingAdvertisingTests {
    @Test func metadataAdvertisesOnlyRenderableDrawings() {
        var worktree = WorktreeEntry(path: "/repo/parser-cache", branch: "parser-cache")
        worktree.drawingHue = 25
        worktree.drawing = WorktreeDrawing(svg: firstDrawing, hue: 25)
        let metadata = SidebarHostNavigation.metadata(for: worktree, projectID: "repo", folders: [], repositoryPath: "/repo")
        #if canImport(AppKit)
        #expect(metadata.drawingRevision == worktree.drawing?.revision)
        #else
        #expect(metadata.drawingRevision == nil)
        #endif
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

private let wideDrawing = WorktreeDrawingSVGTests.svg("<rect x=\"8\" y=\"8\" width=\"80\" height=\"48\" fill=\"accent\"/>", viewBox: "0 0 96 64")
private let otherWideDrawing = WorktreeDrawingSVGTests.svg("<circle cx=\"48\" cy=\"32\" r=\"20\" fill=\"primary\"/>", viewBox: "0 0 96 64")

@Suite("@spec AGENT-3.40: When a worktree's adopted drawing uses the older square canvas, the application shall replace it with the first wide drawing a valid recap carries, even without purposeChanged, and keep its hue.")
struct WorktreeWideRedrawTests {
    @Test func squareDrawingTakesOneWideRedraw() {
        var repos = repos()
        SidebarHostNavigation.adoptReportedDrawing(recap(icon: firstDrawing), worktreePath: "/repo/parser-cache", projectHue: nil, in: &repos)
        let hue = repos[0].worktrees[1].drawingHue
        // Another square drawing still needs a purpose change.
        SidebarHostNavigation.adoptReportedDrawing(recap(icon: secondDrawing), worktreePath: "/repo/parser-cache", projectHue: nil, in: &repos)
        #expect(repos[0].worktrees[1].drawing?.svg == firstDrawing)
        SidebarHostNavigation.adoptReportedDrawing(recap(icon: wideDrawing), worktreePath: "/repo/parser-cache", projectHue: nil, in: &repos)
        #expect(repos[0].worktrees[1].drawing?.svg == wideDrawing)
        #expect(repos[0].worktrees[1].drawingHue == hue)
        // Once wide, the usual rule applies again.
        SidebarHostNavigation.adoptReportedDrawing(recap(icon: otherWideDrawing), worktreePath: "/repo/parser-cache", projectHue: nil, in: &repos)
        #expect(repos[0].worktrees[1].drawing?.svg == wideDrawing)
    }
}

