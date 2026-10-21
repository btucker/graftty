import Testing
import Foundation
@testable import GrafttyKit

@Suite("GitWorktreeStats — parsers")
struct GitWorktreeStatsParserTests {

    // MARK: parseSingleCount
    // `git rev-list --count <refs>` prints a single non-negative integer.
    // A two-ref union needs separate ahead / behind invocations; a single
    // ref uses `--left-right --count` (see `parseLeftRightCount`).

    @Test func parsesSingleCountNonZero() throws {
        #expect(GitWorktreeStats.parseSingleCount("42\n") == 42)
    }

    @Test func parsesSingleCountZero() throws {
        #expect(GitWorktreeStats.parseSingleCount("0\n") == 0)
    }

    @Test func parsesSingleCountWithSurroundingWhitespace() throws {
        #expect(GitWorktreeStats.parseSingleCount("   7   \n") == 7)
    }

    @Test func rejectsMalformedSingleCount() throws {
        #expect(GitWorktreeStats.parseSingleCount("") == nil)
        #expect(GitWorktreeStats.parseSingleCount("not a number\n") == nil)
        #expect(GitWorktreeStats.parseSingleCount("1\t2\n") == nil)
    }

    // MARK: parseShortStat
    // git diff --shortstat output looks like:
    //   " 3 files changed, 42 insertions(+), 7 deletions(-)"
    // Insertions or deletions may be absent if zero. Empty output
    // (no diff) returns (0, 0) rather than failing.

    @Test func parsesShortStatBoth() throws {
        let output = " 3 files changed, 42 insertions(+), 7 deletions(-)\n"
        let result = GitWorktreeStats.parseShortStat(output)
        #expect(result.insertions == 42)
        #expect(result.deletions == 7)
    }

    @Test func parsesShortStatSingularInsertion() throws {
        let output = " 1 file changed, 1 insertion(+)\n"
        let result = GitWorktreeStats.parseShortStat(output)
        #expect(result.insertions == 1)
        #expect(result.deletions == 0)
    }

    @Test func parsesShortStatOnlyDeletions() throws {
        let output = " 2 files changed, 15 deletions(-)\n"
        let result = GitWorktreeStats.parseShortStat(output)
        #expect(result.insertions == 0)
        #expect(result.deletions == 15)
    }

    @Test func parsesShortStatEmpty() throws {
        let result = GitWorktreeStats.parseShortStat("")
        #expect(result.insertions == 0)
        #expect(result.deletions == 0)
    }

    @Test func parsesShortStatBlankLineOnly() throws {
        let result = GitWorktreeStats.parseShortStat("\n")
        #expect(result.insertions == 0)
        #expect(result.deletions == 0)
    }

    // MARK: WorktreeStats.isEmpty

    @Test func isEmptyWhenAllZero() throws {
        let s = WorktreeStats(ahead: 0, behind: 0, insertions: 0, deletions: 0)
        #expect(s.isEmpty)
    }

    @Test func isNotEmptyWhenAnyNonZero() throws {
        #expect(!WorktreeStats(ahead: 1, behind: 0, insertions: 0, deletions: 0).isEmpty)
        #expect(!WorktreeStats(ahead: 0, behind: 1, insertions: 0, deletions: 0).isEmpty)
        #expect(!WorktreeStats(ahead: 0, behind: 0, insertions: 1, deletions: 0).isEmpty)
        #expect(!WorktreeStats(ahead: 0, behind: 0, insertions: 0, deletions: 1).isEmpty)
    }
}

@Suite("GitWorktreeStats — compute (integration)", .serialized)
struct GitWorktreeStatsComputeTests {

    @Test func returnsZerosAtParity() async throws {
        let (root, clone, _) = try makeClonedRepo()
        defer { try? FileManager.default.removeItem(at: root) }

        let stats = try await GitWorktreeStats.compute(
            worktreePath: clone.path,
            upstreamRefs: UpstreamRefs(defaultRef: "origin/main")
        )
        #expect(stats.ahead == 0)
        #expect(stats.behind == 0)
        #expect(stats.insertions == 0)
        #expect(stats.deletions == 0)
        #expect(stats.upstreamRefs == UpstreamRefs(defaultRef: "origin/main"))
    }

    @Test func countsAheadAndLineChanges() async throws {
        let (root, clone, _) = try makeClonedRepo()
        defer { try? FileManager.default.removeItem(at: root) }

        // Add two commits on HEAD with alpha tweaked + new lines added.
        try shellInRepo("""
            printf 'alpha\\nbeta\\ngamma\\ndelta\\n' > file.txt && \
            git add file.txt && git commit -m 'add delta' && \
            printf 'ALPHA\\nbeta\\ngamma\\ndelta\\nepsilon\\nzeta\\n' > file.txt && \
            git add file.txt && git commit -m 'add epsilon/zeta, tweak alpha'
            """, at: clone)

        let stats = try await GitWorktreeStats.compute(
            worktreePath: clone.path,
            upstreamRefs: UpstreamRefs(defaultRef: "origin/main")
        )
        #expect(stats.ahead == 2)
        #expect(stats.behind == 0)
        // alpha: changed (1+/1-); delta: new (1+); epsilon + zeta: new (2+).
        // Totals vs. the merge-base (= origin/main): +4 / -1.
        #expect(stats.insertions == 4)
        #expect(stats.deletions == 1)
    }

    @Test func countsBehindWhenOriginAdvances() async throws {
        let (root, clone, _) = try makeClonedRepo()
        defer { try? FileManager.default.removeItem(at: root) }

        // Push one new commit to origin from a second clone, then fetch.
        let other = root.appendingPathComponent("other-clone")
        try shellInRepo("git clone \(root.appendingPathComponent("upstream.git").path) \(other.path)", at: root)
        try shellInRepo("""
            printf 'alpha\\nbeta\\ngamma\\nomega\\n' > file.txt && \
            git add file.txt && git commit -m 'omega' && \
            git push origin main
            """, at: other)
        try shellInRepo("git fetch origin", at: clone)

        let stats = try await GitWorktreeStats.compute(
            worktreePath: clone.path,
            upstreamRefs: UpstreamRefs(defaultRef: "origin/main")
        )
        #expect(stats.ahead == 0)
        #expect(stats.behind == 1)
    }

    @Test func throwsWhenWorktreeMissing() async throws {
        let bogus = "/nonexistent-graftty-path-\(UUID().uuidString)"
        await #expect(throws: Error.self) {
            try await GitWorktreeStats.compute(
                worktreePath: bogus,
                upstreamRefs: UpstreamRefs(defaultRef: "origin/main")
            )
        }
    }

    @Test func cleanWorktreeReportsNoUncommittedChanges() async throws {
        let (root, clone, _) = try makeClonedRepo()
        defer { try? FileManager.default.removeItem(at: root) }

        let stats = try await GitWorktreeStats.compute(
            worktreePath: clone.path,
            upstreamRefs: UpstreamRefs(defaultRef: "origin/main")
        )
        #expect(stats.hasUncommittedChanges == false)
    }

    @Test func modifiedTrackedFileMarksDirty() async throws {
        let (root, clone, _) = try makeClonedRepo()
        defer { try? FileManager.default.removeItem(at: root) }

        // Modify file.txt without committing.
        try shellInRepo(
            "printf 'alpha\\nbeta\\ngamma\\ndelta\\n' > file.txt",
            at: clone
        )

        let stats = try await GitWorktreeStats.compute(
            worktreePath: clone.path,
            upstreamRefs: UpstreamRefs(defaultRef: "origin/main")
        )
        #expect(stats.ahead == 0)
        #expect(stats.behind == 0)
        #expect(stats.hasUncommittedChanges == true)
    }

    @Test func untrackedFileMarksDirty() async throws {
        let (root, clone, _) = try makeClonedRepo()
        defer { try? FileManager.default.removeItem(at: root) }

        // Untracked files also count as uncommitted work per spec intent.
        try shellInRepo("printf 'scratch' > newfile.txt", at: clone)

        let stats = try await GitWorktreeStats.compute(
            worktreePath: clone.path,
            upstreamRefs: UpstreamRefs(defaultRef: "origin/main")
        )
        #expect(stats.hasUncommittedChanges == true)
    }
}

/// Regression target for the "↓N doesn't reflect origin commits on each
/// worktree" bug. Before the fix, DIVERGE-3.0 compared a linked worktree's
/// HEAD to the *local* default branch, so commits landing on
/// `origin/<defaultBranch>` (PR merges) or `origin/<worktree-branch>`
/// (collaborator pushes) were both invisible to the gutter even after a
/// successful `git fetch`.
///
/// The fix measures `↓N` against the **union** of upstream refs:
/// `origin/<defaultBranch>` is always included so a PR merge surfaces on
/// every worktree; `origin/<branch>` is additionally included when that
/// tracking ref exists so collaborator pushes also surface.
@Suite("GitWorktreeStats.resolveUpstreamRefs — union-of-upstreams", .serialized)
struct GitWorktreeStatsResolveUpstreamRefsTests {

    @Test func homeWorktreeOnDefaultResolvesToSingleRef() async throws {
        let (root, clone, _) = try makeClonedRepo()
        defer { try? FileManager.default.removeItem(at: root) }

        let refs = await GitWorktreeStats.resolveUpstreamRefs(
            worktreePath: clone.path,
            branch: "main",
            defaultBranch: "main"
        )
        #expect(refs == UpstreamRefs(defaultRef: "origin/main"),
                "branch == default → no separate branch ref, avoids \"origin/main + origin/main\"")
    }

    @Test func linkedWorktreeWithTrackedUpstreamIncludesBothRefs() async throws {
        let (root, clone, _) = try makeClonedRepo()
        defer { try? FileManager.default.removeItem(at: root) }

        try shellInRepo("""
            git checkout -b feature && \
            printf 'alpha\\nbeta\\ngamma\\ndelta\\n' > file.txt && \
            git add file.txt && git commit -m 'feature work' && \
            git push -u origin feature && \
            git checkout main
            """, at: clone)

        let wtPath = root.appendingPathComponent("feature-wt").path
        try shellInRepo("git worktree add \(wtPath) feature", at: clone)

        let refs = await GitWorktreeStats.resolveUpstreamRefs(
            worktreePath: wtPath,
            branch: "feature",
            defaultBranch: "main"
        )
        #expect(refs.defaultRef == "origin/main")
        #expect(refs.branchRef == "origin/feature")
        #expect(refs.all == ["origin/main", "origin/feature"])
        #expect(refs.displayLabel == "origin/main + origin/feature")
    }

    @Test func linkedWorktreeWithoutUpstreamKeepsOnlyDefaultRef() async throws {
        // Never-pushed branch: ↓N still tracks origin/<default>, so a
        // PR merge on main surfaces on this scratch worktree too — matches
        // the user's "every worktree that doesn't have the merged commits"
        // mental model.
        let (root, clone, _) = try makeClonedRepo()
        defer { try? FileManager.default.removeItem(at: root) }

        try shellInRepo("git checkout -b scratch", at: clone)
        let wtPath = root.appendingPathComponent("scratch-wt").path
        try shellInRepo("git worktree add \(wtPath) scratch", at: clone)

        let refs = await GitWorktreeStats.resolveUpstreamRefs(
            worktreePath: wtPath,
            branch: "scratch",
            defaultBranch: "main"
        )
        #expect(refs == UpstreamRefs(defaultRef: "origin/main"))
        #expect(refs.displayLabel == "origin/main",
                "never-pushed branch → just the default ref; union collapses to one")
    }

    @Test func resolverUsesRepoConfiguredDefaultNotHardcodedMain() async throws {
        // Repo's default branch is `trunk`, not `main`. resolveUpstreamRefs
        // must honor whatever name the caller passes in via `defaultBranch:`
        // — there must be no literal `"main"` fallback at the compute level.
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let upstream = root.appendingPathComponent("upstream.git")
        let clone = root.appendingPathComponent("clone")
        try FileManager.default.createDirectory(at: upstream, withIntermediateDirectories: true)
        try shellInRepo("git init --bare -b trunk", at: upstream)
        let seed = root.appendingPathComponent("seed")
        try FileManager.default.createDirectory(at: seed, withIntermediateDirectories: true)
        try shellInRepo("""
            git init -b trunk && \
            printf 'alpha\\n' > file.txt && \
            git add file.txt && git commit -m init && \
            git remote add origin \(upstream.path) && \
            git push -u origin trunk
            """, at: seed)
        try shellInRepo("git clone \(upstream.path) \(clone.path)", at: root)

        let refs = await GitWorktreeStats.resolveUpstreamRefs(
            worktreePath: clone.path,
            branch: "trunk",
            defaultBranch: "trunk"
        )
        #expect(refs.defaultRef == "origin/trunk",
                "compute must use the repo's actual default, not a hardcoded main")
    }

    /// The scenario from the user's clarifying question: "if another PR
    /// merges, then within 30s it should show up as ↓N on each worktree
    /// that doesn't have those commits". The feature branch's own
    /// upstream didn't move, but origin/main did — the union semantics
    /// mean the merge shows up anyway.
    @Test func prMergeOnDefaultSurfacesOnFeatureBranchWorktree() async throws {
        let (root, clone, upstream) = try makeClonedRepo()
        defer { try? FileManager.default.removeItem(at: root) }

        // Push feature branch, leave the branch pointing at the initial
        // commit — same starting state as someone who branched earlier
        // and is now reviewing their work.
        try shellInRepo("""
            git checkout -b feature && \
            git push -u origin feature && \
            git checkout main
            """, at: clone)

        // Teammate's clone merges a PR by advancing origin/main.
        let other = root.appendingPathComponent("other-clone")
        try shellInRepo("git clone \(upstream.path) \(other.path)", at: root)
        try shellInRepo("""
            printf 'alpha\\nbeta\\ngamma\\ndelta\\n' > file.txt && \
            git add file.txt && git commit -m 'merged PR' && \
            git push origin main
            """, at: other)

        // Our side: fetch all branches.
        try shellInRepo("git fetch --no-tags --prune origin", at: clone)

        let wtPath = root.appendingPathComponent("feature-wt").path
        try shellInRepo("git worktree add \(wtPath) feature", at: clone)

        let refs = await GitWorktreeStats.resolveUpstreamRefs(
            worktreePath: wtPath,
            branch: "feature",
            defaultBranch: "main"
        )
        let stats = try await GitWorktreeStats.compute(
            worktreePath: wtPath,
            upstreamRefs: refs
        )
        #expect(stats.behind == 1,
                "PR merge on origin/main must surface as ↓1 on the feature worktree, even though origin/feature didn't move")
        #expect(stats.ahead == 0)
    }

    /// The other half of the union: a collaborator push to the feature
    /// branch's own upstream still surfaces as ↓N, even when main is
    /// unchanged. `origin/feature` moved; `origin/main` didn't.
    @Test func collaboratorPushToFeatureUpstreamStillSurfaces() async throws {
        let (root, clone, upstream) = try makeClonedRepo()
        defer { try? FileManager.default.removeItem(at: root) }

        try shellInRepo("""
            git checkout -b feature && \
            printf 'alpha\\nbeta\\ngamma\\ndelta\\n' > file.txt && \
            git add file.txt && git commit -m 'feature work' && \
            git push -u origin feature && \
            git checkout main
            """, at: clone)

        // Teammate pushes one more commit onto origin/feature only.
        let other = root.appendingPathComponent("other-clone")
        try shellInRepo("git clone \(upstream.path) \(other.path)", at: root)
        try shellInRepo("""
            git checkout feature && \
            printf 'alpha\\nbeta\\ngamma\\ndelta\\nepsilon\\n' > file.txt && \
            git add file.txt && git commit -m 'add epsilon' && \
            git push origin feature
            """, at: other)

        try shellInRepo("git fetch --no-tags --prune origin", at: clone)

        let wtPath = root.appendingPathComponent("feature-wt").path
        try shellInRepo("git worktree add \(wtPath) feature", at: clone)

        let refs = await GitWorktreeStats.resolveUpstreamRefs(
            worktreePath: wtPath,
            branch: "feature",
            defaultBranch: "main"
        )
        let stats = try await GitWorktreeStats.compute(
            worktreePath: wtPath,
            upstreamRefs: refs
        )
        #expect(stats.behind == 1)
        #expect(stats.ahead == 0)
    }

    /// Both signals fire at once: origin/main advances AND someone pushes
    /// a commit to origin/feature. The union counts distinct commits
    /// once — the user sees a single ↓2, not a double-counted ↓3 or
    /// separate columns that have to be mentally summed.
    @Test func bothSignalsFireAtOnceDedupedByUnion() async throws {
        let (root, clone, upstream) = try makeClonedRepo()
        defer { try? FileManager.default.removeItem(at: root) }

        try shellInRepo("""
            git checkout -b feature && \
            git push -u origin feature && \
            git checkout main
            """, at: clone)

        let other = root.appendingPathComponent("other-clone")
        try shellInRepo("git clone \(upstream.path) \(other.path)", at: root)
        // One commit to origin/main (PR merge).
        try shellInRepo("""
            printf 'beta\\n' > other.txt && \
            git add other.txt && git commit -m 'on main' && \
            git push origin main
            """, at: other)
        // One distinct commit to origin/feature (collaborator push) —
        // branched from the ORIGINAL main, so it doesn't contain main's
        // new commit.
        try shellInRepo("""
            git checkout feature && \
            printf 'gamma\\n' > feat.txt && \
            git add feat.txt && git commit -m 'on feature' && \
            git push origin feature
            """, at: other)

        try shellInRepo("git fetch --no-tags --prune origin", at: clone)

        let wtPath = root.appendingPathComponent("feature-wt").path
        try shellInRepo("git worktree add \(wtPath) feature", at: clone)

        let refs = await GitWorktreeStats.resolveUpstreamRefs(
            worktreePath: wtPath,
            branch: "feature",
            defaultBranch: "main"
        )
        let stats = try await GitWorktreeStats.compute(
            worktreePath: wtPath,
            upstreamRefs: refs
        )
        #expect(stats.behind == 2,
                "two distinct commits — one on origin/main, one on origin/feature — should count as ↓2 via union, not double-counted as ↓3")
        #expect(stats.ahead == 0)
    }
}

@Suite("""
@spec DIVERGE-3.1: The application shall compute the ahead and behind counts against the upstream refs from `DIVERGE-3.0`. When there is a single ref, the application shall run one `git rev-list --left-right --count HEAD...<ref>` and read the left count as ahead and the right count as behind. When there are two refs, the application shall run `git rev-list --count <refs> ^HEAD` for behind and `git rev-list --count HEAD ^<refs>` for ahead; `rev-list` natively dedupes, so a commit reachable from both upstream refs is counted once.
""")
struct GitWorktreeStatsRevListTests {
    private static func stubDiffAndStatus(_ executor: FakeCLIExecutor, diffBase: String) {
        executor.stub(command: "git", args: ["diff", "--shortstat", "\(diffBase)...HEAD"],
                      output: .init(stdout: "", stderr: "", exitCode: 0))
        executor.stub(command: "git", args: ["status", "--porcelain"],
                      output: .init(stdout: "", stderr: "", exitCode: 0))
    }

    @Test func singleRefCountsAheadAndBehindInOneChild() async throws {
        let executor = FakeCLIExecutor()
        executor.stub(command: "git", args: ["rev-list", "--left-right", "--count", "HEAD...origin/main"],
                      output: .init(stdout: "2\t3\n", stderr: "", exitCode: 0))
        Self.stubDiffAndStatus(executor, diffBase: "origin/main")

        let stats = try await GitWorktreeStats.compute(
            worktreePath: "/wt",
            upstreamRefs: UpstreamRefs(defaultRef: "origin/main"),
            deadline: nil,
            using: executor
        )

        #expect(stats.ahead == 2)
        #expect(stats.behind == 3)
        #expect(executor.invocations.filter { $0.args.first == "rev-list" }.count == 1)
        #expect(executor.invocations.count == 3)
    }

    @Test func unionOfTwoRefsKeepsSeparateAheadAndBehindChildren() async throws {
        let executor = FakeCLIExecutor()
        executor.stub(command: "git", args: ["rev-list", "--count", "origin/main", "origin/feature", "^HEAD"],
                      output: .init(stdout: "3\n", stderr: "", exitCode: 0))
        executor.stub(command: "git", args: ["rev-list", "--count", "HEAD", "^origin/main", "^origin/feature"],
                      output: .init(stdout: "2\n", stderr: "", exitCode: 0))
        Self.stubDiffAndStatus(executor, diffBase: "origin/feature")

        let stats = try await GitWorktreeStats.compute(
            worktreePath: "/wt",
            upstreamRefs: UpstreamRefs(defaultRef: "origin/main", branchRef: "origin/feature"),
            deadline: nil,
            using: executor
        )

        #expect(stats.ahead == 2)
        #expect(stats.behind == 3)
        #expect(executor.invocations.filter { $0.args.first == "rev-list" }.count == 2)
    }

    @Test func singleRefRejectsMalformedLeftRightOutput() async throws {
        let executor = FakeCLIExecutor()
        executor.stub(command: "git", args: ["rev-list", "--left-right", "--count", "HEAD...origin/main"],
                      output: .init(stdout: "2\n", stderr: "", exitCode: 0))
        Self.stubDiffAndStatus(executor, diffBase: "origin/main")

        await #expect(throws: GitWorktreeStatsError.unparseableRevList("2\n")) {
            try await GitWorktreeStats.compute(
                worktreePath: "/wt",
                upstreamRefs: UpstreamRefs(defaultRef: "origin/main"),
                deadline: nil,
                using: executor
            )
        }
    }

    @Test func singleRefMatchesSeparateCountsInARealRepo() async throws {
        let (root, clone, _) = try makeClonedRepo()
        defer { try? FileManager.default.removeItem(at: root) }
        let other = root.appendingPathComponent("other-clone")
        try shellInRepo("git clone \(root.appendingPathComponent("upstream.git").path) \(other.path)", at: root)
        try shellInRepo("""
            printf 'omega\\n' >> file.txt && git add file.txt && git commit -m 'omega' && \
            git push origin main
            """, at: other)
        try shellInRepo("""
            git fetch origin && \
            printf 'local\\n' > local.txt && git add local.txt && git commit -m 'local one' && \
            printf 'more\\n' >> local.txt && git add local.txt && git commit -m 'local two'
            """, at: clone)

        let stats = try await GitWorktreeStats.compute(
            worktreePath: clone.path,
            upstreamRefs: UpstreamRefs(defaultRef: "origin/main")
        )

        #expect(stats.ahead == 2)
        #expect(stats.behind == 1)
    }
}
