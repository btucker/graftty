#if os(macOS)
import AppKit
import GrafttyProtocol
import SwiftUI
import Testing
@testable import GrafttyCommandUI

@MainActor
struct WorktreeCreationProgressViewTests {
    @Test("@spec GIT-5.31: When worktree creation succeeds on Mac or mobile, the application shall hide the sidebar's Creation complete status one minute after completion while retaining creation diagnostics and keeping pending, failed, and interrupted statuses visible.")
    func successfulStatusExpiresWithoutRemovingDiagnostics() {
        let now = Date()
        func height(_ progress: WorktreeCreationProgress) -> CGFloat {
            NSHostingView(rootView: WorktreeCreationProgressView(progress: progress)
                .frame(width: 240).fixedSize(horizontal: false, vertical: true)).fittingSize.height
        }
        var progress = WorktreeCreationProgress(startedAt: now.addingTimeInterval(-600))
        progress.output = "Saved hook output."
        progress.transition(to: .ready, now: now.addingTimeInterval(-59))
        let fresh = height(progress)
        #expect(fresh > 0)
        progress.transition(to: .ready, now: now.addingTimeInterval(-61))
        #expect(height(progress) == 0)
        #expect(progress.showsInSidebar(at: now.addingTimeInterval(-1.001)))
        #expect(!progress.showsInSidebar(at: now.addingTimeInterval(-1)))
        progress.finishedAt = nil
        #expect(!progress.showsInSidebar(at: now), "Legacy completion records must also expire")
        #expect(progress.output == "Saved hook output.")
        for phase in [WorktreeCreationProgress.Phase.preparing, .git, .startingPane, .failed, .interrupted] {
            progress.transition(to: phase, now: now.addingTimeInterval(-600))
            #expect(height(progress) > 0)
        }
    }

    @Test("@spec GIT-5.46: While an agent is running in a worktree, the application shall hide a previous creation failure from its sidebar row and retain the recorded diagnostics.")
    func runningAgentHidesAFailedCreationBadge() {
        var progress = WorktreeCreationProgress()
        progress.transition(to: .failed, error: "Pane startup failed")
        func height(hasRunningAgent: Bool) -> CGFloat {
            NSHostingView(rootView: WorktreeCreationProgressView(progress: progress, hasRunningAgent: hasRunningAgent)
                .frame(width: 240).fixedSize(horizontal: false, vertical: true)).fittingSize.height
        }
        #expect(height(hasRunningAgent: false) > 0)
        #expect(height(hasRunningAgent: true) == 0)
        #expect(progress.error == "Pane startup failed")
    }
}
#endif
