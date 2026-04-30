// Auto-generated inventory of unimplemented specs in this section.
// Promote a @Test(.disabled(...)) entry to a real @Test in a *Tests.swift
// file before implementing the behavior, then delete the entry from this
// inventory file. SPECS.md is regenerated from these markers by
// scripts/generate-specs.py.

import Testing

@Suite("PR — pending specs")
struct PrTodo {
    @Test("""
@spec PR-1.2: If more than one PR in the same repository matches the worktree's branch and state, the application shall associate the worktree with the most recently created one.
""", .disabled("not yet implemented"))
    func pr_1_2() async throws { }

    @Test("""
@spec PR-2.1: When a worktree's HEAD reference changes (per GIT-2.4), the application shall drop the worktree's previously cached PR display synchronously and shall trigger a fresh PR resolution for the new branch — rather than waiting for the next polling tick to discover the change. This prevents the previous branch's PR from continuing to display through the polling cadence window after a `git checkout`, rebase, or other HEAD-rewriting operation.
""", .disabled("not yet implemented"))
    func pr_2_1() async throws { }

    @Test("""
@spec PR-2.2: When the application observes an origin-ref change for a repository (per GIT-2.5), the application shall trigger a fresh PR resolution for every non-stale worktree in that repository whose branch is fetchable. This catches the `gh pr create` / `git push` flow — neither moves local HEAD, so PR-2.1 doesn't fire, and without this trigger the user would wait up to the full `absent` polling cadence before a newly-opened PR appears in the sidebar.
""", .disabled("not yet implemented"))
    func pr_2_2() async throws { }

    @Test("""
@spec PR-3.1: While a worktree has a resolved PR/MR (open or merged), its sidebar row shall use the SF Symbol `arrow.triangle.pull` as its leading icon in place of the default `arrow.triangle.branch` (linked worktree) or `house` (main checkout) glyph. The icon's color shall continue to encode the worktree's running state (closed / running / stale) per existing behavior; the leading-icon change communicates only the PR's existence, while detailed PR state (number, title, check status) remains in the breadcrumb's PR button.
""", .disabled("not yet implemented"))
    func pr_3_1() async throws { }

    @Test("""
@spec PR-3.2: While a worktree has a resolved PR/MR, its sidebar row shall display a `#<number>` badge between the leading icon and the branch label. The badge text shall be colored using the PR's state color: green for open, purple for merged. While the PR is open, the CI verdict from `PR-3.5` overrides the open-state green.
""", .disabled("not yet implemented"))
    func pr_3_2() async throws { }

    @Test("""
@spec PR-3.3: The `#<number>` sidebar badge shall be a tappable button that opens the PR URL in the system browser when clicked. Clicking the badge shall not trigger the row's worktree-selection action.
""", .disabled("not yet implemented"))
    func pr_3_3() async throws { }

    @Test("""
@spec PR-3.4: The `#<number>` sidebar badge shall have an accessibility label of the form "Pull request `<number>`, open/merged[, CI failing|CI running]. Click to open in browser." and a tooltip showing "Open #`<number>` on `<host>`". The CI suffix is appended only when the CI tone is `ciFailure` or `ciPending` per `PR-3.5`.
""", .disabled("not yet implemented"))
    func pr_3_4() async throws { }

    @Test("""
@spec PR-3.5: While a worktree's PR/MR is open, the `#<number>` sidebar badge text shall be colored to reflect CI state, overriding the open-state green: red (matching the breadcrumb PR-button failure dot, RGB ~0.97/0.32/0.29) when the latest checks verdict is `failure`, orange (matching the pending dot, RGB ~0.82/0.60/0.13) and pulsing in opacity when the verdict is `pending`. A `success` or absent (`none`) verdict shall keep the open-state green so repos without CI do not lose the open-vs-merged signal. While the PR is merged, the badge shall remain purple regardless of the CI verdict, since CI status on a merged PR is stale and would distract from the actionable signal on still-open PRs.
""", .disabled("not yet implemented"))
    func pr_3_5() async throws { }

    @Test("""
@spec PR-4.1: The application shall resolve the hosting origin for a repository by running `git remote get-url origin` in the repository's path and parsing the returned URL. Both scp-style (`git@<host>:<owner>/<repo>`) and HTTP(S)/SSH URLs (`https://<host>/<owner>/<repo>`, `ssh://<host>/<owner>/<repo>`) shall be accepted; `file://`, `git://`, and bare local paths shall resolve to no origin.
""", .disabled("not yet implemented"))
    func pr_4_1() async throws { }

    @Test("""
@spec PR-4.2: Hosts whose name is `github.com`, ends in `.github.com`, or begins with `github.` shall classify as provider `github`. Hosts whose name is `gitlab.com`, ends in `.gitlab.com`, or begins with `gitlab.` shall classify as provider `gitlab`. Any other host shall classify as `unsupported`.
""", .disabled("not yet implemented"))
    func pr_4_2() async throws { }

    @Test("""
@spec PR-4.3: For worktrees belonging to a repository whose origin resolves to an `unsupported` provider or to no origin at all, the application shall not attempt PR fetches and shall not display a PR badge.
""", .disabled("not yet implemented"))
    func pr_4_3() async throws { }

    @Test("""
@spec PR-5.1: For GitHub origins, the application shall fetch open PRs via `gh pr list --repo <owner>/<repo> --head <branch> --state open --limit 5 --json number,title,url,state,headRefName,headRepositoryOwner` and take the first result whose `headRepositoryOwner.login` matches the origin owner. Merged PRs shall use the same shape with `--state merged` and the additional `mergedAt` JSON field. The limit is 5 (rather than 1) so a fork PR returned first by `gh`'s default sort cannot crowd out a same-repo PR that the owner filter would otherwise accept.
""", .disabled("not yet implemented"))
    func pr_5_1() async throws { }

    @Test("""
@spec PR-5.2: For GitHub origins, the application shall fetch per-check status via `gh pr checks <number> --repo <owner>/<repo> --json name,state,bucket`. The `bucket` field (values `pass`/`fail`/`pending`/`skipping`/`cancel`) is the canonical verdict; `conclusion` is not a field `gh` emits from this command.
""", .disabled("not yet implemented"))
    func pr_5_2() async throws { }

    @Test("""
@spec PR-5.3: For GitLab origins, the application shall fetch merge requests via `glab mr list --repo <path> --source-branch <branch> --per-page 5 -F json` (appending `--merged` for the merged-state sweep; the default list is opened-only) and take the first result whose `source_project_id` equals its `target_project_id`. Pipeline status for an opened MR comes from a separate `glab mr view <iid> --repo <path> -F json` call and is derived from the returned `head_pipeline.status` — the MR list endpoint (backing `glab mr list`) does not populate `head_pipeline`, only the single-MR view does. glab's earlier string-valued `--state <opened|merged>` flag was removed upstream; invocations that still carry it fail with "Unknown flag: --state" and yield no MR at all, which is why the flag-based spelling above is load-bearing. The per-page bound is 5 (rather than 1) so a fork MR returned first by glab's default sort cannot crowd out a same-repo MR that the source/target project-id filter would otherwise accept — parity with the GitHub-side fork defense in `PR-5.1`. An MR whose project IDs cannot be verified (both fields absent in the response) is excluded rather than accepted, for the same reason the GitHub filter excludes PRs with a missing `headRepositoryOwner`. If the `mr view` pipeline-status call fails after `mr list` succeeded, the MR is still surfaced with `.none` checks rather than dropping the whole `PRInfo` — parity with `PR-5.4`.
""", .disabled("not yet implemented"))
    func pr_5_3() async throws { }

    @Test("""
@spec PR-6.1: A PR's overall check status shall roll up its individual check buckets as follows: any `fail` → `.failure`; any `pending` bucket or any in-flight state (`IN_PROGRESS`, `QUEUED`, `PENDING`) → `.pending`; all-`pass` → `.success`; anything else (including `skipping`, `cancel`, or unclassified) → `.none` (neutral).
""", .disabled("not yet implemented"))
    func pr_6_1() async throws { }

    @Test("""
@spec PR-6.2: When a PR has no checks, its overall status shall be `.none`.
""", .disabled("not yet implemented"))
    func pr_6_2() async throws { }

    @Test("""
@spec PR-7.1: The application shall poll a worktree's PR status on a tiered cadence: 10 seconds while the PR's checks are `.pending`, and 30 seconds otherwise — a known PR with non-pending checks (open passing/failing, or merged), or a worktree observed to have no associated PR (absent). The pending-tier tightening exists because users are actively watching CI for the green/red transition and the 30-second baseline produces visible "I just pushed, why hasn't it gone green yet" staleness during a CI run. The 30-second baseline applies elsewhere because polling is the sole detection channel for an open→merged transition that lands on the hosting provider without a local `git fetch` (`watchOriginRefs` per GIT-2.5 catches local push/fetch but is blind to remote-only events), and a slower cadence directly surfaces as user-visible staleness in the sidebar badge and breadcrumb PR button.
""", .disabled("not yet implemented"))
    func pr_7_1() async throws { }

    @Test("""
@spec PR-7.2: When a fetch for a worktree fails, the application shall apply exponential backoff to its cadence: the base interval (or 60s if the base is zero) shall be doubled for each consecutive failure up to a shift of 5, capped at 60 seconds. The cap is intentionally tight because `PR-7.10` preserves the last-known `PRInfo` on failure — without a tight cap, a run of transient `gh` failures would silently freeze the breadcrumb on data that has drifted minutes-to-hours out of date with no visual cue, since the cached info looks settled and confident even though its scheduled refresh has been pushed far into the future.
""", .disabled("not yet implemented"))
    func pr_7_2() async throws { }

    @Test("""
@spec PR-7.3: The application shall not poll worktrees whose branch is a git sentinel value (`(detached)`, `(bare)`, `(unknown)`, any other parenthesized value, or empty / whitespace-only), since none of these correspond to a real ref that a hosting provider can associate with a PR.
""", .disabled("not yet implemented"))
    func pr_7_3() async throws { }

    @Test("""
@spec PR-7.4: The application shall not poll stale worktrees.
""", .disabled("not yet implemented"))
    func pr_7_4() async throws { }

    @Test("""
@spec PR-7.5: `PRStatusStore.refresh` and `PRStatusStore.branchDidChange` shall also apply the `PR-7.3` sentinel-branch gate, not just the background polling loop. Otherwise an on-demand refresh (sidebar selection, HEAD-change event) against a detached / bare / unknown worktree still fires two wasted `gh pr list --head <sentinel>` invocations per event — the gate belongs at the fetch entry point, not duplicated at every caller.
""", .disabled("not yet implemented"))
    func pr_7_5() async throws { }

    @Test("""
@spec PR-7.6: The PR polling ticker shall continue to fire while Graftty is not the frontmost application. `gh pr list` is the only detection channel for an open→merged transition that happens on GitHub without a local `git fetch`; pausing while the app is backgrounded leaves the sidebar's PR badge stuck on "open" until the user clicks back into Graftty, even though the merge may have happened many minutes earlier. The cost (one `gh pr list` per worktree every 10–30 seconds depending on the `PR-7.1` tier) is negligible compared to the staleness it would otherwise produce.
""", .disabled("not yet implemented"))
    func pr_7_6() async throws { }

    @Test("""
@spec PR-7.9: When `PRStatusStore.refresh` schedules a fetch, it shall snapshot the worktree's per-path generation counter synchronously at scheduling time (not inside the spawned Task). A subsequent `branchDidChange` between the original `refresh` and when its spawned Task actually starts running would otherwise let the stale Task snapshot the post-bump generation and pass its post-await check — allowing the prior branch's still-in-flight fetch to write over the new branch's freshly-landed result when the network returns them out of order.
""", .disabled("not yet implemented"))
    func pr_7_9() async throws { }

    @Test("""
@spec PR-7.11: When host detection (`GitOriginHost.detect` or equivalent) throws for a repository — process launch failure, git binary missing from PATH, etc. — the application shall not cache the failure in the `hostByRepo` map. Only successful detections (whether returning a resolved `HostingOrigin` or a legitimate "no origin remote" nil) shall be cached. Otherwise a transient environment glitch at first fetch poisons the repo's PR tracking for the whole session, since the poll tick skips cached-nil repos and no code path re-attempts detection.
""", .disabled("not yet implemented"))
    func pr_7_11() async throws { }
}
