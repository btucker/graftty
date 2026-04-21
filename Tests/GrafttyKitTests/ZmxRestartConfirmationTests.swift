import Testing
@testable import GrafttyKit

@Suite("ZmxRestartConfirmation Tests")
struct ZmxRestartConfirmationTests {

    @Test func noRunningSessionsShowsNoOpMessage() {
        let text = ZmxRestartConfirmation.informativeText(paneCount: 0, worktreeCount: 0)
        #expect(text == "There are no running terminal sessions. Restarting ZMX will have no effect.")
    }

    /// Even if some worktrees are technically running with zero panes,
    /// the "no running sessions" branch dominates — we're talking to the
    /// user about *terminal sessions* they'll lose, and zero of those is
    /// zero regardless of worktree count.
    @Test func zeroPanesCollapsesToNoOpRegardlessOfWorktreeCount() {
        let text = ZmxRestartConfirmation.informativeText(paneCount: 0, worktreeCount: 3)
        #expect(text.contains("no running terminal sessions"))
    }

    /// The quantified phrase ("N running terminal session[s] across M
    /// worktree[s]") is what the user reads to understand scope. Pin the
    /// exact singular/plural form there; the trailing "…those sessions
    /// will be lost" never varies so we don't assert against its form.
    @Test func singlePaneInSingleWorktreeUsesAllSingulars() {
        let text = ZmxRestartConfirmation.informativeText(paneCount: 1, worktreeCount: 1)
        #expect(text.contains("1 running terminal session across 1 worktree."))
    }

    @Test func multiplePanesInSingleWorktreePluralizesOnlySessions() {
        let text = ZmxRestartConfirmation.informativeText(paneCount: 4, worktreeCount: 1)
        #expect(text.contains("4 running terminal sessions across 1 worktree."))
    }

    @Test func multiplePanesAcrossMultipleWorktreesPluralizesBoth() {
        let text = ZmxRestartConfirmation.informativeText(paneCount: 7, worktreeCount: 3)
        #expect(text.contains("7 running terminal sessions across 3 worktrees."))
    }

    /// Every non-empty branch must name the destructive consequence
    /// explicitly — losing unsaved work is the main decision point for
    /// the user, and dropping the warning would be silent data-loss UX.
    @Test func nonEmptyMessageAlwaysMentionsUnsavedWork() {
        for panes in 1...5 {
            for wts in 1...3 {
                let text = ZmxRestartConfirmation.informativeText(paneCount: panes, worktreeCount: wts)
                #expect(text.contains("unsaved work"), "missing unsaved-work warning for panes=\(panes) wts=\(wts)")
            }
        }
    }
}
