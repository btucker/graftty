import Foundation
import Testing
@testable import GrafttyProtocol

/// Wire-compatibility guard for `[WorktreePanes]`. `Fixtures/worktree-panes-v1.json`
/// was captured from the encoder at the parent of #484's first PR (main
/// e4e8bf8a) for `WorktreePanesWireFixture.rows`. Decoding it checks that new
/// code reads what released hosts send; re-encoding to the same JSON object
/// checks that released clients read what new hosts send.
@Suite("WorktreePanes wire fixture")
struct WorktreePanesWireFixtureTests {
    private func fixture() throws -> Data {
        try WireFixture.data("worktree-panes-v1")
    }

    @Test
    func releasedEncoderOutputDecodesToTheSameRows() throws {
        let decoded = try JSONDecoder().decode([WorktreePanes].self, from: fixture())
        #expect(decoded == WorktreePanesWireFixture.rows)
    }

    @Test
    func currentEncoderProducesTheReleasedJSON() throws {
        let encoded = try JSONEncoder().encode(WorktreePanesWireFixture.rows)
        let current = try JSONSerialization.jsonObject(with: encoded) as? NSArray
        let released = try JSONSerialization.jsonObject(with: fixture()) as? NSArray
        #expect(current != nil)
        #expect(current == released)
    }

    /// `encode(to:)` is hand-written, so a new field that misses an encode
    /// line (or a value in `WorktreePanesWireFixture.rows`) fails here.
    @Test
    func fixtureRowsEncodeEveryCodingKey() throws {
        // Keep the released fixture frozen while including fields added since release.
        let currentRows = WorktreePanesWireFixture.rows + [WorktreePanesWireFixture.rows[0].with(
            creationProgress: WorktreeCreationProgress(operationID: "fixture", startedAt: .distantPast))]
        let encoded = try JSONEncoder().encode(currentRows)
        let rows = try #require(try JSONSerialization.jsonObject(with: encoded) as? [[String: Any]])
        let keys = Set(rows.flatMap(\.keys))
        #expect(keys == Set(WorktreePanes.CodingKeys.allCases.map(\.stringValue)))
    }

    @Test("""
    @spec REMOTE-13.30: If a worktree snapshot carries an attention source or timestamp without attention text, \
    then the application shall treat the worktree as having no worktree-scoped attention.
    """)
    func attentionSourceWithoutTextIsNoAttention() throws {
        let orphan = #"""
        {"path":"/r","displayName":"r","repoDisplayName":"r","attentionSource":"agentStop","attentionTimestamp":5}
        """#
        let row = try JSONDecoder().decode(WorktreePanes.self, from: Data(orphan.utf8))
        #expect(row.attentionSource == nil)
        #expect(row.attentionTimestamp == nil)
        #expect(row.attention == nil)
        let reencoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(row)) as? [String: Any]
        #expect(reencoded?.keys.contains { $0.hasPrefix("attention") } == false)
    }
}

enum WorktreePanesWireFixture {
    private static let paneAttentionAt = Date(timeIntervalSince1970: 1_700_000_001.25)

    /// Every optional field populated at least once, across running, closed
    /// and stale rows, a split layout, and a relayed row.
    static let rows: [WorktreePanes] = [
        WorktreePanes(
            path: "/repo/.worktrees/feat",
            displayName: "feat",
            repoDisplayName: "repo",
            repositoryID: "/repo",
            displayBranch: "feature/login",
            state: .running,
            isMainCheckout: false,
            prBadge: PRBadge(
                number: 42, state: .open, checks: .success, mergeable: .conflicting,
                url: URL(string: "https://github.com/btucker/graftty/pull/42")!),
            stats: WorktreeWireStats(
                ahead: 3, behind: 1, hasUncommittedChanges: true, baseRef: "origin/main",
                insertions: 10, deletions: 4),
            attentionText: "tests failed",
            attentionSource: .agentStop,
            attentionTimestamp: Date(timeIntervalSince1970: 1_700_000_000.5),
            layout: .split(
                direction: .horizontal,
                ratio: 0.25,
                left: .leaf(sessionName: "graftty-aaaa", title: "", attentionText: nil,
                            isBusy: true, attentionSource: nil),
                right: .split(
                    direction: .vertical,
                    ratio: 0.5,
                    left: .leaf(sessionName: "graftty-bbbb", title: "vim", attentionText: "build broken",
                                isBusy: false, attentionSource: .userNotify,
                                attentionTimestamp: paneAttentionAt),
                    right: .leaf(sessionName: "", title: "", attentionText: "✓",
                                 isBusy: false, attentionSource: .commandFinished))),
            origin: WorktreeOrigin(deviceID: RemoteDeviceID(value: "dev-a"), deviceLabel: "Mac A", relayDepth: 0),
            sidebar: SidebarWorktreeMetadata(
                id: "dev-a:proj:/repo/.worktrees/feat", projectID: "dev-a:proj",
                folders: ["Work", "Auth"], folderIDs: ["f1", "f2"],
                paneIDs: ["graftty-aaaa": "1", "graftty-bbbb": "2"],
                paneSlotIDs: ["slot-1", "slot-2", "slot-3"],
                attentionTimestamps: ["graftty-bbbb": 1_700_000_001.25],
                lastAgentStop: SidebarAgentStop(
                    agentName: "claude", stoppedAt: Date(timeIntervalSince1970: 1_699_999_000)),
                agentProgressTimes: ["graftty-aaaa": 1_699_999_500],
                emoji: "🧭",
                isPinned: true),
            ports: [WorktreePort(port: 3000, scope: .loopback, processName: "node")],
            portBindings: ["graftty-aaaa": [
                PortBinding(port: 3000, scope: .loopback, processName: "node", pid: 4242),
                PortBinding(port: 8080, scope: .lan, processName: "python", pid: 4243, targetHost: "0.0.0.0"),
            ]]
        ),
        WorktreePanes(
            path: "/repo",
            displayName: "main",
            repoDisplayName: "repo",
            repositoryID: "/repo",
            displayBranch: "main",
            state: .closed,
            isMainCheckout: true,
            prBadge: nil,
            stats: WorktreeWireStats(ahead: 0, behind: 0, hasUncommittedChanges: false, baseRef: nil),
            attentionText: nil,
            layout: .leaf(sessionName: "graftty-cccc", title: "zsh", attentionText: nil,
                          isBusy: false, attentionSource: nil),
            sidebar: SidebarWorktreeMetadata(id: "dev-a:proj:/repo", projectID: "dev-a:proj")
        ),
        WorktreePanes(
            path: "alias-gone",
            displayName: "gone",
            repoDisplayName: "repo",
            repositoryID: "repo-alias",
            displayBranch: "old",
            state: .stale,
            isMainCheckout: false,
            prBadge: nil,
            stats: nil,
            attentionText: "Claude needs input",
            attentionSource: .agentStop,
            layout: nil,
            origin: WorktreeOrigin(deviceID: RemoteDeviceID(value: "dev-b"), deviceLabel: "Mac B", relayDepth: 1),
            route: WorktreeRoute(repositoryID: "repo-alias", worktreeID: "alias-gone"),
            portBindings: [:]
        ),
    ]
}
