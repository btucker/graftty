import Foundation
import Testing
@testable import GrafttyProtocol

@Suite("WorktreePanes wire payload")
struct WorktreePanesTests {

    @Test
    func fullPayloadRoundTrips() throws {
        let original = WorktreePanes(
            path: "/repo/.worktrees/feat",
            displayName: "feat",
            repoDisplayName: "repo",
            displayBranch: "feature/login",
            state: .running,
            isMainCheckout: false,
            prBadge: PRBadge(
                number: 42,
                state: .open,
                checks: .success,
                mergeable: .conflicting,
                url: URL(string: "https://github.com/btucker/graftty/pull/42")!
            ),
            stats: WorktreeWireStats(
                ahead: 3,
                behind: 1,
                hasUncommittedChanges: true,
                baseRef: "origin/main"
            ),
            attentionText: "tests failed",
            layout: .split(
                direction: .horizontal,
                ratio: 0.5,
                left: .leaf(sessionName: "L", title: "left", attentionText: nil),
                right: .leaf(sessionName: "R", title: "right", attentionText: "build broken")
            )
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(WorktreePanes.self, from: data)
        #expect(decoded == original)
    }

    @Test("""
    @spec IOS-4.16: When the mobile client decodes a `WorktreePanes` payload from a server that predates the sidebar-mirror fields (state, branch, isMainCheckout, prBadge, stats, attentionText), the application shall fall back to safe defaults — empty branch, `.running` state, no PR badge, no stats, no attention — rather than fail decoding, so a version mismatch in either direction keeps the mobile picker functional.
    """)
    func legacyPayloadDecodesWithDefaults() throws {
        let legacyJSON = """
        {
          "path": "/repo/.worktrees/old",
          "displayName": "old",
          "repoDisplayName": "repo",
          "layout": null
        }
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(WorktreePanes.self, from: legacyJSON)
        #expect(decoded.path == "/repo/.worktrees/old")
        #expect(decoded.displayName == "old")
        #expect(decoded.displayBranch == "")
        // Default to .running because legacy servers only ever sent
        // running worktrees; a renderer that branches on state will
        // pick the most-frequent path.
        #expect(decoded.state == .running)
        #expect(decoded.isMainCheckout == false)
        #expect(decoded.prBadge == nil)
        #expect(decoded.stats == nil)
        #expect(decoded.attentionText == nil)
        #expect(decoded.layout == nil)
    }

    @Test
    func paneAttentionRoundTrips() throws {
        let leaf = PaneLayoutNode.leaf(sessionName: "s", title: "t", attentionText: "ping")
        let data = try JSONEncoder().encode(leaf)
        let decoded = try JSONDecoder().decode(PaneLayoutNode.self, from: data)
        #expect(decoded == leaf)
    }

    @Test
    func legacyLeafWithoutAttentionDecodesAsNil() throws {
        let legacy = """
        {"kind":"leaf","sessionName":"s","title":"t"}
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(PaneLayoutNode.self, from: legacy)
        if case let .leaf(sessionName, title, attentionText) = decoded {
            #expect(sessionName == "s")
            #expect(title == "t")
            #expect(attentionText == nil)
        } else {
            Issue.record("expected leaf, got split")
        }
    }

    @Test
    func wireStatsIsEmptyAtParity() {
        #expect(
            WorktreeWireStats(ahead: 0, behind: 0, hasUncommittedChanges: false, baseRef: nil)
                .isEmpty
        )
        #expect(
            !WorktreeWireStats(ahead: 0, behind: 0, hasUncommittedChanges: true, baseRef: nil)
                .isEmpty
        )
    }
}
