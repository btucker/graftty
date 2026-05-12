# Stale worktree registry cleanup

## Problem

Worktree rows in the sidebar — most commonly those labeled `(detached)` —
can become impossible to remove from graftty. The user clicks
**Delete Worktree**, git fails, the **Force Delete** dialog appears,
**Force Delete** also fails, and the row remains in the sidebar across
restarts.

Root cause: the worktree's directory on disk has been removed
(typically by agent tooling that auto-creates and tears down scratch
worktrees — Codex, Claude Code, etc. — without calling
`git worktree remove`), but the repo's `.git/worktrees/<name>`
administrative entry survives. `git worktree remove <path>` validates
the path before doing anything and errors out with a message like
`'<path>' is not a working tree`. `--force` does not bypass that
validation, so graftty's existing retry path is a dead end.

Detached worktrees are disproportionately affected because the same
agent tooling that creates them also tends to detach to a SHA rather
than a branch.

## Approach

Distinguish the **stale-registry** failure mode from the
**dirty-files** failure mode in `performDeleteWorktree` and recover
silently for the stale-registry case.

On `GitWorktreeRemove.Error.gitFailed`, stat the worktree's directory
before deciding which alert to show:

- **Directory missing** → run `git worktree prune --expire=now` in the
  repo, then drop the row from `appState`. No second confirmation; the
  user already confirmed by clicking Delete Worktree.
- **Directory exists** → existing "Force Delete" alert path. Unchanged.

The explicit stat is chosen over parsing git's stderr: it is
unambiguous and does not break when git changes its wording across
versions.

## Components

### New: `Sources/GrafttyKit/Git/GitWorktreePrune.swift`

Thin subprocess wrapper, mirroring the shape of
`GitWorktreeRemove.swift`. Runs
`git worktree prune --expire=now` from `repoPath`. Returns on exit
code 0, throws `Error.gitFailed(exitCode:stderr:)` otherwise.

`--expire=now` is required: bare `git worktree prune` honors
`gc.worktreePruneExpire` (default 3 months) and would no-op on
recently-orphaned entries.

### Modified: `Sources/Graftty/Views/MainWindow.swift`

Inside `performDeleteWorktree`, in the `catch gitFailed` branch, add a
single new conditional ahead of the existing alert logic. When the
worktree's directory does not exist on disk:

1. Best-effort `try? await GitWorktreePrune.run(repoPath:)` — failure
   is logged but does not block step 2; the row is unusable either way
   and the sidebar should reflect that.
2. `appState.removeWorktree(atPath:)` — drops the row immediately. The
   FSEvents watcher's idempotent re-discovery callback is a backstop.

The existing `force == true` retry branch, the dirty-files Force
Delete alert, and the non-git-exit error alert are untouched.

## Behavior the user sees

- **Stale registry entry** (the new case): clicking Delete Worktree on
  the row makes it disappear, no dialog beyond the initial
  confirmation. Any other stale entries in the same repo are also
  pruned as a side effect of `git worktree prune` (it operates on the
  whole repo, not a single entry). This matches what the user wanted —
  the row is gone — without narrating internal mechanics.

- **Dirty/locked worktree** (the existing case): unchanged. Force
  Delete dialog appears, `--force` retry behaves exactly as today.

- **Non-stale `(detached)` worktree on disk**: unchanged. The
  `(detached)` label remains; this design does not relabel or filter
  legitimate detached worktrees.

## Spec annotations

One new requirement, placed in the GIT-4 cluster alongside the
existing worktree-remove specs:

> **GIT-4.13:** When `git worktree remove` fails and the worktree's
> directory does not exist on disk, the application shall run
> `git worktree prune --expire=now` against the repo and remove the
> row from the sidebar without prompting the user.

Annotated on the real `@Test` that exercises the missing-directory
branch of `performDeleteWorktree`. No `@spec` doc comment is needed on
a type — this is purely a behavioral spec.

## Testing

A single behavioral test covers the new branch. Fixture: a git repo
plus a linked worktree, then `rm -rf` the worktree directory to
create a stale registry entry. Assert:

1. `git worktree list --porcelain` lists the stale entry before the
   test action.
2. After invoking the delete path, the entry is gone from
   `git worktree list --porcelain`.
3. `appState.repos[…].worktrees` no longer contains the entry.

The existing `GitWorktreeRemove` tests and Force Delete alert tests
stay green untouched.

Unit test for `GitWorktreePrune.run` itself: verify the command
succeeds against a fixture repo with no prunable entries (no-op
exit 0), and fails cleanly when given a bad `repoPath`.

## Non-goals

- Relabeling `(detached)` rows whose directories still exist on disk.
  Those are legitimate (`git worktree add --detach`, `gh pr checkout`
  of fork PRs, bisecting) and the current label is fine.
- Introducing a `(missing)` sentinel sidebar label. Considered during
  brainstorming as option (B); rejected because the silent-recovery
  approach makes it unnecessary.
- Auto-pruning on every discovery pass. Considered as option (C);
  rejected because it would hide legitimate worktrees that live on
  network/USB volumes that come and go.
- Preventing agent tooling from creating scratch worktrees in the
  first place. Out of graftty's scope.

## Risk and rollback

The new branch is a strict superset of the old behavior: every code
path that used to reach the Force Delete alert still does, except
when the directory is already missing — in which case Force Delete
would have failed anyway. Rollback is a single revert of the
`MainWindow.swift` change; `GitWorktreePrune.swift` can stay (unused)
or be deleted with no other code referring to it.
