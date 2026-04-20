import Testing
import Foundation
@testable import EspalierKit

/// Covers `WorktreeMonitor.resolveHeadLogPath` for the three `.git`
/// file shapes a linked worktree can carry:
///   1. `gitdir: <absolute-path>` — the default in git ≤ 2.51 and
///      when `worktree.useRelativePaths=false`.
///   2. `gitdir: <relative-path>` — emitted when
///      `worktree.useRelativePaths=true` is set globally, defaulted
///      in git ≥ 2.52 on some platforms. Relative paths are measured
///      from the worktree directory, not from the process cwd.
///   3. Missing/unparseable `.git` — fall back to the
///      `<repoPath>/.git/worktrees/<basename>` guess so the watch
///      at least targets the conventional location.
@Suite("WorktreeMonitor.resolveHeadLogPath")
struct WorktreeMonitorHeadLogPathTests {

    private static func makeScratch() throws -> URL {
        let dir = URL(fileURLWithPath: "/tmp")
            .appendingPathComponent("espalier-monitor-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func absoluteGitdirReturnsAbsoluteReflogPath() throws {
        let scratch = try Self.makeScratch()
        defer { try? FileManager.default.removeItem(at: scratch) }

        let repo = scratch.appendingPathComponent("repo")
        let worktree = scratch.appendingPathComponent("wt")
        let gitDir = repo.appendingPathComponent(".git/worktrees/wt")
        try FileManager.default.createDirectory(at: gitDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)
        try "gitdir: \(gitDir.path)\n".write(
            to: worktree.appendingPathComponent(".git"),
            atomically: true, encoding: .utf8
        )

        let monitor = WorktreeMonitor()
        let result = monitor.resolveHeadLogPath(worktreePath: worktree.path, repoPath: repo.path)
        #expect(result == "\(CanonicalPath.canonicalize(gitDir.path))/logs/HEAD")
    }

    @Test func relativeGitdirResolvesAgainstWorktreeDirectory() throws {
        // git ≥ 2.52 with `worktree.useRelativePaths=true` writes
        // `gitdir: ../.git/worktrees/name` into the worktree's `.git`
        // file. The old code fed that verbatim to open(2), which
        // resolved it against the process cwd — usually nothing like
        // the worktree dir — and the HEAD-reflog watcher silently
        // watched the wrong path (or nothing at all).
        let scratch = try Self.makeScratch()
        defer { try? FileManager.default.removeItem(at: scratch) }

        let repo = scratch.appendingPathComponent("repo")
        let worktree = scratch.appendingPathComponent("wt")
        let gitDir = repo.appendingPathComponent(".git/worktrees/wt")
        try FileManager.default.createDirectory(at: gitDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)
        // `../repo/.git/worktrees/wt` from `<scratch>/wt` lands at
        // `<scratch>/repo/.git/worktrees/wt`.
        try "gitdir: ../repo/.git/worktrees/wt\n".write(
            to: worktree.appendingPathComponent(".git"),
            atomically: true, encoding: .utf8
        )

        let monitor = WorktreeMonitor()
        let result = monitor.resolveHeadLogPath(worktreePath: worktree.path, repoPath: repo.path)
        // The returned path must point at the same file regardless
        // of process cwd. Canonicalise the gitDir portion (which
        // exists so `realpath` resolves) and append the non-existent
        // `logs/HEAD` leaf manually.
        let expected = "\(CanonicalPath.canonicalize(gitDir.path))/logs/HEAD"
        #expect(
            result == expected,
            "relative gitdir must resolve against worktree dir; got \(result) vs \(expected)"
        )
        #expect(result.hasPrefix("/"), "reflog path must be absolute; got \(result)")
    }

    @Test func missingGitFileFallsBackToWorktreesNameGuess() throws {
        let scratch = try Self.makeScratch()
        defer { try? FileManager.default.removeItem(at: scratch) }

        let repo = scratch.appendingPathComponent("repo")
        let worktree = scratch.appendingPathComponent("named-wt")
        // Deliberately no .git file at all.
        try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)

        let monitor = WorktreeMonitor()
        let result = monitor.resolveHeadLogPath(worktreePath: worktree.path, repoPath: repo.path)
        #expect(result == "\(repo.path)/.git/worktrees/named-wt/logs/HEAD")
    }
}
