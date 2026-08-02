import Foundation
import GrafttyKit
import GrafttyProtocol
import SwiftUI
import Testing
@testable import Graftty

@Suite("Stale worktree dismissal")
struct StaleWorktreeDismissalTests {
    @MainActor
    @Test("""
    @spec GIT-3.21: When a worktree has remained in the stale state for one hour, the application shall automatically dismiss it using the same teardown as the manual Dismiss action: destroy any retained terminal surfaces, clear per-path PR and divergence caches, clear selection when applicable, and remove the entry. The one-hour grace period shall begin when the stale transition is first observed, persist across app relaunches, and be cancelled if the worktree resurrects before expiry.
    """)
    func expiredStaleWorktreeUsesFullDismissalTeardown() async {
        let now = Date(timeIntervalSince1970: 10_000)
        let expiredPane = PaneSlotID()
        var expired = WorktreeEntry(
            path: "/repo/expired",
            branch: "expired",
            state: .stale,
            staleSince: now.addingTimeInterval(-3_600)
        )
        expired.splitTree = SplitTree(root: .leaf(expiredPane))
        let recent = WorktreeEntry(
            path: "/repo/recent",
            branch: "recent",
            state: .stale,
            staleSince: now.addingTimeInterval(-3_599)
        )
        let box = StateBox(AppState(
            repos: [
                RepoEntry(
                    path: "/repo",
                    displayName: "repo",
                    worktrees: [expired, recent]
                ),
            ],
            selectedWorktreePath: expired.path
        ))
        let binding = Binding(
            get: { box.value },
            set: { box.value = $0 }
        )
        var events: [String] = []

        let dismissed = await StaleWorktreeDismissal.dismissExpired(
            appState: binding,
            now: now,
            discoverWorktrees: { _ in [] },
            destroySurfaces: { panes in
                #expect(panes == [expiredPane])
                events.append("surfaces")
            },
            clearPRStatus: { path in
                #expect(path == expired.path)
                events.append("pr")
            },
            clearStats: { path in
                #expect(path == expired.path)
                events.append("stats")
            },
            onDismiss: { _ in
                events.append("persist")
            }
        )

        #expect(dismissed == [expired.id])
        #expect(events == ["surfaces", "pr", "stats", "persist"])
        #expect(box.value.repos[0].worktrees.map(\.id) == [recent.id])
        #expect(box.value.selectedWorktreePath == nil)
    }

    @MainActor
    @Test func expiredWorktreeThatReappearedIsPreserved() async {
        let now = Date(timeIntervalSince1970: 10_000)
        let worktree = WorktreeEntry(
            path: "/repo/back",
            branch: "feature",
            state: .stale,
            staleSince: now.addingTimeInterval(-7_200)
        )
        let box = StateBox(AppState(repos: [
            RepoEntry(
                path: "/repo",
                displayName: "repo",
                worktrees: [worktree]
            ),
        ]))

        let dismissed = await StaleWorktreeDismissal.dismissExpired(
            appState: Binding(
                get: { box.value },
                set: { box.value = $0 }
            ),
            now: now,
            discoverWorktrees: { _ in
                GitWorktreeDiscovery.parsePorcelain("""
                worktree \(worktree.path)
                branch refs/heads/\(worktree.branch)

                """)
            },
            destroySurfaces: { _ in Issue.record("unexpected surface teardown") },
            clearPRStatus: { _ in Issue.record("unexpected PR clear") },
            clearStats: { _ in Issue.record("unexpected stats clear") }
        )

        #expect(dismissed.isEmpty)
        #expect(box.value.repos[0].worktrees == [worktree])
    }

    @MainActor
    @Test func ordinaryDirectoryAtOldPathDoesNotBlockDismissal() async throws {
        let now = Date(timeIntervalSince1970: 10_000)
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("graftty-stale-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: path) }

        let worktree = WorktreeEntry(
            path: path.path,
            branch: "feature",
            state: .stale,
            staleSince: now.addingTimeInterval(-3_600)
        )
        let box = StateBox(AppState(repos: [
            RepoEntry(
                path: "/repo",
                displayName: "repo",
                worktrees: [worktree]
            ),
        ]))

        let dismissed = await StaleWorktreeDismissal.dismissExpired(
            appState: Binding(
                get: { box.value },
                set: { box.value = $0 }
            ),
            now: now,
            // Git porcelain is authoritative: the directory exists, but
            // the deleted worktree is still absent from discovery.
            discoverWorktrees: { _ in [] },
            destroySurfaces: { _ in },
            clearPRStatus: { _ in },
            clearStats: { _ in }
        )

        #expect(dismissed == [worktree.id])
        #expect(box.value.repos[0].worktrees.isEmpty)
    }

    @MainActor
    @Test func prunableGitMetadataDoesNotBlockDismissal() async {
        let now = Date(timeIntervalSince1970: 10_000)
        let worktree = WorktreeEntry(
            path: "/repo/wt",
            branch: "feature",
            state: .stale,
            staleSince: now.addingTimeInterval(-3_600)
        )
        let box = StateBox(AppState(repos: [
            RepoEntry(
                path: "/repo",
                displayName: "repo",
                worktrees: [worktree]
            ),
        ]))

        let dismissed = await StaleWorktreeDismissal.dismissExpired(
            appState: Binding(
                get: { box.value },
                set: { box.value = $0 }
            ),
            now: now,
            discoverWorktrees: { _ in
                GitWorktreeDiscovery.parsePorcelain("""
                worktree /repo
                HEAD abc123
                branch refs/heads/main

                worktree \(worktree.path)
                HEAD def456
                branch refs/heads/\(worktree.branch)
                prunable gitdir file points to non-existent location

                """)
            },
            destroySurfaces: { _ in },
            clearPRStatus: { _ in },
            clearStats: { _ in }
        )

        #expect(dismissed == [worktree.id])
    }

    @MainActor
    @Test func discoveryFailurePreservesExpiredWorktree() async {
        enum ExpectedError: Error { case unavailable }

        let now = Date(timeIntervalSince1970: 10_000)
        let worktree = WorktreeEntry(
            path: "/repo/wt",
            branch: "feature",
            state: .stale,
            staleSince: now.addingTimeInterval(-3_600)
        )
        let box = StateBox(AppState(repos: [
            RepoEntry(
                path: "/repo",
                displayName: "repo",
                worktrees: [worktree]
            ),
        ]))

        let dismissed = await StaleWorktreeDismissal.dismissExpired(
            appState: Binding(
                get: { box.value },
                set: { box.value = $0 }
            ),
            now: now,
            discoverWorktrees: { _ in throw ExpectedError.unavailable },
            destroySurfaces: { _ in Issue.record("unexpected surface teardown") },
            clearPRStatus: { _ in Issue.record("unexpected PR clear") },
            clearStats: { _ in Issue.record("unexpected stats clear") }
        )

        #expect(dismissed.isEmpty)
        #expect(box.value.repos[0].worktrees == [worktree])
    }

    @MainActor
    @Test func freshStaleTransitionDuringDiscoveryGetsNewGracePeriod() async {
        let now = Date(timeIntervalSince1970: 10_000)
        let worktree = WorktreeEntry(
            path: "/repo/wt",
            branch: "feature",
            state: .stale,
            staleSince: now.addingTimeInterval(-3_600)
        )
        let box = StateBox(AppState(repos: [
            RepoEntry(
                path: "/repo",
                displayName: "repo",
                worktrees: [worktree]
            ),
        ]))
        let binding = Binding(
            get: { box.value },
            set: { box.value = $0 }
        )

        let dismissed = await StaleWorktreeDismissal.dismissExpired(
            appState: binding,
            now: now,
            discoverWorktrees: { _ in
                // The original stale generation resurrected, then the same
                // model row was deleted again while discovery was suspended.
                box.value.repos[0].worktrees[0].state = .closed
                box.value.repos[0].worktrees[0].markStale(at: now)
                return []
            },
            destroySurfaces: { _ in Issue.record("unexpected surface teardown") },
            clearPRStatus: { _ in Issue.record("unexpected PR clear") },
            clearStats: { _ in Issue.record("unexpected stats clear") }
        )

        #expect(dismissed.isEmpty)
        #expect(box.value.repos[0].worktrees[0].staleSince == now)
    }

    @MainActor
    @Test func dismissalRechecksStaleStateBeforeRemoving() {
        let worktree = WorktreeEntry(path: "/repo/wt", branch: "feature")
        let box = StateBox(AppState(repos: [
            RepoEntry(
                path: "/repo",
                displayName: "repo",
                worktrees: [worktree]
            ),
        ]))

        let dismissed = StaleWorktreeDismissal.dismiss(
            worktreeID: worktree.id,
            appState: Binding(
                get: { box.value },
                set: { box.value = $0 }
            ),
            destroySurfaces: { _ in Issue.record("unexpected surface teardown") },
            clearPRStatus: { _ in Issue.record("unexpected PR clear") },
            clearStats: { _ in Issue.record("unexpected stats clear") }
        )

        #expect(!dismissed)
        #expect(box.value.repos[0].worktrees == [worktree])
    }
}

@MainActor
private final class StateBox {
    var value: AppState

    init(_ value: AppState) {
        self.value = value
    }
}
