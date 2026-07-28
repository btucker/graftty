import Testing
import Foundation
@testable import GrafttyKit

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
            .appendingPathComponent("graftty-monitor-\(UUID().uuidString.prefix(8))")
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

/// A genuine `SF_DATALESS` file can only be produced by the fileprovider
/// kernel path (iCloud eviction), so the spec is enforced on the pure
/// stat-predicate `WorktreeMonitor.isMaterializedRegularFile` with
/// synthetic `stat` values, plus a wiring assertion that
/// `resolveHeadLogPath` degrades to the conventional-location guess when
/// the `.git` entry is not readable as a materialized regular file.
@Suite("""
@spec GIT-3.20: If a linked worktree's `.git` entry is not a materialized regular file \
(an iCloud-evicted `SF_DATALESS` placeholder or a non-regular file type), then \
`WorktreeMonitor.resolveHeadLogPath` shall skip reading it — deciding via a metadata-only \
stat, which never triggers materialization — and fall back to the \
`<repoPath>/.git/worktrees/<basename>` guess, rather than issue a read(2) that blocks the \
calling thread on network materialization. `startup()` resolves reflog paths on the main \
thread, so a single iCloud-evicted `.git` file under `~/Documents` froze the whole app at \
launch (Application Not Responding).
""")
struct DatalessGitFileGuardTests {

    private func syntheticStat(mode: mode_t, flags: UInt32 = 0) -> stat {
        var st = stat()
        st.st_mode = mode
        st.st_flags = flags
        return st
    }

    @Test func materializedRegularFileIsReadable() {
        let st = syntheticStat(mode: S_IFREG | 0o644)
        #expect(WorktreeMonitor.isMaterializedRegularFile(st))
    }

    @Test func datalessRegularFileIsRejected() {
        let st = syntheticStat(mode: S_IFREG | 0o644, flags: UInt32(SF_DATALESS))
        #expect(!WorktreeMonitor.isMaterializedRegularFile(st))
    }

    @Test func nonRegularFileIsRejected() {
        let st = syntheticStat(mode: S_IFIFO | 0o644)
        #expect(!WorktreeMonitor.isMaterializedRegularFile(st))
    }

    @Test func resolveHeadLogPathFallsBackWhenGitEntryIsNotMaterializedRegular() throws {
        let scratch = URL(fileURLWithPath: "/tmp")
            .appendingPathComponent("graftty-dataless-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        let repo = scratch.appendingPathComponent("repo")
        let worktree = scratch.appendingPathComponent("fifo-wt")
        try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)
        // A FIFO stands in for the dataless placeholder: same guard
        // (stat says not a materialized regular file → don't read).
        #expect(mkfifo(worktree.appendingPathComponent(".git").path, 0o644) == 0)

        let monitor = WorktreeMonitor()
        let result = monitor.resolveHeadLogPath(worktreePath: worktree.path, repoPath: repo.path)
        #expect(result == "\(repo.path)/.git/worktrees/fifo-wt/logs/HEAD")
    }
}
