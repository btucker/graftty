#if os(macOS)
import AppKit
import GrafttyProtocol
import SwiftUI
import Testing
@testable import GrafttyCommandUI

@MainActor
struct WorktreeCreationProgressViewTests {
    @Test("@spec GIT-5.31: When worktree creation succeeds on Mac or mobile, the application shall hide the sidebar's Creation complete status one minute after completion. While a worktree is running, the application shall hide prior failed or interrupted creation statuses in the sidebar and retain their diagnostics.")
    func sidebarStatusKeepsUnresolvedFailuresAndExpiresSuccess() {
        let now = Date()
        func height(_ progress: WorktreeCreationProgress, isRunning: Bool = false) -> CGFloat {
            NSHostingView(rootView: WorktreeCreationProgressView(progress: progress, isRunning: isRunning)
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
            #expect(height(progress, isRunning: true) == 0 || progress.isPending)
        }
        #expect(progress.output == "Saved hook output.")
    }
}
#endif
