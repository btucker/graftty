import Foundation

/// Snapshot of all PRs/MRs that can be associated with the worktrees
/// of a single repo. Keyed by head-branch name (the same value
/// `WorktreeEntry.branch` holds for a worktree checked out on that
/// branch). Both open and merged PRs may appear; for any branch that
/// has both, the resolver inside the fetcher prefers `.open`.
///
/// @spec PR-8.12
public struct RepoPRSnapshot: Sendable, Equatable {
    public let prsByBranch: [String: PRInfo]

    public init(prsByBranch: [String: PRInfo]) {
        self.prsByBranch = prsByBranch
    }
}

/// Fetches the PR/MR snapshot for an entire repo in (ideally) one
/// host-CLI call. Replaces the previous per-branch fetcher so the
/// poller dispatches one fetch per repo per tick instead of one
/// fetch per worktree per tick — `gh pr list --json statusCheckRollup`
/// already returns CI rollup + mergeable for every PR in the repo
/// in a single network round-trip.
///
/// `branchesOfInterest` is a hint: when a provider's list endpoint
/// doesn't include CI status (GitLab `glab mr list` is the
/// motivating case — pipeline status only ships in the per-MR
/// `view` payload), the implementation may restrict secondary
/// fetches to the provided branches so a repo with 100 MRs and 5
/// worktrees doesn't trigger 100 pipeline calls per tick. GitHub's
/// `gh pr list --json statusCheckRollup` already returns checks in
/// the listing, so its implementation ignores the hint.
///
/// @spec PR-8.13
public protocol PRFetcher: Sendable {
    func fetch(
        origin: HostingOrigin,
        branchesOfInterest: Set<String>
    ) async throws -> RepoPRSnapshot
}
