# Durable roles and instructions

Pin ongoing responsibilities such as releases or crash investigation; use temporary worktrees for bounded tasks. Pinning retains a worktree after PR or MR resolution without implying agent reachability. The default-branch checkout is always pinned.

```sh
graftty worktree pin
graftty worktree pin release-manager
graftty worktree unpin release-manager
```

No target, or `.`, means the current worktree. Otherwise use a name or roster `worktree_path`; prefer an absolute path when ambiguous. Agent suffixes are not worktree paths. Commands run on the owning Mac, are idempotent, and preserve branch, panes, and instructions. The default checkout cannot be unpinned.

Pinning does not create role instructions. Define them in `GRAFTTY.md` when establishing a durable role. If known before launch, place the role file where the child's first session can read it, delegate with `--wait`, then pin its returned path. For asynchronous creation, confirm readiness first. Unpinning preserves the workspace and files; explicit removal still requires `graftty worktree remove <worktree> --pinned`.

## Instruction files

For peer-visible roles, prefer the main checkout's `.graftty/<worktree-key>/GRAFTTY.md`. The first entry of `git worktree list --porcelain` identifies that checkout. Check higher-precedence overlays before editing. Create or modify instruction files only when authorized; preserve useful existing guidance.

- `.graftty/GRAFTTY.md` applies to every worktree in the repository.
- A linked worktree's key is its path relative to the main checkout's `.worktrees/`. The main checkout's key is the repository's default branch; until resolved, it receives only repository-wide instructions.
- `<parent>/<leaf>` reads `.graftty/<parent>/GRAFTTY.md` and `.graftty/<parent>/<leaf>/GRAFTTY.md`. Each applies to that key and descendants.
- Above `## Private`, text is shared with peers as role context. Below it, text reaches only matching worktrees.
- For each relative path, the first readable regular file wins: Application Support, current worktree, then main checkout.
- Current filesystem contents apply at the next session start; no commit is required.

To configure a new child's first session, place its exact-worktree file in Application Support, the main checkout, or its starting tree. For committed instructions, launch with `--base HEAD`. A role file does not pin a worktree; use the pin command separately.
