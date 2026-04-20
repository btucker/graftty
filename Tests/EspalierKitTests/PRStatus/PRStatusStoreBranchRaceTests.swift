import Testing
import Foundation
@testable import EspalierKit

/// A pausable PRFetcher: each `fetch` parks on a per-branch continuation
/// that the test releases explicitly. Lets us force the ordering where
/// a stale fetch (branchA's) lands AFTER a fresh fetch (branchB's),
/// which is the window where `branchDidChange` can be overwritten by a
/// still-in-flight previous refresh.
private final class PausablePRFetcher: PRFetcher, @unchecked Sendable {
    private let lock = NSLock()
    private var waiting: [String: CheckedContinuation<PRInfo?, Never>] = [:]

    func fetch(origin: HostingOrigin, branch: String) async throws -> PRInfo? {
        await withCheckedContinuation { cont in
            lock.lock()
            waiting[branch] = cont
            lock.unlock()
        }
    }

    func release(branch: String, with info: PRInfo?) {
        lock.lock()
        let cont = waiting.removeValue(forKey: branch)
        lock.unlock()
        cont?.resume(returning: info)
    }

    func isWaiting(on branch: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return waiting[branch] != nil
    }
}

/// Race: after `branchDidChange`, the prior branch's still-in-flight
/// fetch must not overwrite the new branch's freshly-written result.
/// Pre-fix, both Tasks snapshotted the same generation (because
/// branchDidChange bumped once via clear, then both Task1 and Task2
/// ran AFTER that bump and captured the post-bump value). Whichever
/// Task wrote last won, and if the network made the stale fetch
/// slower, the sidebar showed the OLD branch's PR for that worktree.
@Suite("PRStatusStore — branchDidChange stale-fetch race")
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
    @Test func staleFetchDoesNotOverwriteFreshAfterBranchChange() async throws {
        let fetcher = PausablePRFetcher()
        let origin = HostingOrigin(provider: .github, host: "github.com", owner: "foo", repo: "bar")
        let store = PRStatusStore(
            executor: FakeCLIExecutor(),
            fetcherFor: { _ in fetcher },
            detectHost: { _ in origin }
        )

        // Fire BOTH refreshes before yielding. With no await between
        // them, neither Task1 nor Task2 has started running yet — so
        // if refresh() did NOT snapshot generation synchronously, both
        // Tasks would snapshot the same (post-bump) value and the
        // stale one could overwrite the fresh one.
        store.refresh(worktreePath: "/wt", repoPath: "/repo", branch: "branchA")
        store.branchDidChange(worktreePath: "/wt", repoPath: "/repo", branch: "branchB")

        // Wait for at least branchB's fetch to park.
        for _ in 0..<100 {
            if fetcher.isWaiting(on: "branchB") { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(fetcher.isWaiting(on: "branchB"), "Task2 should be parked on branchB fetch")

        // Release the FRESH fetch first — Task2 writes PR#200.
        fetcher.release(branch: "branchB", with: Self.pr(number: 200))
        for _ in 0..<100 {
            if store.infos["/wt"]?.number == 200 { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(store.infos["/wt"]?.number == 200, "Task2 wrote branchB's PR")

        // Release the stale fetch too (if it parked). With the bug,
        // Task1 would overwrite PR#200 with PR#100; with the fix,
        // Task1 either bailed before reaching fetcher.fetch (pre-await
        // generation check) or bails after resume (post-await
        // generation check). Either way, PR#200 stays.
        if fetcher.isWaiting(on: "branchA") {
            fetcher.release(branch: "branchA", with: Self.pr(number: 100))
        }
        try await Task.sleep(for: .milliseconds(80))

        #expect(
            store.infos["/wt"]?.number == 200,
            "Stale branchA fetch must not overwrite branchB's fresh result"
        )
    }
}
