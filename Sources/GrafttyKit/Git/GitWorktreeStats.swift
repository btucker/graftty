import Foundation

/// The set of refs a worktree's divergence is measured against.
/// Always at least `defaultRef`; also includes `branchRef` when the
/// worktree's own branch has an `origin/<branch>` tracking ref.
public struct UpstreamRefs: Equatable, Sendable {
    public let defaultRef: String
    public let branchRef: String?

    public init(defaultRef: String, branchRef: String? = nil) {
        self.defaultRef = defaultRef
        self.branchRef = branchRef
    }

    /// Every ref to include on the reachable side of `rev-list`.
    public var all: [String] {
        branchRef.map { [defaultRef, $0] } ?? [defaultRef]
    }

    /// Sidebar tooltip label: either the single ref or both joined with `" + "`.
    public var displayLabel: String {
        branchRef.map { "\(defaultRef) + \($0)" } ?? defaultRef
    }
}

/// Ephemeral per-worktree divergence information. Not persisted — lives
/// in `WorktreeStatsStore` for the session only.
public struct WorktreeStats: Equatable, Sendable {
    public let ahead: Int
    public let behind: Int
    public let insertions: Int
    public let deletions: Int
    /// True when the worktree has modified, staged, deleted, or untracked
    /// files. Surfaced inline as a `+` suffix on the ahead count so the
    /// user can distinguish "clean branch, 2 commits ahead" from
    /// "2 commits ahead plus work in progress" at a glance.
    public let hasUncommittedChanges: Bool
    /// The upstream refs these counts were measured against. Nil only
    /// for test fixtures that pre-build stats without going through
    /// compute; production always populates it.
    public let upstreamRefs: UpstreamRefs?

    public init(
        ahead: Int,
        behind: Int,
        insertions: Int,
        deletions: Int,
        hasUncommittedChanges: Bool = false,
        upstreamRefs: UpstreamRefs? = nil
    ) {
        self.ahead = ahead
        self.behind = behind
        self.insertions = insertions
        self.deletions = deletions
        self.hasUncommittedChanges = hasUncommittedChanges
        self.upstreamRefs = upstreamRefs
    }

    public var isEmpty: Bool {
        ahead == 0 && behind == 0 && insertions == 0 && deletions == 0 && !hasUncommittedChanges
    }
}

public enum GitWorktreeStats {

    /// Picks the upstream refs a worktree's divergence is measured
    /// against: always `origin/<defaultBranch>`, plus `origin/<branch>`
    /// when that tracking ref exists. The union semantics then surface
    /// both PR merges on the default branch and collaborator pushes to
    /// the worktree's own branch as ↓N. See `DIVERGE-3.0`.
    public static func resolveUpstreamRefs(
        worktreePath: String,
        branch: String,
        defaultBranch: String,
        timeout: Duration? = nil
    ) async -> UpstreamRefs {
        let deadline = timeout.map(GitCommandDeadline.init(timeout:))
        return await resolveUpstreamRefs(
            worktreePath: worktreePath,
            branch: branch,
            defaultBranch: defaultBranch,
            deadline: deadline
        )
    }

    static func resolveUpstreamRefs(
        worktreePath: String,
        branch: String,
        defaultBranch: String,
        deadline: GitCommandDeadline?,
        using executor: CLIExecutor? = nil,
        includeDefaultBranchRemote: Bool = false
    ) async -> UpstreamRefs {
        let defaultRef = "origin/\(defaultBranch)"
        let fallback = UpstreamRefs(defaultRef: defaultRef)
        guard !branch.isEmpty, branch != defaultBranch || includeDefaultBranchRemote else { return fallback }
        let branchCandidate = "origin/\(branch)"
        let commandTimeout: Duration?
        do {
            commandTimeout = try deadline?.remaining()
        } catch {
            return fallback
        }
        guard let captured = try? await GitRunner.capture(
            args: ["show-ref", "--verify", "--quiet", "refs/remotes/\(branchCandidate)"],
            at: worktreePath,
            timeout: commandTimeout,
            using: executor
        ), captured.exitCode == 0 else {
            return fallback
        }
        return UpstreamRefs(defaultRef: defaultRef, branchRef: branchCandidate)
    }

    /// Parse `git rev-list --count …` output — a single non-negative
    /// integer on its own line. Returns nil on non-numeric input.
    public static func parseSingleCount(_ output: String) -> Int? {
        Int(output.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Parse `git rev-list --left-right --count A...B` output: the count
    /// of commits only in `A`, a tab, and the count only in `B`. Returns
    /// nil unless both are present and numeric.
    public static func parseLeftRightCount(_ output: String) -> (left: Int, right: Int)? {
        let fields = output.split(whereSeparator: \.isWhitespace)
        guard fields.count == 2, let left = Int(fields[0]), let right = Int(fields[1]) else {
            return nil
        }
        return (left, right)
    }

    /// Parse output of `git diff --shortstat`. Empty output means no diff —
    /// return (0, 0) rather than failing, since "no changes" is a valid answer.
    public static func parseShortStat(_ output: String) -> (insertions: Int, deletions: Int) {
        var insertions = 0
        var deletions = 0
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return (0, 0) }
        for part in trimmed.split(separator: ",") {
            let token = part.trimmingCharacters(in: .whitespaces)
            if token.contains("insertion"), let n = leadingInt(token) {
                insertions = n
            } else if token.contains("deletion"), let n = leadingInt(token) {
                deletions = n
            }
        }
        return (insertions: insertions, deletions: deletions)
    }

    private static func leadingInt(_ s: String) -> Int? {
        var digits = ""
        for ch in s {
            if ch.isWholeNumber { digits.append(ch) } else if !digits.isEmpty { break }
        }
        return Int(digits)
    }

    /// Computes divergence stats for a worktree vs. the union of its
    /// upstream refs. Runs three local git commands in sequence (four when
    /// there are two upstream refs); each is awaited so callers yield
    /// rather than block. Throws if git fails
    /// to launch or exits non-zero.
    ///
    /// Semantics:
    /// - `behind` = commits reachable from any upstream ref but not
    ///   HEAD. `git rev-list` natively dedupes so overlap (e.g. a push
    ///   to `origin/<branch>` that was already rebased onto `origin/<default>`)
    ///   is counted once.
    /// - `ahead` = commits reachable from HEAD but not from any
    ///   upstream ref — the user's truly unpushed local work.
    /// - Lines and dirty-flag semantics unchanged; the `git diff` uses
    ///   the worktree's own branch upstream when present (so the
    ///   tooltip describes "your work on this branch"), falling back
    ///   to the default ref.
    public static func compute(
        worktreePath: String,
        upstreamRefs: UpstreamRefs,
        timeout: Duration? = nil
    ) async throws -> WorktreeStats {
        let deadline = timeout.map(GitCommandDeadline.init(timeout:))
        return try await compute(
            worktreePath: worktreePath,
            upstreamRefs: upstreamRefs,
            deadline: deadline
        )
    }

    static func compute(
        worktreePath: String,
        upstreamRefs: UpstreamRefs,
        deadline: GitCommandDeadline?,
        using executor: CLIExecutor? = nil
    ) async throws -> WorktreeStats {
        func git(_ args: [String]) async throws -> String {
            do {
                return try await GitRunner.run(
                    args: args,
                    at: worktreePath,
                    timeout: try deadline?.remaining(),
                    using: executor
                )
            } catch let err as CLIError {
                throw GitWorktreeStatsError.gitFailed(err)
            }
        }

        let ahead: Int
        let behind: Int
        if upstreamRefs.branchRef == nil {
            // One ref: the symmetric difference splits into exactly the two
            // one-sided counts, so a single child answers both.
            let output = try await git(
                ["rev-list", "--left-right", "--count", "HEAD...\(upstreamRefs.defaultRef)"]
            )
            guard let counts = parseLeftRightCount(output) else {
                throw GitWorktreeStatsError.unparseableRevList(output)
            }
            (ahead, behind) = (counts.left, counts.right)
        } else {
            let allRefs = upstreamRefs.all
            let behindOutput = try await git(["rev-list", "--count"] + allRefs + ["^HEAD"])
            guard let behindCount = parseSingleCount(behindOutput) else {
                throw GitWorktreeStatsError.unparseableRevList(behindOutput)
            }
            let aheadOutput = try await git(["rev-list", "--count", "HEAD"] + allRefs.map { "^\($0)" })
            guard let aheadCount = parseSingleCount(aheadOutput) else {
                throw GitWorktreeStatsError.unparseableRevList(aheadOutput)
            }
            (ahead, behind) = (aheadCount, behindCount)
        }

        // Lines: use the worktree's own branch upstream when present,
        // else the default. `branch...HEAD` (three-dot) counts work from
        // the merge-base forward — i.e. "your commits on this branch".
        let diffBase = upstreamRefs.branchRef ?? upstreamRefs.defaultRef
        let diff = parseShortStat(try await git(["diff", "--shortstat", "\(diffBase)...HEAD"]))

        let statusOutput = try await git(["status", "--porcelain"])
        let dirty = !statusOutput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        return WorktreeStats(
            ahead: ahead,
            behind: behind,
            insertions: diff.insertions,
            deletions: diff.deletions,
            hasUncommittedChanges: dirty,
            upstreamRefs: upstreamRefs
        )
    }
}

public enum GitWorktreeStatsError: Swift.Error, Equatable {
    case gitFailed(CLIError)
    case unparseableRevList(String)
}
