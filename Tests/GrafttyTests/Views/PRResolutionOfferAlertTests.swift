import Testing
import GrafttyProtocol
@testable import Graftty

/// Pins the configuration of the GIT-4.7 offer-delete dialog. The
/// presentation itself (sheet vs. modal — see GIT-4.14) is verified by
/// manual smoke testing; this suite covers the pure factory so the
/// dialog's text and button labels stay regression-proof without booting
/// AppKit. NSAlert.init() loads a NIB that needs a running
/// NSApplication, which `swift test` doesn't provide — so the factory
/// returns a value struct and MainWindow assembles the NSAlert.
@Suite("PRResolutionOfferAlert")
struct PRResolutionOfferAlertTests {

    @Test("""
@spec GIT-4.7: When the application first observes a worktree's associated pull request transition into a terminal resolved state — either merged or closed-without-merging, whether from open, from no-PR-cached, or from a different previously-resolved PR number — the application shall present an informational dialog offering to delete the worktree. The dialog's message text shall cite the PR number and the resolution word ("merged" or "closed"), its informative text shall read "Delete the worktree now? This will delete the worktree but not the branch.", and its buttons shall be "Delete Worktree" and "Keep".
""")
    func mergedConfiguration() {
        let config = PRResolutionOfferAlert.configuration(prNumber: 142, state: .merged)
        #expect(config?.messageText == "Pull request #142 merged")
        #expect(config?.informativeText == "Delete the worktree now? This will delete the worktree but not the branch.")
        #expect(config?.primaryButton == "Delete Worktree")
        #expect(config?.secondaryButton == "Keep")
    }

    @Test func closedStateUsesClosedVerb() {
        let config = PRResolutionOfferAlert.configuration(prNumber: 99, state: .closed)
        #expect(config?.messageText == "Pull request #99 closed")
    }

    @Test func openStateReturnsNil() {
        #expect(PRResolutionOfferAlert.configuration(prNumber: 1, state: .open) == nil)
    }
}
