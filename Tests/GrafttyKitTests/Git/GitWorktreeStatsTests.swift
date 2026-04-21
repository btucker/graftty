import Testing
import Foundation
@testable import GrafttyKit

@Suite("GitWorktreeStats — parsers")
struct GitWorktreeStatsParserTests {

    // MARK: parseRevListCounts
    // Format is `<behind>\t<ahead>\n` because we invoke
    // `rev-list --left-right --count <default>...HEAD` — the left side
    // of A...B is "commits in A not B" (behind for us), right side is
    // "commits in B not A" (ahead).

    @Test func parsesRevListBothNonZero() throws {
        let result = GitWorktreeStats.parseRevListCounts("2\t5\n")
        #expect(result?.behind == 2)
        #expect(result?.ahead == 5)
    }

    @Test func parsesRevListAllZeros() throws {
        let result = GitWorktreeStats.parseRevListCounts("0\t0\n")
        #expect(result?.behind == 0)
        #expect(result?.ahead == 0)
    }

    @Test func parsesRevListWithTrailingWhitespace() throws {
        let result = GitWorktreeStats.parseRevListCounts("  3\t7  \n")
        #expect(result?.behind == 3)
        #expect(result?.ahead == 7)
    }

    @Test func rejectsMalformedRevListOutput() throws {
        #expect(GitWorktreeStats.parseRevListCounts("") == nil)
        #expect(GitWorktreeStats.parseRevListCounts("not a number\tnope\n") == nil)
        #expect(GitWorktreeStats.parseRevListCounts("only-one-column\n") == nil)
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

@Suite("GitWorktreeStats — compute (integration)")
struct GitWorktreeStatsComputeTests {

    func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("graftty-stats-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @discardableResult
    func shell(_ command: String, at dir: URL) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-c", command]
        process.currentDirectoryURL = dir
        process.environment = [
            "PATH": "/usr/bin:/bin:/usr/local/bin",
            "HOME": NSHomeDirectory(),
            "GIT_AUTHOR_NAME": "Test",
            "GIT_AUTHOR_EMAIL": "test@test.com",
            "GIT_COMMITTER_NAME": "Test",
            "GIT_COMMITTER_EMAIL": "test@test.com",
        ]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }

    /// Sets up a clone with origin/main as the default branch and returns
    /// the clone path.
    func makeClonedRepo() throws -> (root: URL, clone: URL) {
        let root = try makeTempDir()
        let upstream = root.appendingPathComponent("upstream.git")
        let clone = root.appendingPathComponent("clone")
        try FileManager.default.createDirectory(at: upstream, withIntermediateDirectories: true)
        try shell("git init --bare -b main", at: upstream)
        let seed = root.appendingPathComponent("seed")
        try FileManager.default.createDirectory(at: seed, withIntermediateDirectories: true)
        try shell("""
            git init -b main && \
            printf 'alpha\\nbeta\\ngamma\\n' > file.txt && \
            git add file.txt && \
            git commit -m init && \
            git remote add origin \(upstream.path) && \
            git push -u origin main
            """, at: seed)
        try shell("git clone \(upstream.path) \(clone.path)", at: root)
        return (root, clone)
    }

    @Test func returnsZerosAtParity() async throws {
        let (root, clone) = try makeClonedRepo()
        defer { try? FileManager.default.removeItem(at: root) }

        let stats = try await GitWorktreeStats.compute(
            worktreePath: clone.path,
            defaultBranchRef: "origin/main"
        )
        #expect(stats == WorktreeStats(ahead: 0, behind: 0, insertions: 0, deletions: 0))
    }

    @Test func countsAheadAndLineChanges() async throws {
        let (root, clone) = try makeClonedRepo()
        defer { try? FileManager.default.removeItem(at: root) }

        // Add two commits on HEAD with alpha tweaked + new lines added.
        try shell("""
            printf 'alpha\\nbeta\\ngamma\\ndelta\\n' > file.txt && \
            git add file.txt && git commit -m 'add delta' && \
            printf 'ALPHA\\nbeta\\ngamma\\ndelta\\nepsilon\\nzeta\\n' > file.txt && \
            git add file.txt && git commit -m 'add epsilon/zeta, tweak alpha'
            """, at: clone)

        let stats = try await GitWorktreeStats.compute(
            worktreePath: clone.path,
            defaultBranchRef: "origin/main"
        )
        #expect(stats.ahead == 2)
        #expect(stats.behind == 0)
        // alpha: changed (1+/1-); delta: new (1+); epsilon + zeta: new (2+).
        // Totals vs. the merge-base (= origin/main): +4 / -1.
        #expect(stats.insertions == 4)
        #expect(stats.deletions == 1)
    }

    @Test func countsBehindWhenOriginAdvances() async throws {
        let (root, clone) = try makeClonedRepo()
        defer { try? FileManager.default.removeItem(at: root) }

        // Push one new commit to origin from a second clone, then fetch.
        let other = root.appendingPathComponent("other-clone")
        try shell("git clone \(root.appendingPathComponent("upstream.git").path) \(other.path)", at: root)
        try shell("""
            printf 'alpha\\nbeta\\ngamma\\nomega\\n' > file.txt && \
            git add file.txt && git commit -m 'omega' && \
            git push origin main
            """, at: other)
        try shell("git fetch origin", at: clone)

        let stats = try await GitWorktreeStats.compute(
            worktreePath: clone.path,
            defaultBranchRef: "origin/main"
        )
        #expect(stats.ahead == 0)
        #expect(stats.behind == 1)
    }

    @Test func throwsWhenWorktreeMissing() async throws {
        let bogus = "/nonexistent-graftty-path-\(UUID().uuidString)"
        await #expect(throws: Error.self) {
            try await GitWorktreeStats.compute(worktreePath: bogus, defaultBranchRef: "origin/main")
        }
    }

    @Test func cleanWorktreeReportsNoUncommittedChanges() async throws {
        let (root, clone) = try makeClonedRepo()
        defer { try? FileManager.default.removeItem(at: root) }

        let stats = try await GitWorktreeStats.compute(
            worktreePath: clone.path,
            defaultBranchRef: "origin/main"
        )
        #expect(stats.hasUncommittedChanges == false)
    }

    @Test func modifiedTrackedFileMarksDirty() async throws {
        let (root, clone) = try makeClonedRepo()
        defer { try? FileManager.default.removeItem(at: root) }

        // Modify file.txt without committing.
        try shell(
            "printf 'alpha\\nbeta\\ngamma\\ndelta\\n' > file.txt",
            at: clone
        )

        let stats = try await GitWorktreeStats.compute(
            worktreePath: clone.path,
            defaultBranchRef: "origin/main"
        )
        #expect(stats.ahead == 0)
        #expect(stats.behind == 0)
        #expect(stats.hasUncommittedChanges == true)
    }

    @Test func untrackedFileMarksDirty() async throws {
        let (root, clone) = try makeClonedRepo()
        defer { try? FileManager.default.removeItem(at: root) }

        // Untracked files also count as uncommitted work per spec intent.
        try shell("printf 'scratch' > newfile.txt", at: clone)

        let stats = try await GitWorktreeStats.compute(
            worktreePath: clone.path,
            defaultBranchRef: "origin/main"
        )
        #expect(stats.hasUncommittedChanges == true)
    }
}
