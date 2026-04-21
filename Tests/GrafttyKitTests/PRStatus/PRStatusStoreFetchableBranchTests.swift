import Testing
import Foundation
@testable import GrafttyKit

// Worktrees in git's `(detached)` / `(bare)` / `(unknown)` states carry
// sentinel strings as their `branch` value (see GitWorktreeDiscovery).
// Feeding those sentinels to `gh pr list --head (detached)` always
// returns an empty array — every polling tick against such a worktree
// fires two pointless `gh` subprocesses. `isFetchableBranch` is the
// gate that keeps the poller off those branches.
@Suite("PRStatusStore.isFetchableBranch")
struct PRStatusStoreFetchableBranchTests {
    @Test func realBranchIsFetchable() {
        #expect(PRStatusStore.isFetchableBranch("main"))
        #expect(PRStatusStore.isFetchableBranch("feature/x"))
        #expect(PRStatusStore.isFetchableBranch("bug/pr-association"))
    }

    @Test func gitSentinelsAreNotFetchable() {
        #expect(!PRStatusStore.isFetchableBranch("(detached)"))
        #expect(!PRStatusStore.isFetchableBranch("(bare)"))
        #expect(!PRStatusStore.isFetchableBranch("(unknown)"))
    }

    @Test func futureParenthesizedSentinelsAreNotFetchable() {
        // If `parsePorcelain` grows a new sentinel tomorrow, we'd rather
        // silently skip fetching for it than start spamming `gh`.
        #expect(!PRStatusStore.isFetchableBranch("(unborn)"))
        #expect(!PRStatusStore.isFetchableBranch("(anything)"))
    }

    @Test func emptyAndWhitespaceBranchesAreNotFetchable() {
        #expect(!PRStatusStore.isFetchableBranch(""))
        #expect(!PRStatusStore.isFetchableBranch("   "))
        #expect(!PRStatusStore.isFetchableBranch("\t\n"))
    }

    @Test func branchesThatHappenToContainParensAreStillFetchable() {
        // Real branches can't start-with-( AND end-with-) (git ref rules
        // forbid parens in ref names — see git-check-ref-format), so only
        // the precise prefix+suffix match counts as a sentinel. A branch
        // like `foo-(WIP)` wouldn't be a valid ref anyway, but making
        // sure the helper isn't overbroad: middle-paren branches pass.
        #expect(PRStatusStore.isFetchableBranch("feature-(wip)-bar"))
    }
}
