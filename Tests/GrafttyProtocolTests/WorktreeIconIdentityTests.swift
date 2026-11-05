import Foundation
import Testing
@testable import GrafttyProtocol

@Suite("@spec LAYOUT-2.200: While a linked worktree has an adopted drawing, the application shall identify it by that drawing ahead of an agent emoji, while a home checkout keeps its project icon and an emoji the user chose keeps precedence.")
struct WorktreeIconIdentityTests {
    @Test func drawingBeatsAgentEmoji() {
        #expect(WorktreeIconIdentity.resolve(isMainCheckout: false, emoji: "🗃️", drawingRevision: "r:25", emojiChosenByUser: false)
            == .drawing(revision: "r:25", emoji: "🗃️"))
    }

    @Test func homeCheckoutIgnoresDrawing() {
        #expect(WorktreeIconIdentity.resolve(isMainCheckout: true, emoji: nil, drawingRevision: "r:25", emojiChosenByUser: false) == .project)
    }

    @Test func userChosenEmojiBeatsDrawing() {
        #expect(WorktreeIconIdentity.resolve(isMainCheckout: false, emoji: "🎱", drawingRevision: "r:25", emojiChosenByUser: true) == .emoji("🎱"))
    }

    @Test func noDrawingKeepsEmoji() {
        #expect(WorktreeIconIdentity.resolve(isMainCheckout: false, emoji: "🗃️", drawingRevision: nil, emojiChosenByUser: false) == .emoji("🗃️"))
        #expect(WorktreeIconIdentity.resolve(isMainCheckout: false, emoji: nil) == WorktreeIconIdentity.none)
    }

    @Test func effectiveEmojiSurvivesDrawing() {
        var metadata = SidebarWorktreeMetadata(id: "p:w", projectID: "p", emoji: "🗃️")
        metadata.drawingRevision = "r:25"
        let panes = WorktreePanes(path: "/repo/parser-cache", displayName: "parser-cache", repoDisplayName: "Repo",
            displayBranch: "parser-cache", state: .closed, isMainCheckout: false, prBadge: nil, stats: nil, attentionText: nil,
            layout: nil, sidebar: metadata)
        #expect(panes.iconIdentity == .drawing(revision: "r:25", emoji: "🗃️"))
        #expect(panes.effectiveEmoji == "🗃️")
    }

    @Test func metadataDecodesWithoutDrawingKeys() throws {
        let legacy = try JSONEncoder().encode(SidebarWorktreeMetadata(id: "p:w", projectID: "p", emoji: "🗃️"))
        let decoded = try JSONDecoder().decode(SidebarWorktreeMetadata.self, from: legacy)
        #expect(decoded.drawingRevision == nil)
        #expect(decoded.emojiChosenByUser == nil)
    }
}
