import Testing
import Foundation
import GrafttyProtocol
@testable import GrafttyKit

@Suite("BranchPickerViewModel")
struct BranchPickerViewModelTests {

    private func make(
        local: [(String, Date)] = [],
        remote: [(String, Date)] = [],
        mounted: [String: String] = [:],
        prs: [String: PRInfo] = [:],
        filter: String = ""
    ) -> [BranchPickerEntry] {
        let snapshot = RemoteBranchSnapshot(
            remoteBranches: remote.map { BranchRef(name: $0.0, lastCommitDate: $0.1) },
            localBranches: local.map { BranchRef(name: $0.0, lastCommitDate: $0.1) },
            upstreams: [:]
        )
        return BranchPickerViewModel.entries(
            branchSnapshot: snapshot,
            mountedBranchToPath: mounted,
            prsByBranch: prs,
            filterText: filter
        )
    }

    @Test("@spec GIT-5.13: While the user is in existing-branch mode, the application shall display branches sorted by last-commit date descending in an always-visible list, with branches mounted in another worktree dimmed and unselectable.")
    func sortsByDateDesc() {
        let now = Date()
        let entries = make(local: [
            ("old", now.addingTimeInterval(-3600 * 24 * 30)),
            ("new", now),
            ("mid", now.addingTimeInterval(-3600 * 24)),
        ])
        #expect(entries.map(\.name) == ["new", "mid", "old"])
    }

    @Test("dedupes local + remote — local wins")
    func dedupePrefersLocal() {
        let now = Date()
        let entries = make(
            local: [("feat", now)],
            remote: [("feat", now.addingTimeInterval(-1))]
        )
        #expect(entries.count == 1)
        #expect(entries.first?.source == .local)
    }

    @Test("dims branches with mountedWorktreePath")
    func annotatesMounted() {
        let now = Date()
        let entries = make(
            local: [("feat", now)],
            mounted: ["feat": "/r/.worktrees/feat"]
        )
        #expect(entries.first?.mountedWorktreePath == "/r/.worktrees/feat")
    }

    @Test("@spec GIT-5.14: When a branch row in the existing-branch picker has an associated open PR/MR, the application shall surface the PR number and title alongside the branch name.")
    func attachesPRInfo() {
        let now = Date()
        let pr = PRInfo(
            number: 42,
            title: "Add OAuth",
            url: URL(string: "https://x/y")!,
            state: .open,
            checks: .success,
            mergeable: .mergeable,
            fetchedAt: now
        )
        let entries = make(
            local: [("feat", now)],
            prs: ["feat": pr]
        )
        #expect(entries.first?.pr?.number == 42)
        #expect(entries.first?.pr?.title == "Add OAuth")
    }

    @Test("@spec GIT-5.16: While the user is in existing-branch mode, the application shall render a filter `TextField` above the branch list whose contents narrow the list to branches whose name contains the typed substring (case-insensitive).")
    func filtersByText() {
        let now = Date()
        let entries = make(
            local: [("Feat-Login", now), ("docs", now)],
            filter: "feat"
        )
        #expect(entries.map(\.name) == ["Feat-Login"])
    }

    @Test("filters out sentinel branches")
    func filtersSentinels() {
        let now = Date()
        let entries = make(local: [("(detached)", now), ("(bare)", now), ("feat", now)])
        #expect(entries.map(\.name) == ["feat"])
    }

    @Test("remote-only branch surfaces with .remoteOnly source")
    func remoteOnlyAttribution() {
        let now = Date()
        let entries = make(remote: [("feat", now)])
        #expect(entries.count == 1)
        #expect(entries.first?.source == .remoteOnly)
    }
}
