# Remote Branch Gated PR/MR Polling - Design Specification

Make PR/MR polling follow the lifecycle users actually experience: a local
worktree branch starts unpushed, later gains an `origin/<branch>` ref, and only
then becomes worth asking GitHub/GitLab about. This avoids wasting host CLI
calls for never-pushed local branches while making pushed branches discover PRs
without requiring the user to select the tab.

## 1. Goals and Non-Goals

**Goals:**

- Detect, cheaply and frequently, whether each non-stale worktree branch has a
  local remote-tracking ref at `refs/remotes/origin/<branch>`.
- Treat branch remote-existence as the gate for PR/MR polling:
  unpushed branches do not invoke `gh`/`glab`; pushed branches do.
- Keep the existing origin-ref file watcher as the fastest signal when this
  clone observes a push, fetch, or prune.
- Add a 10-second local-ref scan as a safety net for missed/coalesced watcher
  events and changes made by other local processes.
- Poll PR/MR status every 30 seconds once the branch is pushed. Existing faster
  pending-CI behavior may stay if already present, but pushed/no-PR and stable
  PR states should not wait on user selection.

**Non-goals:**

- Detect remote branches that this clone has never fetched. A local ref check
  cannot see branches that only exist on GitHub/GitLab. The existing repo-level
  `git fetch` cadence remains the mechanism for discovering those.
- Replace the `gh`/`glab` fetchers.
- Create PRs/MRs or infer PR existence from commit metadata.
- Poll never-pushed branches against the hosting provider.

## 2. Signals

### 2.1 Origin-Ref Watcher

`WorktreeMonitor.watchOriginRefs(repoPath:)` already watches
`<repoPath>/.git/logs/refs/remotes/origin/`. Keep this as the immediate signal
for local operations that advance remote-tracking refs:

- `git push` from this clone
- `git fetch`
- prune/delete of an origin ref

On this event, refresh the repo's local remote-branch index, refresh divergence
stats as today, and re-evaluate PR/MR polling eligibility for every worktree in
the repo.

### 2.2 Local Remote-Branch Scan

Every 10 seconds, per tracked repo, run a cheap local git command equivalent to:

```bash
git for-each-ref --format=%(refname:short) refs/remotes/origin
```

Store the resulting branch-name set after stripping the `origin/` prefix. This
scan is local-only and should not contact the network. It is cheap relative to
`gh`/`glab` and cheaper than a network `git fetch`.

Use this scan to answer, for a worktree branch `feature/x`:

```swift
remoteBranchesByRepo[repoPath].contains("feature/x")
```

Sentinel branches such as `(detached)`, `(bare)`, `(unknown)`, empty strings,
and whitespace-only values remain ineligible.

### 2.3 Repo-Level Fetch

Repo-level `git fetch --no-tags --prune origin` remains separate. It is the
only local mechanism in this design that can discover remote branches created
from another clone. Its cadence should not be collapsed into the 10-second
local scan unless the user explicitly accepts that network cost.

## 3. State Model

Track per worktree path:

- `unpushed`: no local `origin/<branch>` exists. Do not invoke host PR/MR CLI.
- `pushedNoPR`: local `origin/<branch>` exists, but the latest PR/MR lookup
  returned absent. Poll every 30 seconds.
- `hasPR`: latest lookup returned a PR/MR. Poll every 30 seconds, preserving
  any existing faster pending-CI cadence if desired.
- `merged`: latest lookup returned merged. Keep current merged-offer behavior;
  continue polling at the stable cadence until the worktree is deleted,
  dismissed, or the user explicitly keeps it.

Transitions:

- `unpushed -> pushedNoPR`: local remote-branch scan or origin-ref watcher sees
  `origin/<branch>`.
- `pushedNoPR -> hasPR`: PR/MR fetcher returns a PR/MR.
- `hasPR -> merged`: PR/MR fetcher returns merged.
- Any state -> `unpushed`: branch changes or the local remote ref disappears.
- Any state -> cleared: worktree becomes stale, is dismissed, or is deleted.

The existing branch-change path should clear cached PR info and re-evaluate the
new branch's remote-ref presence immediately.

## 4. Components

### 4.1 `RemoteBranchStore`

Add a small `@MainActor` observable or store-like component in `GrafttyKit` or
near `WorktreeStatsStore`/`PRStatusStore`:

```swift
public final class RemoteBranchStore {
    public private(set) var branchesByRepo: [String: Set<String>]

    public func refresh(repoPath: String)
    public func start(ticker:getRepos:)
    public func hasRemote(repoPath: String, branch: String) -> Bool
    public func clear(repoPath: String)
}
```

Implementation details:

- Inject a git-listing function for tests.
- Deduplicate concurrent refreshes per repo.
- Publish only when the branch set changes.
- Keep the command local-only; no fetch.

### 4.2 `PRStatusStore` Gate

Teach `PRStatusStore` to distinguish "not eligible because branch is unpushed"
from "eligible and absent." The background tick should skip unpushed branches
instead of marking them absent and backing off.

The gate can be injected as:

```swift
@MainActor (String, String) -> Bool
// repoPath, branch -> has local origin/<branch>
```

Manual refresh from the UI can either:

- respect the gate, keeping behavior consistent, or
- bypass it for explicit user action.

Recommended: respect the gate for empty/sentinel/unpushed branches, because a
manual refresh cannot find a PR for a branch the host has no pushed ref for.

### 4.3 App Wiring

At startup:

- Start `RemoteBranchStore` with a 10-second ticker.
- Run an initial refresh for every tracked repo.
- Pass `RemoteBranchStore.hasRemote(repoPath:branch:)` into `PRStatusStore`.

On origin-ref watcher event:

- Refresh the remote-branch set for that repo immediately.
- Pulse/re-run PR eligibility after that refresh.
- Keep the delayed follow-up PR refreshes for the push-then-create race, but
  only for worktrees whose branch is now locally pushed.

On branch-change event:

- Update the worktree's branch label.
- Refresh stats as today.
- Clear PR cache.
- Re-check local remote existence for the new branch and only start PR polling
  if `origin/<branch>` exists.

## 5. Error Handling

- If local remote-branch listing fails, preserve the previous branch set and log
  at debug/info level. A transient git lock or missing repo should not erase
  all eligibility and hide existing PR badges.
- If the repo is removed or relocated, clear the old repo's branch set.
- If a remote branch disappears, clear the worktree's PR cache so stale PR badges
  do not remain attached to a now-unpushed/deleted branch.
- Host CLI failures keep existing `PRStatusStore` behavior: preserve last-known
  PR info and use failure backoff.

## 6. Testing

Add focused tests for:

- Local remote-branch scan strips `origin/` and preserves slash branch names.
- Scan failure preserves the previous branch set.
- `PRStatusStore` does not call `gh`/`glab` for unpushed branches.
- `PRStatusStore` starts polling once `origin/<branch>` appears locally.
- Origin-ref watcher refreshes the branch set before scheduling PR/MR follow-ups.
- Branch changes clear prior PR status and re-apply the remote-branch gate.
- Remote-ref deletion clears stale PR status.

## 7. SPECS.md Updates

Implementation should add EARS requirements under Worktree Discovery &
Monitoring / PR status behavior, including:

- While a repository is tracked, the application shall scan local
  `refs/remotes/origin/*` every 10 seconds without contacting the network.
- When a worktree branch lacks a local `origin/<branch>` ref, the application
  shall skip PR/MR host polling for that worktree.
- When a local `origin/<branch>` ref appears, the application shall begin PR/MR
  polling for that worktree on the pushed-branch cadence.
- When a local `origin/<branch>` ref disappears, the application shall clear
  cached PR/MR status for worktrees on that branch.
