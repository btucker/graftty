import Testing
import GrafttyKit
import GrafttyProtocol
@testable import Graftty

@MainActor
struct SidebarSelectedWorktreeProjectionTests {
    private let owner = WorktreeOrigin(deviceID: .init(value: "local"), deviceLabel: "Mac", relayDepth: 0)

    // Stored, not computed: entries mint fresh UUIDs, and row identity embeds them.
    private let state = AppState(repos: [
        .init(path: "/alpha", displayName: "Alpha", worktrees: [
            WorktreeEntry(path: "/alpha", branch: "main"),
            WorktreeEntry(path: "/alpha/.worktrees/research/lead", branch: "feature/lead"),
            WorktreeEntry(path: "/alpha/.worktrees/research/notes", branch: "feature/notes"),
        ]),
        .init(path: "/beta", displayName: "Beta", worktrees: [
            WorktreeEntry(path: "/beta", branch: "trunk"),
            WorktreeEntry(path: "/beta/.worktrees/lead", branch: "feature/lead"),
        ]),
    ])

    @Test("@spec PERF-1.15: When the main window resolves the selected local worktree's context, the application shall project only that worktree's repository and produce the same row as the full sidebar projection.")
    func selectedRowMatchesFullProjectionAndResolvesOneRepository() throws {
        let titles: [PaneSlotID: String] = [:]
        let full = sidebarLocalWorktrees(state: state, owner: owner, titles: titles, liveness: [:],
                                         defaultBranch: { _ in "main" })
        for expected in full {
            var resolved: [String] = []
            let row = sidebarLocalWorktree(atPath: expected.path, state: state, owner: owner, titles: titles,
                liveness: [:], prBadge: nil, defaultBranch: { resolved.append($0.path); return "main" })
            #expect(row == expected)
            #expect(resolved.count == 1)
        }
        #expect(sidebarLocalWorktree(atPath: "/missing", state: state, owner: owner, titles: titles,
                                     liveness: [:], prBadge: nil) == nil)
    }
}
