import Foundation
import Testing
import GrafttyProtocol
@testable import GrafttyKit

struct WorktreeContextHandoffTests {
    @Test("@spec CONTEXT-71: When an agent reads retained context through the private handoff, the application shall return the owning live host's snapshot and reject snapshots from exited or replaced hosts.")
    func snapshotRequiresTheSameHostProcess() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let handoff = AttentionFileHandoff(rootDirectory: directory)
        let brief = WorktreeBrief(recap: .init(title: "Fix", completed: "Started.", next: "Test."), at: Date())
        try handoff.publishContext(brief, worktree: "/wt", emoji: "🔧")
        let snapshot = try handoff.context(worktree: "/wt")
        #expect(snapshot.brief == brief)
        #expect(snapshot.emoji == "🔧")
        #expect(throws: (any Error).self) {
            try handoff.context(worktree: "/wt", isCurrentHost: { _, _ in false })
        }
        #expect(throws: (any Error).self) { try handoff.context(worktree: "/another") }
    }
}
