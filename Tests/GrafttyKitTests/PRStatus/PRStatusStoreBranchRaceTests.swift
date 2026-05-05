import Testing
import Foundation
@testable import GrafttyKit

/// A pausable repo fetcher: each `fetch` parks on a continuation
/// the test releases explicitly. Lets us force an in-flight fetch
/// to land AFTER the worktree's branch has changed.
private final class PausableFetcher: PRFetcher, @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [CheckedContinuation<RepoPRSnapshot, Never>] = []

    func fetch(
        origin: HostingOrigin,
        branchesOfInterest: Set<String>
    ) async throws -> RepoPRSnapshot {
        await withCheckedContinuation { cont in
            lock.lock()
            continuations.append(cont)
            lock.unlock()
        }
    }

    @discardableResult
    func release(with snapshot: RepoPRSnapshot) -> Bool {
        lock.lock()
        let cont = continuations.isEmpty ? nil : continuations.removeFirst()
        lock.unlock()
        cont?.resume(returning: snapshot)
        return cont != nil
    }

    var pending: Int {
        lock.lock(); defer { lock.unlock() }
        return continuations.count
    }
}

/// After `branchDidChange`, the in-flight fetch's result must
/// land on the worktree's NEW branch — never write back the OLD
/// branch's PR into the cache. The per-repo store re-reads
/// worktree state at apply time so a branch change between
/// dispatch and result lands on the new branch.
///
/// @spec PR-8.18
@Suite("PRStatusStore — branchDidChange race")
struct PRStatusStoreBranchRaceTests {

    private static func pr(number: Int) -> PRInfo {
        PRInfo(
            number: number,
            title: "PR\(number)",
            url: URL(string: "https://example.com/\(number)")!,
            state: .open,
            checks: .none,
            fetchedAt: Date()
        )
    }

    @MainActor
    @Test func staleFetchAppliesToCurrentBranchNotDispatchBranch() async throws {
        let fetcher = PausableFetcher()
        let origin = HostingOrigin(provider: .github, host: "github.com", owner: "foo", repo: "bar")

        let repoBox = RepoEntryBox(repo: RepoEntry(
            path: "/repo",
            displayName: "repo",
            worktrees: [WorktreeEntry(path: "/wt", branch: "branchA", state: .running)]
        ))
        let store = PRStatusStore(
            executor: FakeCLIExecutor(),
            fetcherFor: { _ in fetcher },
            detectHost: { _ in origin }
        )
        let ticker = ManualTicker()
        store.start(ticker: ticker, getRepos: { [repoBox.repo] })
        defer { store.stop() }

        store.refresh(worktreePath: "/wt", repoPath: "/repo", branch: "branchA")
        for _ in 0..<100 {
            if fetcher.pending > 0 { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(fetcher.pending > 0, "first fetch should be parked")

        // Worktree's branch flips — same shape as a HEAD-change
        // FSEvent landing while a poll is mid-flight.
        repoBox.repo.worktrees[0].branch = "branchB"
        store.branchDidChange(worktreePath: "/wt", repoPath: "/repo", branch: "branchB")

        // The in-flight fetch returns a snapshot containing both
        // branches' PRs. Apply must look up branch B (current),
        // not A (dispatch-time).
        let snapshot = RepoPRSnapshot(prsByBranch: [
            "branchA": Self.pr(number: 100),
            "branchB": Self.pr(number: 200),
        ])
        fetcher.release(with: snapshot)

        for _ in 0..<100 {
            if store.infos["/wt"]?.number != nil { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(
            store.infos["/wt"]?.number == 200,
            "fetch result must apply to current branch (B), not dispatch-time branch (A)"
        )
    }
}

@MainActor
private final class RepoEntryBox {
    var repo: RepoEntry
    init(repo: RepoEntry) { self.repo = repo }
}

