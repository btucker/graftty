# Stale worktree registry cleanup — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `(detached)` worktree rows whose on-disk directory has been removed cleanable from the sidebar — by detecting the stale-registry failure mode in `performDeleteWorktree`, running `git worktree prune --expire=now`, and dropping the row without forcing the user through a useless Force Delete dialog.

**Architecture:** Tiny refactor (extract the post-remove teardown into a private helper so the success path and the new missing-directory branch share it), then a new ~15-line `GitWorktreePrune.swift` subprocess wrapper alongside `GitWorktreeRemove.swift`, then a single new conditional branch in `performDeleteWorktree`'s `catch gitFailed` arm that runs prune + the shared teardown when the directory is missing on disk. GIT-4.13 captures the new behavior; the existing Force Delete path (GIT-4.4 / GIT-4.12) is untouched.

**Tech Stack:** Swift Concurrency, Swift Testing, AppKit/SwiftUI, git CLI via `GitRunner.captureAll`.

---

## Task 1 — Extract post-remove teardown helper

`performDeleteWorktree`'s success path and the upcoming missing-directory branch perform identical work (terminal teardown → cache clears → `appState.removeWorktree` → `TeamMembershipEvents.fireLeft`). Extract it into a private helper before adding the new branch so the new code doesn't duplicate the 20-line block.

**No behavior change.** Existing tests should remain green; this is preparation only.

**Files:**
- Modify: `Sources/Graftty/Views/MainWindow.swift:622-712` (only the `performDeleteWorktree` method)

- [ ] **Step 1: Add the new private helper directly below `performDeleteWorktree`**

Insert this method immediately after the closing brace of `performDeleteWorktree` (currently around line 712). Place it BEFORE `stopWorktreeWithConfirmation` so deletion-related helpers cluster together.

```swift
/// Shared post-remove teardown used by both the normal success path
/// and the GIT-4.13 stale-registry recovery branch. Tears down live
/// terminal surfaces, clears per-path caches, drops the model entry,
/// then fires the TEAM-5.3 `left` event so the lead is notified the
/// worktree is gone. Runs on the MainActor.
@MainActor
private func finishWorktreeRemoval(
    worktree wt: WorktreeEntry,
    worktreePath: String,
    repoPath: String
) {
    if wt.state == .running {
        terminalManager.destroySurfaces(terminalIDs: wt.splitTree.allLeaves)
    }
    // GIT-4.10: drop per-path caches BEFORE removing the model entry.
    // Same reason `dismissWorktree` (GIT-3.6) does: orphan cache entries
    // survive indefinitely and bleed into a future same-path re-add.
    prStatusStore.clear(worktreePath: worktreePath)
    statsStore.clear(worktreePath: worktreePath)
    // Capture the branch before the entry is removed so `fireLeft` can
    // build the member name from it.
    let leaverBranch = wt.branch
    appState.removeWorktree(atPath: worktreePath)
    // TEAM-5.3: notify the lead that a worktree left. The repo state is
    // read AFTER removal so the lead-present guard works.
    if let repo = appState.repo(forWorktreePath: repoPath) {
        TeamMembershipEvents.fireLeft(
            repo: repo,
            leaverBranch: leaverBranch,
            leaverPath: worktreePath,
            reason: .removed,
            teamsEnabled: UserDefaults.standard.bool(forKey: SettingsKeys.agentTeamsEnabled),
            dispatcher: teamEventDispatcher
        )
    }
}
```

- [ ] **Step 2: Replace the inline success-path teardown with a call to the helper**

Inside `performDeleteWorktree`, the success block currently spans lines 684–710. Replace those lines with a single call. The full success block becomes:

```swift
            finishWorktreeRemoval(worktree: wt, worktreePath: worktreePath, repoPath: repoPath)
        }
    }
```

The replaced lines are everything from `if wt.state == .running {` (684) through the closing brace of the `if let repo = appState.repo(...)` block at line 710. Do NOT touch the `} catch GitWorktreeRemove.Error.gitFailed` arm (lines 646–668) or the `catch` arm at lines 669–682 in this task; they get the new branch in Task 3.

- [ ] **Step 3: Build and run full test suite to confirm zero behavior change**

Run: `swift test 2>&1 | tail -40`
Expected: same green/red as `main` — no new failures, no removed tests.

- [ ] **Step 4: Commit**

```bash
git add Sources/Graftty/Views/MainWindow.swift
git commit -m "$(cat <<'EOF'
refactor: extract finishWorktreeRemoval helper in MainWindow

Pulls the success-path teardown (terminal destroy → cache clear →
removeWorktree → fireLeft) out of performDeleteWorktree so the
upcoming GIT-4.13 stale-registry branch can share it without copying
the 20-line block.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 2 — Add `GitWorktreePrune` subprocess wrapper (TDD)

Mirror of `GitWorktreeRemove.swift`: thin async wrapper, structured `gitFailed` error, no UI concerns. Tested at the git-CLI level using the same fixture pattern as `GitWorktreeRemoveTests`. The behavioral spec GIT-4.13 is annotated on the prune-clears-stale-entry test so it shows up in `SPECS.md`.

**Files:**
- Create: `Sources/GrafttyKit/Git/GitWorktreePrune.swift`
- Test: `Tests/GrafttyKitTests/Git/GitWorktreePruneTests.swift`

- [ ] **Step 1: Write the failing test**

Create `Tests/GrafttyKitTests/Git/GitWorktreePruneTests.swift` with the following exact content:

```swift
import Testing
import Foundation
@testable import GrafttyKit

@Suite("GitWorktreePrune Tests", .serialized)
struct GitWorktreePruneTests {

    /// @spec GIT-4.13: When the user confirms Delete Worktree on a worktree whose directory no longer exists on disk, the application shall run `git worktree prune --expire=now`, drop the worktree entry from the sidebar without prompting the user with a Force Delete alert, and tear down any running terminal surfaces for the entry.
    ///
    /// This test exercises the git-level half of the requirement: that
    /// `prune --expire=now` against a repo with an orphaned
    /// `.git/worktrees/<name>` entry (directory gone but admin dir still
    /// present) successfully removes the admin dir. The UI-glue half
    /// (calling this from `performDeleteWorktree`'s missing-directory
    /// branch and then `finishWorktreeRemoval`) is verified manually
    /// against the running app, matching the convention used for
    /// `performDeleteWorktree`'s other branches.
    @Test("""
@spec GIT-4.13: When the user confirms Delete Worktree on a worktree whose directory no longer exists on disk, the application shall run `git worktree prune --expire=now`, drop the worktree entry from the sidebar without prompting the user with a Force Delete alert, and tear down any running terminal surfaces for the entry.
""")
    func pruneRemovesOrphanedAdminEntry() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("graftty-prune-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let repoDir = dir.appendingPathComponent("repo")
        try FileManager.default.createDirectory(at: repoDir, withIntermediateDirectories: true)
        let worktreeDir = dir.appendingPathComponent("wt-feature")

        try runShell("""
            git init && \
            git commit --allow-empty -m 'init' && \
            git worktree add \(worktreeDir.path) -b feature
            """, at: repoDir)

        // Simulate the stale-registry condition: directory gone, admin
        // entry still present. This is what agent tooling produces when
        // it rm -rfs its scratch worktree without calling
        // `git worktree remove`.
        try FileManager.default.removeItem(at: worktreeDir)
        let adminEntry = repoDir.appendingPathComponent(".git/worktrees/wt-feature")
        #expect(FileManager.default.fileExists(atPath: adminEntry.path))

        try await GitWorktreePrune.run(repoPath: repoDir.path)

        #expect(!FileManager.default.fileExists(atPath: adminEntry.path))
    }

    /// `git worktree prune` is well-defined on a repo that has no
    /// prunable entries — exits 0 with empty stderr. Verifying the
    /// no-op shape so the UI's best-effort call (`try?`) does not
    /// silently mask a legitimate error.
    @Test func pruneNoopOnCleanRepo() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("graftty-prune-noop-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let repoDir = dir.appendingPathComponent("repo")
        try FileManager.default.createDirectory(at: repoDir, withIntermediateDirectories: true)
        try runShell("git init && git commit --allow-empty -m 'init'", at: repoDir)

        try await GitWorktreePrune.run(repoPath: repoDir.path)
    }

    /// A non-git path raises `gitFailed` rather than a launch error —
    /// `git` itself exits non-zero with a populated stderr.
    @Test func pruneFailsOnNonGitPath() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("graftty-prune-bad-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        do {
            try await GitWorktreePrune.run(repoPath: dir.path)
            Issue.record("expected gitFailed for non-git directory")
        } catch GitWorktreePrune.Error.gitFailed(let code, let stderr) {
            #expect(code != 0)
            #expect(!stderr.isEmpty)
        }
    }

    private func runShell(_ command: String, at directory: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-c", command]
        process.currentDirectoryURL = directory
        process.environment = [
            "PATH": "/usr/bin:/bin:/usr/local/bin",
            "HOME": NSHomeDirectory(),
            "GIT_AUTHOR_NAME": "Test",
            "GIT_AUTHOR_EMAIL": "test@test.com",
            "GIT_COMMITTER_NAME": "Test",
            "GIT_COMMITTER_EMAIL": "test@test.com",
        ]
        try process.run()
        process.waitUntilExit()
    }
}
```

- [ ] **Step 2: Run the test, expect compile failure**

Run: `swift test --filter GitWorktreePruneTests 2>&1 | tail -20`
Expected: compilation error referring to `GitWorktreePrune` (the type does not exist yet). This confirms the test is wired to the not-yet-built type.

- [ ] **Step 3: Create the implementation**

Create `Sources/GrafttyKit/Git/GitWorktreePrune.swift` with this exact content:

```swift
import Foundation

/// Prunes stale `.git/worktrees/<name>` administrative entries whose
/// working-tree directories no longer exist on disk. Used by the
/// GIT-4.13 recovery path in `performDeleteWorktree` when
/// `git worktree remove` fails because the worktree directory is gone
/// (typical when agent tooling tears down scratch worktrees without
/// calling `git worktree remove` first).
///
/// `--expire=now` is required: a bare `git worktree prune` honors
/// `gc.worktreePruneExpire` (default 3 months) and would no-op on
/// recently-orphaned entries.
///
/// `prune` operates on the whole repo, not a single path — every
/// stale entry in the repo is pruned by one invocation. That matches
/// GIT-4.13's UX intent (the user wanted the dead row gone; other
/// dead rows in the same repo are also dead and should disappear).
public enum GitWorktreePrune {

    public enum Error: Swift.Error, Equatable {
        case gitFailed(exitCode: Int32, stderr: String)
    }

    public static func run(repoPath: String) async throws {
        let result = try await GitRunner.captureAll(
            args: ["worktree", "prune", "--expire=now"],
            at: repoPath
        )
        guard result.exitCode == 0 else {
            throw Error.gitFailed(
                exitCode: result.exitCode,
                stderr: result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
    }
}
```

- [ ] **Step 4: Run the tests, expect pass**

Run: `swift test --filter GitWorktreePruneTests 2>&1 | tail -20`
Expected: 3 tests pass (`pruneRemovesOrphanedAdminEntry`, `pruneNoopOnCleanRepo`, `pruneFailsOnNonGitPath`).

- [ ] **Step 5: Run the full test suite for regressions**

Run: `swift test 2>&1 | tail -40`
Expected: all tests pass — no GitWorktreeRemove or other tests regressed.

- [ ] **Step 6: Commit**

```bash
git add Sources/GrafttyKit/Git/GitWorktreePrune.swift Tests/GrafttyKitTests/Git/GitWorktreePruneTests.swift
git commit -m "$(cat <<'EOF'
feat(git): add GitWorktreePrune wrapper for GIT-4.13

Thin async wrapper around `git worktree prune --expire=now`, mirroring
GitWorktreeRemove's shape. Used in the next commit by the
performDeleteWorktree stale-registry recovery branch. `--expire=now`
is required because the default `gc.worktreePruneExpire` is 3 months.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 3 — Wire the missing-directory branch into `performDeleteWorktree`

Add a single new conditional inside the `catch GitWorktreeRemove.Error.gitFailed` arm of `performDeleteWorktree`. When the worktree's directory does not exist on disk, run prune (best-effort) and call `finishWorktreeRemoval` instead of falling through to the Force Delete alert.

**Files:**
- Modify: `Sources/Graftty/Views/MainWindow.swift` (inside `performDeleteWorktree`, the `gitFailed` catch arm)

- [ ] **Step 1: Add the new conditional at the top of the `gitFailed` catch arm**

In `performDeleteWorktree`, the `catch GitWorktreeRemove.Error.gitFailed(_, let stderr)` block begins around line 646. Insert this guard as the FIRST statement of that catch block, BEFORE the `if force { ... }` check:

```swift
            } catch GitWorktreeRemove.Error.gitFailed(_, let stderr) {
                // GIT-4.13: directory is gone but the admin entry survives.
                // --force can't bypass git's path validation, so the Force
                // Delete dialog is a dead end for this case. Run prune to
                // clean the orphaned `.git/worktrees/<name>` and drop the
                // row via the shared teardown.
                if !FileManager.default.fileExists(atPath: worktreePath) {
                    try? await GitWorktreePrune.run(repoPath: repoPath)
                    finishWorktreeRemoval(worktree: wt, worktreePath: worktreePath, repoPath: repoPath)
                    return
                }
                if force {
                    // Already attempted with --force; nothing left to
                    // offer. Match the original GIT-4.4 single-button
                    // shape so we don't trap the user in retry loops.
                    let errorAlert = NSAlert()
                    /* ... existing body unchanged ... */
                    /* ... existing body unchanged ... */
                }
                // GIT-4.4. (existing body unchanged)
                /* ... existing body unchanged ... */
```

The full final shape of the catch arm should look like this (do NOT alter the existing inner content of either `if force { ... }` or the GIT-4.4 fall-through; only INSERT the new guard at the top):

```swift
            } catch GitWorktreeRemove.Error.gitFailed(_, let stderr) {
                // GIT-4.13: directory is gone but the admin entry survives.
                // --force can't bypass git's path validation, so the Force
                // Delete dialog is a dead end for this case. Run prune to
                // clean the orphaned `.git/worktrees/<name>` and drop the
                // row via the shared teardown.
                if !FileManager.default.fileExists(atPath: worktreePath) {
                    try? await GitWorktreePrune.run(repoPath: repoPath)
                    finishWorktreeRemoval(worktree: wt, worktreePath: worktreePath, repoPath: repoPath)
                    return
                }
                if force {
                    // Already attempted with --force; nothing left to
                    // offer. Match the original GIT-4.4 single-button
                    // shape so we don't trap the user in retry loops.
                    let errorAlert = NSAlert()
                    errorAlert.messageText = "Could not delete worktree"
                    errorAlert.informativeText = stderr.isEmpty ? "git worktree remove --force failed" : stderr
                    errorAlert.alertStyle = .warning
                    errorAlert.runModal()
                    return
                }
                // GIT-4.4.
                let status = await GitStatusCapture.shortStatus(at: worktreePath)
                let errorAlert = NSAlert()
                errorAlert.messageText = "Could not delete worktree"
                errorAlert.informativeText = ForceDeleteAlert.informativeText(stderr: stderr, status: status)
                errorAlert.alertStyle = .warning
                errorAlert.addButton(withTitle: "Cancel")
                errorAlert.addButton(withTitle: "Force Delete")
                guard errorAlert.runModal() == .alertSecondButtonReturn else { return }
                performDeleteWorktree(worktreePath, force: true)
                return
```

- [ ] **Step 2: Build and run full test suite**

Run: `swift test 2>&1 | tail -40`
Expected: every test still passes; no compile errors. The new branch isn't directly tested at the UI level (matches the convention for `performDeleteWorktree`'s other branches), but the GIT-4.13 spec test in `GitWorktreePruneTests` exercises the git-side guarantee.

- [ ] **Step 3: Regenerate SPECS.md**

Run: `scripts/generate-specs.py`
Expected: `SPECS.md` is updated. Diff should show:
- A new `**GIT-4.13** When the user confirms Delete Worktree on a worktree whose directory no longer exists ...` entry in the GIT-4.x section.

If `scripts/generate-specs.py --check` fails, that means the prior `swift test` run somehow generated stale or duplicate spec annotations — re-read both Task 2 Step 1 and Task 3 Step 1 to confirm the `@spec GIT-4.13` text appears exactly once across the codebase and that the GIT-4.13 entry was NOT added to `Tests/GrafttyTests/Specs/GitTodo.swift` (it's implemented now, so it goes directly on the real `@Test`, not in the `*Todo.swift` inventory).

- [ ] **Step 4: Commit**

```bash
git add Sources/Graftty/Views/MainWindow.swift SPECS.md
git commit -m "$(cat <<'EOF'
feat(worktree): silently recover stale registry entries (GIT-4.13)

When the user clicks Delete Worktree on a row whose on-disk directory
has been removed (typical when agent tooling — Codex, Claude Code —
tears down scratch worktrees without calling `git worktree remove`),
the existing Force Delete dialog is a dead end: `--force` does not
bypass git's path validation. The user is stuck.

Detect that case in performDeleteWorktree's gitFailed branch by
stat'ing the directory. If it's missing, run
`git worktree prune --expire=now` against the repo and drop the row
via the shared teardown helper. The Force Delete dialog only fires
for its intended dirty-files case from here on.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Self-review checklist (run before handing off)

- [ ] **Spec coverage:** GIT-4.13 has one real `@Test` (in `GitWorktreePruneTests.swift`); no duplicate annotation in `GitTodo.swift`. The behavior described in the spec design doc maps to Tasks 1+3 (helper + missing-dir branch) plus Task 2 (the git-level prune wrapper exercised by the test).
- [ ] **Placeholder scan:** none. Every step has executable code/commands.
- [ ] **Type consistency:** `finishWorktreeRemoval(worktree:worktreePath:repoPath:)`, `GitWorktreePrune.run(repoPath:)`, `GitWorktreePrune.Error.gitFailed(exitCode:stderr:)` — all signatures defined in one place and referenced consistently.
- [ ] **No-goal guard:** the plan does NOT relabel `(detached)` rows whose directory exists, does NOT add a `(missing)` sentinel, does NOT auto-prune on every discovery — all explicitly scoped out per the design doc's "Non-goals" section.
