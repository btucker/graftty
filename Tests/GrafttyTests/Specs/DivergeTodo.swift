// Auto-generated inventory of unimplemented specs in this section.
// Promote a @Test(.disabled(...)) entry to a real @Test in a *Tests.swift
// file before implementing the behavior, then delete the entry from this
// inventory file. SPECS.md is regenerated from these markers by
// scripts/generate-specs.py.

import Testing

@Suite("DIVERGE — pending specs")
struct DivergeTodo {
    @Test("""
@spec DIVERGE-1.1: Each worktree entry in the sidebar shall display a trailing-aligned divergence indicator, placed to the left of the attention badge (or at the trailing edge when no attention badge is present).
""", .disabled("not yet implemented"))
    func diverge_1_1() async throws { }

    @Test("""
@spec DIVERGE-1.2: The indicator shall display zero, one, or both of the following on a single line, separated by a single space when both are present:
""", .disabled("not yet implemented"))
    func diverge_1_2() async throws { }

    @Test("""
@spec DIVERGE-1.3: On hover, the indicator shall surface a system tooltip containing the insertion/deletion line counts in the form `+<I> -<D> lines` (with zero sides omitted), optionally suffixed with `, uncommitted changes` when the worktree has uncommitted changes. When there are neither line changes nor uncommitted changes, no tooltip is shown.
""", .disabled("not yet implemented"))
    func diverge_1_3() async throws { }

    @Test("""
@spec DIVERGE-1.4: When the worktree's ahead count, behind count, insertion count, and deletion count are all zero and there are no uncommitted changes, the indicator shall render no text.
""", .disabled("not yet implemented"))
    func diverge_1_4() async throws { }

    @Test("""
@spec DIVERGE-1.5: When the repository has no `origin` remote or the default branch name cannot be resolved, the indicator shall render no text for any worktree in that repository.
""", .disabled("not yet implemented"))
    func diverge_1_5() async throws { }

    @Test("""
@spec DIVERGE-1.6: While a worktree is in the stale state, the indicator shall render no text.
""", .disabled("not yet implemented"))
    func diverge_1_6() async throws { }

    @Test("""
@spec DIVERGE-2.1: The application shall resolve each repository's default branch name by running `git symbolic-ref --short refs/remotes/origin/HEAD` and stripping the `origin/` prefix from the result.
""", .disabled("not yet implemented"))
    func diverge_2_1() async throws { }

    @Test("""
@spec DIVERGE-2.2: If `refs/remotes/origin/HEAD` is not set, the application shall probe the refs `origin/main`, `origin/master`, and `origin/develop` in that order via `git show-ref --verify` and use the matching branch name.
""", .disabled("not yet implemented"))
    func diverge_2_2() async throws { }

    @Test("""
@spec DIVERGE-2.3: The application shall not perform any network operations to resolve the default branch name.
""", .disabled("not yet implemented"))
    func diverge_2_3() async throws { }

    @Test("""
@spec DIVERGE-2.4: The application shall cache the resolved default branch name per repository for the duration of the session.
""", .disabled("not yet implemented"))
    func diverge_2_4() async throws { }

    @Test("""
@spec DIVERGE-3.0: Divergence shall be measured against the union of a worktree's upstream refs:
""", .disabled("not yet implemented"))
    func diverge_3_0() async throws { }

    @Test("""
@spec DIVERGE-3.1: The application shall compute the behind count by running `git rev-list --count <refs> ^HEAD` and the ahead count by running `git rev-list --count HEAD ^<refs>` (each `<ref>` from `DIVERGE-3.0` prefixed with `^` for the ahead command). `rev-list` natively dedupes, so a commit reachable from both upstream refs is counted once.
""", .disabled("not yet implemented"))
    func diverge_3_1() async throws { }

    @Test("""
@spec DIVERGE-3.2: The application shall compute insertion and deletion line counts by running `git diff --shortstat <ref>...HEAD` where `<ref>` is `origin/<worktree-branch>` when that tracking ref exists, otherwise `origin/<defaultBranch>`. The diff uses a single ref rather than the full union so the tooltip reports "your commits on this branch" rather than conflating feature-branch work with default-branch churn.
""", .disabled("not yet implemented"))
    func diverge_3_2() async throws { }

    @Test("""
@spec DIVERGE-3.3: The application shall detect uncommitted changes in each worktree by running `git status --porcelain` and treating any non-empty output (including modified, staged, deleted, or untracked entries) as "has uncommitted changes".
""", .disabled("not yet implemented"))
    func diverge_3_3() async throws { }

    @Test("""
@spec DIVERGE-3.4: All git computation for divergence indicators shall run off the main thread and shall not block the UI.
""", .disabled("not yet implemented"))
    func diverge_3_4() async throws { }

    @Test("""
@spec DIVERGE-3.5: Divergence counts and the uncommitted-changes flag shall be held in memory only and shall not be written to `state.json`.
""", .disabled("not yet implemented"))
    func diverge_3_5() async throws { }

    @Test("""
@spec DIVERGE-4.1: When a repository is added to the sidebar, the application shall compute divergence counts for each of its worktrees.
""", .disabled("not yet implemented"))
    func diverge_4_1() async throws { }

    @Test("""
@spec DIVERGE-4.2: When a worktree's HEAD reference changes, the application shall recompute that worktree's divergence counts.
""", .disabled("not yet implemented"))
    func diverge_4_2() async throws { }

    @Test("""
@spec DIVERGE-4.8: The polling ticker for divergence stats shall continue to fire while Graftty is not the frontmost application. Users frequently run their editor or Claude session in a different app while the sidebar's divergence indicator tracks their work; pausing on `resignActive` leaves those updates queued until the user clicks back into Graftty, defeating the purpose of the indicator.
""", .disabled("not yet implemented"))
    func diverge_4_8() async throws { }
}
