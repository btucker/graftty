import Foundation
import SwiftUI
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
                left: .leaf(sessionName: "L", title: "left", attentionText: nil, isBusy: false),
                right: .leaf(sessionName: "R", title: "right", attentionText: "build broken", isBusy: false)
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
        let leaf = PaneLayoutNode.leaf(sessionName: "s", title: "t", attentionText: "ping", isBusy: false)
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
        if case let .leaf(sessionName, title, attentionText, _) = decoded {
            #expect(sessionName == "s")
            #expect(title == "t")
            #expect(attentionText == nil)
        } else {
            Issue.record("expected leaf, got split")
        }
    }

    @Test("WorktreeWireState.hasOnDiskWorktree mirrors the Mac WorktreeState semantics: closed/running=true, stale/creating/deleting=false")
    func hasOnDiskWorktreeMirror() {
        // True only when the on-disk path corresponds to a real git
        // worktree the host can inspect.
        #expect(WorktreeWireState.closed.hasOnDiskWorktree == true)
        #expect(WorktreeWireState.running.hasOnDiskWorktree == true)
        // False for the three "no usable on-disk worktree" buckets,
        // matching `WorktreeState.hasOnDiskWorktree` server-side.
        #expect(WorktreeWireState.stale.hasOnDiskWorktree == false)
        #expect(WorktreeWireState.creating.hasOnDiskWorktree == false)
        #expect(WorktreeWireState.deleting.hasOnDiskWorktree == false)
    }

    @Test
    func busyLeafRoundTrips() throws {
        let leaf = PaneLayoutNode.leaf(
            sessionName: "s", title: "t", attentionText: nil, isBusy: true)
        let data = try JSONEncoder().encode(leaf)
        let decoded = try JSONDecoder().decode(PaneLayoutNode.self, from: data)
        #expect(decoded == leaf)
        if case let .leaf(_, _, _, isBusy) = decoded {
            #expect(isBusy == true)
        } else {
            Issue.record("expected leaf")
        }
    }

    @Test
    func legacyLeafWithoutIsBusyDecodesAsFalse() throws {
        let legacy = #"{"kind":"leaf","sessionName":"s","title":"t"}"#.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(PaneLayoutNode.self, from: legacy)
        if case let .leaf(_, _, _, isBusy) = decoded {
            #expect(isBusy == false)
        } else {
            Issue.record("expected leaf")
        }
    }

    @Test("""
@spec AGENT-2.1: While a pane has a live notify attention ping, the application shall render that ping in preference to any derived busy/idle status.
""")
    func pingSupersedesBusyStyle() {
        // A live capsule wins: the busy italic style is suppressed so the
        // capsule (rendered beside the title) is the unambiguous signal.
        #expect(PaneTitleBusyStyle.applies(isBusy: true, hasAttentionCapsule: true) == false)
        // No capsule: a busy session styles the title.
        #expect(PaneTitleBusyStyle.applies(isBusy: true, hasAttentionCapsule: false) == true)
        // Not busy: never styled, capsule or not.
        #expect(PaneTitleBusyStyle.applies(isBusy: false, hasAttentionCapsule: true) == false)
        #expect(PaneTitleBusyStyle.applies(isBusy: false, hasAttentionCapsule: false) == false)
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
