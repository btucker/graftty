---
name: graftty-ci
description: Investigate CI failures for the current worktree's pull request, including Graftty forge failure notices, and follow fixes until the replacement run finishes.
---

# Graftty CI

Use this skill when the user reports a CI failure or Graftty delivers a CI failure notice in a `<graftty-forge-message>`. The notice reports a status transition, not a run ID or proof that the failure is still current. Several transitions may arrive together after a reconnect.

Identify the current PR, branch, and commit before acting. Check the forge's live status and match the failing run to the PR head. For GitHub, `gh pr view`, `gh pr checks`, and `gh run view <run-id>` provide this context. If the current head has a newer run, use that run; do not diagnose an old failure as though it were current. If the current checks have passed, report that and stop.

For a current failure:

1. Inspect the failed job and its logs. On GitHub, `gh run view <run-id> --log-failed` is a starting point; open the specific job log when that output omits the cause. Distinguish a product regression from an unrelated runner or service failure using the actual error.
2. Reproduce the failure when practical, make the smallest fix within the user's authorized work, and run the relevant local checks. Follow repository instructions for tests, generated files, review, and commits. Do not rerun CI merely to hide a deterministic failure.
3. Push the fix when the task authorizes updating that PR. Confirm that the new run belongs to the pushed head commit. Watch every required check through its final state, including aggregate jobs that start after their shards. A pending or queued check is not a pass.
4. If the replacement run fails, inspect that failure and continue. Stop when the current head is green or when a concrete blocker prevents further work. Report the PR, final head, check result, and any remaining limitation.

Use the forge's equivalent commands for non-GitHub repositories. A forge notice has no peer reply address; report progress to the user in the current conversation.
