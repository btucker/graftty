// Auto-generated inventory of unimplemented specs in this section.
// Promote a @Test(.disabled(...)) entry to a real @Test in a *Tests.swift
// file before implementing the behavior, then delete the entry from this
// inventory file. SPECS.md is regenerated from these markers by
// scripts/generate-specs.py.

import Testing

@Suite("GIT — pending specs")
struct GitTodo {
    @Test("""
@spec GIT-1.1: When a repository is added, the application shall run `git worktree list --porcelain` and populate the sidebar with all discovered worktrees in the closed state.
""", .disabled("not yet implemented"))
    func git_1_1() async throws { }

    @Test("""
@spec GIT-1.2: When the user picks a folder in the Add Repository flow and `git worktree list --porcelain` fails on that folder (not a git repository, missing `git` binary, permission denied), the application shall present an `NSAlert` showing the folder path and the underlying error message, rather than silently returning from the Task. Without this, the user clicks a menu, picks a folder, and sees nothing happen — no log, no error, no repo added.
""", .disabled("not yet implemented"))
    func git_1_2() async throws { }

    @Test("""
@spec GIT-2.1: While a repository is in the sidebar, the application shall watch the repository's `.git/worktrees/` directory for changes using FSEvents.
""", .disabled("not yet implemented"))
    func git_2_1() async throws { }

    @Test("""
@spec GIT-2.2: When a change is detected in `.git/worktrees/`, the application shall re-run `git worktree list --porcelain` and reconcile the results against the current model.
""", .disabled("not yet implemented"))
    func git_2_2() async throws { }

    @Test("""
@spec GIT-2.3: While a repository is in the sidebar, the application shall watch each worktree's directory path for deletion using FSEvents.
""", .disabled("not yet implemented"))
    func git_2_3() async throws { }

    @Test("""
@spec GIT-2.4: While a repository is in the sidebar, the application shall detect every operation that moves a worktree's HEAD — including commits on the current branch, `checkout`, `switch`, `reset`, `merge`, and `rebase` — and surface each as a HEAD-reference change.
""", .disabled("not yet implemented"))
    func git_2_4() async throws { }

    @Test("""
@spec GIT-2.5: While a repository is in the sidebar, the application shall watch `<repoPath>/.git/logs/refs/remotes/origin/` using FSEvents so that any operation which advances a remote-tracking ref — `git push` (the common `gh pr create` path), `git fetch`, and prune — surfaces as an origin-ref change. One watch per repository covers all linked worktrees, since they share the main checkout's git directory.
""", .disabled("not yet implemented"))
    func git_2_5() async throws { }

    @Test("""
@spec GIT-2.8: While a repository is in the sidebar, the application shall scan local `refs/remotes/origin/*` every 10 seconds without contacting the network, maintaining a repo-scoped set of locally-known remote branch names. The scan shall use local git ref metadata only; it shall not replace the repo-level fetch cadence that discovers branches created from another clone.
""", .disabled("not yet implemented"))
    func git_2_8() async throws { }

    @Test("""
@spec GIT-2.9: When the origin-ref watcher from `GIT-2.5` observes a remote-tracking ref movement, the application shall refresh the repo's local remote-branch set before deciding which worktrees should receive PR/MR polling.
""", .disabled("not yet implemented"))
    func git_2_9() async throws { }

    @Test("""
@spec GIT-3.1: When a new worktree is detected, the application shall add a new entry in the closed state and briefly flash its background highlight.
""", .disabled("not yet implemented"))
    func git_3_1() async throws { }

    @Test("""
@spec GIT-3.2: When a worktree is removed via `git worktree remove`, the application shall transition the entry to the stale state.
""", .disabled("not yet implemented"))
    func git_3_2() async throws { }

    @Test("""
@spec GIT-3.3: When a worktree's directory is deleted externally, the application shall transition the entry to the stale state.
""", .disabled("not yet implemented"))
    func git_3_3() async throws { }

    @Test("""
@spec GIT-3.4: While a worktree entry is in the stale state and was running, the application shall keep terminal surfaces alive until the user explicitly stops the entry.
""", .disabled("not yet implemented"))
    func git_3_4() async throws { }

    @Test("""
@spec GIT-3.5: When a worktree's HEAD reference changes, the application shall update the entry's branch label in the sidebar.
""", .disabled("not yet implemented"))
    func git_3_5() async throws { }

    @Test("""
@spec GIT-3.6: While a worktree entry is in the stale state, the context menu shall include a "Dismiss" action that removes the entry from the sidebar and drops its cached PR status, divergence stats, and any other per-path observable state so a future worktree added at the same path starts from a clean slate.
""", .disabled("not yet implemented"))
    func git_3_6() async throws { }

    @Test("""
@spec GIT-3.7: When a worktree entry in the stale state reappears in `git worktree list --porcelain` output (e.g., after a transient FSEvents glitch, a `git worktree repair`, or a force-remove followed by a fresh `git worktree add` at the same path), the application shall transition the entry back to the closed state and adopt any updated branch label.
""", .disabled("not yet implemented"))
    func git_3_7() async throws { }

    @Test("""
@spec GIT-3.8: When the user clicks a stale worktree entry whose directory still exists on disk (the stale state was a lingering artifact of a prior transient filesystem event), the application shall resurrect the entry to the closed state, clear any leftover split tree referencing destroyed surfaces, and proceed with the normal closed→running transition so terminals start rather than the content area showing the `Color.black + ProgressView` terminal-not-yet-created placeholder indefinitely.
""", .disabled("not yet implemented"))
    func git_3_8() async throws { }

    @Test("""
@spec GIT-3.9: When resurrecting a worktree entry that was stale-while-running (per `GIT-3.4`, which kept surfaces alive across the stale transition), the application shall tear down every terminal surface in the entry's previous split tree *before* creating the fresh surface for the resurrected entry, so the old surfaces' render/IO/kqueue threads stop rather than running orphaned — orphaned surfaces have been observed to corrupt libghostty's internal `os_unfair_lock` during window resize and SIGKILL the app.
""", .disabled("not yet implemented"))
    func git_3_9() async throws { }

    @Test("""
@spec GIT-3.10: When the user triggers "Dismiss" on a stale worktree whose surfaces are still alive per `GIT-3.4` (stale-while-running), the application shall tear down every terminal surface in the entry's split tree before removing the entry from the model, and shall clear `selectedWorktreePath` if the dismissed worktree was currently selected. Skipping the surface teardown is the same orphan-surfaces shape as `GIT-3.9` (different entry point) and has the same crash signature.
""", .disabled("not yet implemented"))
    func git_3_10() async throws { }

    @Test("""
@spec GIT-3.12: When `GitWorktreeDiscovery.discover(repoPath:)` throws (missing `git` binary, non-repo path passed due to a stale state.json entry, subprocess exceeding the timeout, transient FS glitch), the application shall log the failure via `NSLog` at every call site in `GrafttyApp` — `reconcileOnLaunch`, `worktreeMonitorDidDetectChange`, and `worktreeMonitorDidDetectBranchChange` — rather than swallow via `try?`. Analogue of `ATTN-2.7` / `PERSIST-2.2`. Without this, a transient discovery failure silently skips that repo's reconcile tick: Andy creates a new worktree, FSEvents fires, discover throws once, and the worktree never appears in the sidebar with no trail of why.
""", .disabled("not yet implemented"))
    func git_3_12() async throws { }

    @Test("""
@spec GIT-3.13: When a worktree transitions to the `.stale` state — regardless of which FSEvents channel observed the disappearance (`worktreeMonitorDidDetectDeletion` for the worktree-directory watcher, or the reconcile-driven transitions in `reconcileOnLaunch` / `worktreeMonitorDidDetectChange` when `git worktree list --porcelain` stops listing the entry) — the application shall call `statsStore.clear(worktreePath:)` and `prStatusStore.clear(worktreePath:)` so the cached stats and PR status don't linger on the stale entry. Matches `GIT-4.10`'s rule for the explicit-remove path; the three stale-transition paths must be symmetric, otherwise a worktree made stale by reconcile keeps rendering its old PR badge until a Dismiss or Delete fires.
""", .disabled("not yet implemented"))
    func git_3_13() async throws { }

    @Test("""
@spec GIT-3.14: When `WorktreeMonitor.resolveHeadLogPath` reads a linked worktree's `.git` file and finds a `gitdir: <path>` line, it shall resolve a relative `<path>` against the worktree directory rather than feeding it verbatim to `open(2)`. Git ≥ 2.52 with `worktree.useRelativePaths=true` writes relative gitdir entries like `gitdir: ../.git/worktrees/name`; passing that to `open` resolves it against the process cwd — usually nothing like the worktree dir — so the HEAD-reflog watcher silently targets the wrong path (or fails outright). The absolute-gitdir case (older git and the default config) is unaffected.
""", .disabled("not yet implemented"))
    func git_3_14() async throws { }

    @Test("""
@spec GIT-3.16: When a stale worktree is resurrected via user click (`selectWorktree` per `GIT-3.8`) rather than via the reconciler, the application shall re-arm the path / HEAD-reflog watchers for the worktree on the new inode. A user-click resurrection does not fire a `.git/worktrees/` FSEvents tick (no git subprocess ran), so the reconciler's re-register loop in `worktreeMonitorDidDetectChange` never runs — without this, the resurrected worktree has no real-time PR refresh until the polling safety nets catch up or the user triggers a git operation that bumps the `.git/worktrees/` dir.
""", .disabled("not yet implemented"))
    func git_3_16() async throws { }

    @Test("""
@spec GIT-3.17: When a worktree's current branch lacks a local `origin/<branch>` ref, the application shall skip GitHub/GitLab PR/MR host polling for that worktree and shall not mark the worktree as "absent PR" merely because the branch has not been pushed.
""", .disabled("not yet implemented"))
    func git_3_17() async throws { }

    @Test("""
@spec GIT-3.18: When a local `origin/<branch>` ref appears for a non-stale worktree's current branch, the application shall begin PR/MR polling for that worktree on the pushed-branch cadence without requiring the user to select the worktree.
""", .disabled("not yet implemented"))
    func git_3_18() async throws { }

    @Test("""
@spec GIT-3.19: When a local `origin/<branch>` ref disappears for a non-stale worktree's current branch, the application shall clear cached PR/MR status for that worktree so stale PR badges do not remain attached to an unpushed or deleted remote branch.
""", .disabled("not yet implemented"))
    func git_3_19() async throws { }

    @Test("""
@spec GIT-4.1: While a worktree entry is not in the stale state and is not the repository's main checkout, the context menu shall include a "Delete Worktree" action.
""", .disabled("not yet implemented"))
    func git_4_1() async throws { }

    @Test("""
@spec GIT-4.2: When the user triggers "Delete Worktree", the application shall display a confirmation dialog whose informative text explicitly states "This will delete the worktree but not the branch."
""", .disabled("not yet implemented"))
    func git_4_2() async throws { }

    @Test("""
@spec GIT-4.3: When the user confirms "Delete Worktree", the application shall run `git worktree remove <path>` in the repository, leaving the worktree's branch ref untouched.
""", .disabled("not yet implemented"))
    func git_4_3() async throws { }

    @Test("""
@spec GIT-4.5: When `git worktree remove` succeeds on a worktree in the running state, the application shall tear down all terminal surfaces in the worktree's split tree.
""", .disabled("not yet implemented"))
    func git_4_5() async throws { }

    @Test("""
@spec GIT-4.6: When `git worktree remove` succeeds, the application shall remove the worktree entry from the sidebar, and if that worktree was the selected worktree the application shall clear the selected-worktree state so the terminal content area shows the "no worktree selected" placeholder.
""", .disabled("not yet implemented"))
    func git_4_6() async throws { }

    @Test("""
@spec GIT-4.7: When the application first observes a worktree's associated pull request transition into the merged state — whether from open, from no-PR-cached, or from a different previously-merged PR number — the application shall present an informational dialog offering to delete the worktree. The dialog's message text shall cite the PR number, its informative text shall read "Delete the worktree now? This will delete the worktree but not the branch.", and its buttons shall be "Delete Worktree" and "Keep".
""", .disabled("not yet implemented"))
    func git_4_7() async throws { }

    @Test("""
@spec GIT-4.8: If the user confirms the offer dialog from GIT-4.7 by clicking "Delete Worktree", the application shall proceed directly to `git worktree remove` without re-prompting — the offer dialog IS the confirmation. The resulting success and failure paths shall be identical to GIT-4.5 and GIT-4.4 (teardown on success, stderr surfaced on failure).
""", .disabled("not yet implemented"))
    func git_4_8() async throws { }

    @Test("""
@spec GIT-4.9: The application shall offer the dialog described in GIT-4.7 at most once per (worktree, PR-number) pair, by persisting the offered PR number on the worktree entry. On a subsequent poll that still reports the same merged PR, on an app restart that re-resolves the same already-merged PR, or if the user dismisses the dialog with "Keep", the application shall not re-offer until the worktree's PR number changes. The application shall not present this dialog for the repository's main checkout (GIT-4.1 forbids deleting it) nor for worktrees in the stale state.
""", .disabled("not yet implemented"))
    func git_4_9() async throws { }

    @Test("""
@spec GIT-4.10: When `git worktree remove` succeeds (via either the menu-initiated Delete Worktree path per GIT-4.3 or the PR-merged offer path per GIT-4.8), the application shall drop the worktree's cached entries from every per-path observable store (PR status, divergence stats) before removing the entry from the model. Matches the contract GIT-3.6's Dismiss path already enforces — without it, orphan cache entries survive indefinitely and bleed into a future same-path re-add on its first reconcile tick.
""", .disabled("not yet implemented"))
    func git_4_10() async throws { }

    @Test("""
@spec GIT-4.11: When `performDeleteWorktree` fails with a non-`gitFailed` error (git binary missing, subprocess launch failure, timeout), the application shall surface the error in an `NSAlert` analogous to `GIT-4.4`, not silently return. Without this, the user clicks Delete Worktree and nothing happens — matches the shape of the cycle 101 `addRepoFromPath` (GIT-1.2) silent-failure fix, on the symmetric delete path.
""", .disabled("not yet implemented"))
    func git_4_11() async throws { }

    @Test("""
@spec GIT-5.1: When the user types or pastes into the "Worktree name" or "Branch" field of the Add Worktree sheet, the application shall replace any character outside the set `A-Z a-z 0-9 . _ - /` with `-`, and shall collapse any run of consecutive `-` (including dashes the user typed directly) into a single `-`. `/` is permitted so branch names can use the conventional namespace separator (`feature/foo`); the resulting worktree path becomes a nested `.worktrees/<ns>/<leaf>` directory that `git worktree add` creates. Ref-format rules git already enforces (`//`, leading/trailing `/`, components beginning with `.`) are not duplicated here — git reports them at submit time. The replacement shall apply live on every edit so the field shows only sanitized content.
""", .disabled("not yet implemented"))
    func git_5_1() async throws { }

    @Test("""
@spec GIT-5.2: While the branch field is still mirroring the worktree name (i.e. the user has not manually diverged the branch field), the sanitized worktree name shall be propagated into the branch field on each edit so both fields stay in sync.
""", .disabled("not yet implemented"))
    func git_5_2() async throws { }

    @Test("""
@spec GIT-5.3: When the user submits the Add Worktree sheet, the application shall additionally strip leading and trailing `-`, `.`, and whitespace from both values before invoking `git worktree add`. Live editing intentionally preserves those characters (trimming them as-you-type would swallow the separator between words); the final submit trim ensures no request ever asks git to create `-foo` or `foo.` as a branch.
""", .disabled("not yet implemented"))
    func git_5_3() async throws { }

    @Test("""
@spec GIT-5.4: When the user submits the Add Worktree sheet and validation passes (the target repository is still tracked and no entry already exists at `<repoPath>/.worktrees/<name>`), the application shall (a) insert a placeholder `WorktreeEntry` for the target path in the `.creating` state, (b) dismiss the sheet immediately, and (c) run `git worktree add` in a detached `Task` so a slow git invocation — typically blocked on `pre-commit` / `post-checkout` hooks that can take seconds — does not hold the sheet open. Without this, the sheet's `ProgressView` would block all sidebar interaction for the duration of the hook chain.
""", .disabled("not yet implemented"))
    func git_5_4() async throws { }

    @Test("""
@spec GIT-5.5: While a worktree entry is in the `.creating` state, the sidebar row shall render a `ProgressView` in place of its type icon (`house` / `arrow.triangle.branch` / `arrow.triangle.pull`), shall suppress the divergence-stats gutter (no on-disk repo to diff against), shall hide pane title rows beneath it (no surfaces exist yet), and shall present an empty right-click context menu (Stop, Delete Worktree, Open in Finder would all either error or race the in-flight create). A click on the row shall be a no-op for selection purposes — the user keeps their previous worktree focused — until the placeholder transitions out of `.creating`.
""", .disabled("not yet implemented"))
    func git_5_5() async throws { }

    @Test("""
@spec GIT-5.6: When `git worktree add` started by `GIT-5.4` succeeds, the application shall (a) adopt git's resolved branch label onto the placeholder, (b) arm the path / HEAD-reflog / content watchers and seed divergence stats for the new path, (c) spawn the first terminal surface, (d) transition the entry from `.creating` to `.running`, and (e) flip `selectedWorktreePath` to the new worktree so the user ends up focused on it (matching the pre-optimistic flow's "submit → ends up on new worktree" outcome).
""", .disabled("not yet implemented"))
    func git_5_6() async throws { }

    @Test("""
@spec GIT-5.7: When `git worktree add` started by `GIT-5.4` fails, the application shall (a) remove the `.creating` placeholder from the sidebar and (b) present an `NSAlert` titled "Could not create worktree" whose informative text shows git's stderr (or "git worktree add failed" when stderr is empty). Inline error display in the sheet is no longer reachable since `GIT-5.4` already dismissed the sheet on submit. Mirrors `GIT-1.2` / `GIT-4.4` / `GIT-4.11`'s alert-not-silent-return policy on the symmetric create path.
""", .disabled("not yet implemented"))
    func git_5_7() async throws { }

    @Test("""
@spec GIT-5.9: When persisting `WorktreeEntry` to `state.json`, the application shall encode `.creating` as `.closed`. The `.creating` state is in-memory-only; if the app crashes mid-creation, the next launch's reconciler classifies the entry from `git worktree list --porcelain` rather than restoring a phantom spinner that would never resolve.
""", .disabled("not yet implemented"))
    func git_5_9() async throws { }
}
