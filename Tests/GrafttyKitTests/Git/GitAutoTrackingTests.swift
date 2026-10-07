import Foundation
import Testing
@testable import GrafttyKit

@Suite("Git auto-tracking")
@MainActor
struct GitAutoTrackingTests {
    @Test("@spec GIT-6.1: When the user enables auto-tracking on a pinned agent or main checkout, the application shall persist the opt-in across relaunches and default older worktrees to disabled.")
    func preferencePersists() throws {
        var worktree = WorktreeEntry(path: "/repo", branch: "trunk")
        worktree.autoTrackEnabled = true
        #expect(try JSONDecoder().decode(WorktreeEntry.self, from: JSONEncoder().encode(worktree)).autoTrackEnabled)
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(worktree)) as? [String: Any])
        json.removeValue(forKey: "autoTrackEnabled")
        #expect(try !JSONDecoder().decode(WorktreeEntry.self, from: JSONSerialization.data(withJSONObject: json)).autoTrackEnabled)
    }

    @Test("@spec GIT-6.2: When the origin default branch changes and the main checkout has auto-tracking enabled, the application shall attempt a git pull in that checkout before merging the resulting local default branch into opted-in pinned agents.")
    func pullThenMerge() async {
        let fixture = Fixture()
        fixture.repo.worktrees[0].autoTrackEnabled = true
        fixture.afterPull = .init(branch: "trunk", localCommit: "pulled", remoteCommit: "remote")
        let tracker = fixture.tracker()
        await fixture.refresh(tracker)
        #expect(fixture.operations == [.pull(path: "/repo", branch: "trunk"), .merge(path: "/repo/role", branch: "trunk")])
        #expect(fixture.refreshed == ["/repo", "/repo/role"])
        await fixture.refresh(tracker)
        #expect(fixture.operations.count == 2)
    }

    @Test("@spec GIT-6.3: When the local default branch changes, the application shall attempt git merge in every opted-in pinned agent, including closed worktrees, without requiring main-checkout tracking or a remote change.")
    func localChangesMergeWithoutPull() async {
        let fixture = Fixture()
        fixture.snapshot = .init(branch: "trunk", localCommit: "local", remoteCommit: nil)
        var disabled = WorktreeEntry(path: "/repo/disabled", branch: "disabled")
        disabled.isPinned = true
        var temporary = WorktreeEntry(path: "/repo/task", branch: "task")
        temporary.autoTrackEnabled = true
        var stale = WorktreeEntry(path: "/repo/stale", branch: "stale", state: .stale)
        stale.isPinned = true
        stale.autoTrackEnabled = true
        fixture.repo.worktrees += [disabled, temporary, stale]
        let tracker = fixture.tracker()
        await fixture.refresh(tracker)
        #expect(fixture.operations == [.merge(path: "/repo/role", branch: "trunk")])
        fixture.snapshot = .init(branch: "trunk", localCommit: "next", remoteCommit: nil)
        await fixture.refresh(tracker)
        #expect(fixture.operations.count == 2)
    }

    @Test("@spec GIT-6.4: If an automatic pull or merge fails, then the application shall leave Git's resulting state for the user, refresh divergence stats, and retry only when its upstream commit changes or tracking is re-enabled.")
    func failureWaitsForChangedTarget() async {
        let fixture = Fixture()
        fixture.repo.worktrees[0].autoTrackEnabled = true
        fixture.fails = true
        let tracker = fixture.tracker()
        await fixture.refresh(tracker)
        await fixture.refresh(tracker)
        #expect(fixture.operations.count == 2)
        #expect(fixture.refreshed == ["/repo", "/repo/role"])
        fixture.repo.worktrees[1].branch = "other-role-branch"
        await fixture.refresh(tracker)
        #expect(fixture.operations.count == 2)
        fixture.snapshot = .init(branch: "trunk", localCommit: "local", remoteCommit: "new-remote")
        await fixture.refresh(tracker)
        #expect(fixture.operations.count == 3)
        fixture.snapshot = .init(branch: "trunk", localCommit: "new-local", remoteCommit: "new-remote")
        await fixture.refresh(tracker)
        #expect(fixture.operations.count == 4)
        tracker.reset(worktreePath: "/repo/role")
        fixture.repo.worktrees[1].autoTrackLastAttempt = nil
        await fixture.refresh(tracker)
        #expect(fixture.operations.count == 5)
    }

    @Test func failureDoesNotRetryAfterRelaunch() async throws {
        let fixture = Fixture()
        fixture.fails = true
        await fixture.refresh(fixture.tracker())
        fixture.repo = try JSONDecoder().decode(RepoEntry.self, from: JSONEncoder().encode(fixture.repo))
        await fixture.refresh(fixture.tracker())
        #expect(fixture.operations.count == 1)
        fixture.snapshot = .init(branch: "trunk", localCommit: "next", remoteCommit: "remote")
        await fixture.refresh(fixture.tracker())
        #expect(fixture.operations.count == 2)
    }

    @Test func skippedCheckoutDoesNotConsumeUpstreamTarget() async {
        let fixture = Fixture()
        var eligible = false
        var calls = 0
        let tracker = GitAutoTracking(readSnapshot: { _ in fixture.snapshot }, perform: { _ in
            calls += 1
            return eligible
        })
        await fixture.refresh(tracker)
        #expect(fixture.repo.worktrees[1].autoTrackLastAttempt == nil)
        eligible = true
        await fixture.refresh(tracker)
        #expect(calls == 2)
        #expect(fixture.repo.worktrees[1].autoTrackLastAttempt?.commit == "local")
        await fixture.refresh(tracker)
        #expect(calls == 2)
    }

    @Test func reenableDuringOperationKeepsNewOptInRetryable() async {
        let fixture = Fixture()
        var release: CheckedContinuation<Void, Never>?
        var calls = 0
        let tracker = GitAutoTracking(readSnapshot: { _ in fixture.snapshot }, perform: { _ in
            calls += 1
            if calls == 1 { await withCheckedContinuation { release = $0 } }
            return true
        })
        let first = Task { await fixture.refresh(tracker) }
        while release == nil { await Task.yield() }
        fixture.repo.worktrees[1].autoTrackEnabled = false
        fixture.repo.worktrees[1].autoTrackLastAttempt = nil
        tracker.reset(worktreePath: "/repo/role")
        fixture.repo.worktrees[1].autoTrackEnabled = true
        await fixture.refresh(tracker)
        release?.resume()
        await first.value
        #expect(calls == 2)
        #expect(fixture.repo.worktrees[1].autoTrackLastAttempt?.commit == "local")
    }

    @Test("@spec DIVERGE-3.2: When computing insertion and deletion line counts, the application shall run `git diff --shortstat <ref>...HEAD` where `<ref>` is `origin/<worktree-branch>` when that tracking ref exists, otherwise the local default branch for pinned agents with auto-tracking enabled or `origin/<defaultBranch>` for other worktrees. The diff shall use a single ref rather than the full union.")
    func lineCountsUseOwnRemoteOrSelectedDefault() async throws {
        for (local, hasOwnRemote, branch) in [(true, false, "role"), (true, true, "role"), (false, false, "role"), (false, true, "role"), (true, true, "main")] {
            let executor = FakeCLIExecutor()
            executor.stub(command: "git", args: ["symbolic-ref", "--short", "refs/remotes/origin/HEAD"],
                          output: .init(stdout: "origin/main\n", stderr: "", exitCode: 0))
            executor.stub(command: "git", args: ["show-ref", "--verify", "--quiet", "refs/remotes/origin/\(branch)"],
                          output: .init(stdout: "", stderr: "", exitCode: hasOwnRemote ? 0 : 1))
            let defaultRef = local ? "refs/heads/main" : "origin/main"
            let refs = [defaultRef] + (hasOwnRemote ? ["origin/\(branch)"] : [])
            for args in [["rev-list", "--count"] + refs + ["^HEAD"], ["rev-list", "--count", "HEAD"] + refs.map { "^\($0)" }] {
                executor.stub(command: "git", args: args, output: .init(stdout: "1\n", stderr: "", exitCode: 0))
            }
            let diffRef = hasOwnRemote ? "origin/\(branch)" : defaultRef
            executor.stub(command: "git", args: ["diff", "--shortstat", "\(diffRef)...HEAD"],
                          output: .init(stdout: "1 file changed, 7 insertions(+), 3 deletions(-)\n", stderr: "", exitCode: 0))
            executor.stub(command: "git", args: ["status", "--porcelain"], output: .init(stdout: "", stderr: "", exitCode: 0))
            let compute = WorktreeStatsStore.makeDefaultCompute(executor: executor, useLocalDefault: local,
                                                               fallbackDefaultBranch: "feature-at-add-time")
            let result = await compute("/repo/role", "/repo", branch, nil)
            #expect(result.defaultBranch == "main")
            #expect(result.stats?.insertions == 7)
            #expect(result.stats?.deletions == 3)
            #expect(result.stats?.upstreamRefs?.branchRef == (hasOwnRemote ? "origin/\(branch)" : nil))
            #expect(executor.invocations.filter { $0.args.first == "diff" }.map(\.args) == [["diff", "--shortstat", "\(diffRef)...HEAD"]])
        }
    }

    @Test func fallbackHintIsNotCachedAsAuthoritativeDefault() async {
        let executor = FakeCLIExecutor()
        executor.stub(command: "git", args: ["symbolic-ref", "--short", "refs/remotes/origin/HEAD"],
                      output: .init(stdout: "", stderr: "", exitCode: 1))
        for candidate in ["main", "master", "develop", "role"] {
            executor.stub(command: "git", args: ["show-ref", "--verify", "--quiet", "refs/remotes/origin/\(candidate)"],
                          output: .init(stdout: "", stderr: "", exitCode: 1))
        }
        for name in ["feature", "main"] {
            let ref = "refs/heads/\(name)"
            for args in [["rev-list", "--count", ref, "^HEAD"], ["rev-list", "--count", "HEAD", "^\(ref)"]] {
                executor.stub(command: "git", args: args, output: .init(stdout: "1\n", stderr: "", exitCode: 0))
            }
            executor.stub(command: "git", args: ["diff", "--shortstat", "\(ref)...HEAD"],
                          output: .init(stdout: "", stderr: "", exitCode: 0))
        }
        executor.stub(command: "git", args: ["status", "--porcelain"], output: .init(stdout: "", stderr: "", exitCode: 0))
        let compute = WorktreeStatsStore.makeDefaultCompute(executor: executor, useLocalDefault: true,
                                                           fallbackDefaultBranch: "feature")
        let beforeOrigin = await compute("/repo/role", "/repo", "role", nil)
        #expect(beforeOrigin.stats?.upstreamRefs?.defaultRef == "refs/heads/feature")
        #expect(beforeOrigin.defaultBranch == nil)
        executor.stub(command: "git", args: ["symbolic-ref", "--short", "refs/remotes/origin/HEAD"],
                      output: .init(stdout: "origin/main\n", stderr: "", exitCode: 0))
        let afterOrigin = await compute("/repo/role", "/repo", "role", beforeOrigin.defaultBranch)
        #expect(afterOrigin.defaultBranch == "main")
        #expect(afterOrigin.stats?.upstreamRefs?.defaultRef == "refs/heads/main")
    }

    @Test("@spec GIT-6.5: While an automatic tracking operation is in flight, the application shall serialize tracking within that repository, coalesce new signals, and recheck current opt-in and worktree eligibility before subsequent operations.")
    func coalescesAndUsesCurrentPreferences() async {
        let fixture = Fixture()
        fixture.repo.worktrees[0].autoTrackEnabled = true
        var release: CheckedContinuation<Void, Never>?
        let tracker = fixture.tracker { operation in
            if case .pull = operation {
                await withCheckedContinuation { release = $0 }
            }
        }
        let first = Task { await fixture.refresh(tracker) }
        while release == nil { await Task.yield() }
        fixture.repo.worktrees[1].autoTrackEnabled = false
        await fixture.refresh(tracker)
        release?.resume()
        await first.value
        #expect(fixture.operations == [.pull(path: "/repo", branch: "trunk")])
    }

    @Test func optedOutRepositoriesDoNoGitWork() async {
        let fixture = Fixture()
        fixture.repo.isGitTracked = false
        let tracker = fixture.tracker()
        await fixture.refresh(tracker)
        #expect(fixture.reads == 0)
        fixture.repo.isGitTracked = true
        fixture.repo.worktrees[1].autoTrackEnabled = false
        await fixture.refresh(tracker)
        #expect(fixture.reads == 0)
    }

    @Test func pullUsesOriginDefaultAndRefusesOtherCheckoutBranches() async throws {
        let executor = FakeCLIExecutor()
        executor.stub(command: "git", args: ["branch", "--show-current"],
                      output: .init(stdout: "trunk\n", stderr: "", exitCode: 0))
        executor.stub(command: "git", args: ["pull", "--no-edit", "origin", "trunk"],
                      output: .init(stdout: "", stderr: "", exitCode: 0))
        try await GitAutoTracking.perform(.pull(path: "/repo", branch: "trunk"), using: executor)
        #expect(executor.invocations.map(\.args) == [["branch", "--show-current"], ["pull", "--no-edit", "origin", "trunk"]])

        let switched = FakeCLIExecutor()
        switched.stub(command: "git", args: ["branch", "--show-current"],
                      output: .init(stdout: "feature\n", stderr: "", exitCode: 0))
        try await GitAutoTracking.perform(.pull(path: "/repo", branch: "trunk"), using: switched)
        #expect(switched.invocations.count == 1)
    }

    @Test func mergeUsesLocalBranchAndLeavesDetachedHeadAlone() async throws {
        let executor = FakeCLIExecutor()
        executor.stub(command: "git", args: ["branch", "--show-current"],
                      output: .init(stdout: "role\n", stderr: "", exitCode: 0))
        executor.stub(command: "git", args: ["merge", "--no-edit", "--", "refs/heads/trunk"],
                      output: .init(stdout: "", stderr: "conflict", exitCode: 1))
        await #expect(throws: CLIError.self) {
            try await GitAutoTracking.perform(.merge(path: "/repo/role", branch: "trunk"), using: executor)
        }
        #expect(executor.invocations.allSatisfy { $0.directory == "/repo/role" })
        let detached = FakeCLIExecutor()
        detached.stub(command: "git", args: ["branch", "--show-current"],
                      output: .init(stdout: "\n", stderr: "", exitCode: 0))
        try await GitAutoTracking.perform(.merge(path: "/repo/role", branch: "trunk"), using: detached)
        #expect(detached.invocations.count == 1)
    }

    @Test func realPullAdvancesMainAfterFetch() async throws {
        let (root, clone, _) = try makeClonedRepo()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(try shellInRepo("printf 'remote\\n' > remote.txt && git add remote.txt && git commit -m remote && git push", at: root.appendingPathComponent("seed")) == 0)
        let executor = CLIRunner()
        _ = try await GitRunner.run(args: ["fetch", "origin"], at: clone.path, using: executor)
        let before = try #require(await GitAutoTracking.readSnapshot(.init(path: clone.path, displayName: "Repo"), using: executor))
        #expect(before.localCommit != before.remoteCommit)
        var home = WorktreeEntry(path: clone.path, branch: "main")
        home.autoTrackEnabled = true
        let repo = RepoEntry(path: clone.path, displayName: "Repo", worktrees: [home])
        let tracker = GitAutoTracking(readSnapshot: { await GitAutoTracking.readSnapshot($0, using: executor) },
                                      perform: { try await GitAutoTracking.perform($0, using: executor) })
        await tracker.refresh(repoPath: repo.path, getRepo: { repo }, onAttempt: { _ in })
        let after = try #require(await GitAutoTracking.readSnapshot(repo, using: executor))
        #expect(after.localCommit == before.remoteCommit)
    }

    @Test("@spec GIT-6.7: While a pinned agent has auto-tracking enabled, the application shall measure its divergence against the local default branch plus its own remote branch when present, so failed merges remain visible before local default commits are pushed.")
    func realConflictRemainsBehindLocalDefault() async throws {
        let (root, clone, _) = try makeClonedRepo()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(try shellInRepo("git switch -c role && printf 'role\\n' > file.txt && git commit -am role && git switch main && printf 'main\\n' > file.txt && git commit -am main && git switch role", at: clone) == 0)
        let executor = CLIRunner()
        let compute = WorktreeStatsStore.makeDefaultCompute(executor: executor, useLocalDefault: true)
        let before = await compute(clone.path, clone.path, "role", "main")
        #expect(before.stats?.behind == 1)
        #expect(before.stats?.upstreamRefs?.defaultRef == "refs/heads/main")
        await #expect(throws: CLIError.self) {
            try await GitAutoTracking.perform(.merge(path: clone.path, branch: "main"), using: executor)
        }
        #expect(FileManager.default.fileExists(atPath: clone.appendingPathComponent(".git/MERGE_HEAD").path))
        let after = await compute(clone.path, clone.path, "role", "main")
        #expect(after.stats?.behind == 1)
        #expect(after.stats?.hasUncommittedChanges == true)
        // The regular origin comparison cannot see the unpushed main commit.
        let origin = await WorktreeStatsStore.makeDefaultCompute(executor: executor)(clone.path, clone.path, "role", "main")
        #expect(origin.stats?.behind == 0)
    }

    @MainActor
    private final class Fixture {
        var repo: RepoEntry
        var snapshot = GitAutoTracking.Snapshot(branch: "trunk", localCommit: "local", remoteCommit: "remote")
        var afterPull: GitAutoTracking.Snapshot?
        var operations: [GitAutoTracking.Operation] = []
        var refreshed: [String] = []
        var reads = 0
        var fails = false

        init() {
            let main = WorktreeEntry(path: "/repo", branch: "trunk")
            var role = WorktreeEntry(path: "/repo/role", branch: "role")
            role.isPinned = true
            role.autoTrackEnabled = true
            repo = RepoEntry(path: "/repo", displayName: "Repo", worktrees: [main, role], defaultBranchHint: "trunk")
        }

        func tracker(beforeOperation: @escaping @MainActor (GitAutoTracking.Operation) async -> Void = { _ in }) -> GitAutoTracking {
            GitAutoTracking(readSnapshot: { _ in
                self.reads += 1
                return self.snapshot
            }, perform: { operation in
                self.operations.append(operation)
                await beforeOperation(operation)
                if self.fails { throw CLIError.nonZeroExit(command: "git", exitCode: 1, stderr: "conflict") }
                if case .pull = operation, let afterPull = self.afterPull { self.snapshot = afterPull }
                return true
            })
        }

        func refresh(_ tracker: GitAutoTracking) async {
            await tracker.refresh(repoPath: repo.path, getRepo: { self.repo }, recordAttempt: { path, target in
                if let index = self.repo.worktrees.firstIndex(where: { $0.path == path }) {
                    self.repo.worktrees[index].autoTrackLastAttempt = target
                }
            }, onAttempt: { self.refreshed.append($0) })
        }
    }
}
