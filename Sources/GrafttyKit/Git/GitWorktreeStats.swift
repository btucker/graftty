import Foundation

/// Ephemeral per-worktree divergence information vs. the origin default branch.
/// Not persisted — lives in `WorktreeStatsStore` for the session only.
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

    public init(
        ahead: Int,
        behind: Int,
        insertions: Int,
        deletions: Int,
        hasUncommittedChanges: Bool = false
    ) {
        self.ahead = ahead
        self.behind = behind
        self.insertions = insertions
        self.deletions = deletions
        self.hasUncommittedChanges = hasUncommittedChanges
    }

    public var isEmpty: Bool {
        ahead == 0 && behind == 0 && insertions == 0 && deletions == 0 && !hasUncommittedChanges
    }
}

public enum GitWorktreeStats {

    /// Parse output of `git rev-list --left-right --count <ref>...HEAD`.
    /// A single line of the form `<left>\t<right>\n`, where left = commits
    /// reachable from `<ref>` but not HEAD (behind), right = commits
    /// reachable from HEAD but not `<ref>` (ahead).
    public static func parseRevListCounts(_ output: String) -> (behind: Int, ahead: Int)? {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let parts = trimmed.split(separator: "\t", omittingEmptySubsequences: false)
        guard parts.count == 2,
              let behind = Int(parts[0].trimmingCharacters(in: .whitespaces)),
              let ahead = Int(parts[1].trimmingCharacters(in: .whitespaces)) else {
            return nil
        }
        return (behind: behind, ahead: ahead)
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

    /// Computes divergence stats for a worktree vs. an origin default branch ref.
    /// Runs three local git commands in sequence; each is awaited so callers
    /// yield rather than block. Throws if git fails to launch or exits non-zero
    /// on rev-list/diff. Uncommitted-changes detection uses `git status
    /// --porcelain`: any output (modified, staged, deleted, untracked) counts
    /// as dirty.
    public static func compute(
        worktreePath: String,
        defaultBranchRef: String
    ) async throws -> WorktreeStats {
        let range = "\(defaultBranchRef)...HEAD"

        let revListOutput: String
        do {
            revListOutput = try await GitRunner.run(
                args: ["rev-list", "--left-right", "--count", range],
                at: worktreePath
            )
        } catch let err as CLIError {
            throw GitWorktreeStatsError.gitFailed(err)
        }

        guard let counts = parseRevListCounts(revListOutput) else {
            throw GitWorktreeStatsError.unparseableRevList(revListOutput)
        }

        let diffOutput: String
        do {
            diffOutput = try await GitRunner.run(
                args: ["diff", "--shortstat", range],
                at: worktreePath
            )
        } catch let err as CLIError {
            throw GitWorktreeStatsError.gitFailed(err)
        }
        let diff = parseShortStat(diffOutput)

        let statusOutput: String
        do {
            statusOutput = try await GitRunner.run(
                args: ["status", "--porcelain"],
                at: worktreePath
            )
        } catch let err as CLIError {
            throw GitWorktreeStatsError.gitFailed(err)
        }
        let dirty = !statusOutput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        return WorktreeStats(
            ahead: counts.ahead,
            behind: counts.behind,
            insertions: diff.insertions,
            deletions: diff.deletions,
            hasUncommittedChanges: dirty
        )
    }
}

public enum GitWorktreeStatsError: Swift.Error, Equatable {
    case gitFailed(CLIError)
    case unparseableRevList(String)
}
