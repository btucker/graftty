import Testing
import GrafttyProtocol
import Foundation
@testable import GrafttyKit

@Suite("PRStatusStore — prsByRepoBranch second index", .serialized)
struct PRStatusStorePrsByRepoBranchTests {

    private static let origin = HostingOrigin(
        provider: .github, host: "github.com", owner: "foo", repo: "bar"
    )

    @MainActor
    @Test("When a repo fetch completes, the store shall populate prsByRepoBranch[repoPath] with all PRs from the snapshot, including branches with no mounted worktree.")
    func populatesPrsByRepoBranchFromSnapshot() async throws {
        let pr42 = PRInfo(
            number: 42,
            title: "Add feat",
            url: URL(string: "https://github.com/foo/bar/pull/42")!,
            state: .open,
            checks: .none,
            mergeable: .mergeable,
            fetchedAt: Date()
        )
        let fetcher = FixedFetcher(prsByBranch: ["feat": pr42])
        let store = PRStatusStore(
            executor: FakeCLIExecutor(),
            fetcherFor: { _ in fetcher },
            detectHost: { _ in Self.origin }
        )
        let repo = RepoEntry(
            path: "/r",
            displayName: "r",
            worktrees: [WorktreeEntry(path: "/r/main", branch: "main", state: .running)]
        )
        store.start(ticker: ManualTicker(), getRepos: { [repo] })
        defer { store.stop() }

        store.refresh(worktreePath: "/r/main", repoPath: "/r", branch: "main")

        // The shared background-process limiter adds an actor hop before the
        // fetch. Under the full parallel suite the cooperative executor can
        // delay that hop for several seconds, so keep this behavioral wait
        // comfortably above scheduler contention without changing production
        // cadence or timeout behavior.
        let deadline = Date().addingTimeInterval(10.0)
        while Date() < deadline {
            if store.prsByRepoBranch["/r"] != nil { break }
            try await Task.sleep(for: .milliseconds(25))
        }

        #expect(store.prsByRepoBranch["/r"]?["feat"]?.number == 42)
        #expect(store.prsByRepoBranch["/r"]?["feat"]?.state == .open)
    }
}

private actor FixedFetcher: PRFetcher {
    private let prsByBranch: [String: PRInfo]

    init(prsByBranch: [String: PRInfo]) {
        self.prsByBranch = prsByBranch
    }

    func fetch(
        origin: HostingOrigin,
        branchesOfInterest: Set<String>
    ) async throws -> RepoPRSnapshot {
        RepoPRSnapshot(prsByBranch: prsByBranch)
    }
}
