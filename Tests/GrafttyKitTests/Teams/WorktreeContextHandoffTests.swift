import Foundation
import Testing
import GrafttyProtocol
@testable import GrafttyKit

struct WorktreeContextHandoffTests {
    @Test("@spec CONTEXT-82: If one context snapshot cannot be published, then the application shall continue publishing other worktrees and keep activity observation independent of that failure.")
    func oneSnapshotFailureDoesNotBlockTheOthers() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let handoff = AttentionFileHandoff(rootDirectory: root)
        try handoff.publishContext(nil, worktree: "/blocked", emoji: nil)
        let file = try #require(FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).first { $0.lastPathComponent.hasPrefix("context-") })
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
        let state = AppState(repos: [.init(path: "/repo", displayName: "Repo", worktrees: [.init(path: "/blocked", branch: "bad"), .init(path: "/healthy", branch: "good")])])
        state.publishContextSnapshots(handoff: handoff)
        #expect(try handoff.context(worktree: "/healthy").worktree == "/healthy")
        let observer = AttentionFileHandoffObserver(handoff: handoff)
        try observer.start {}
        observer.stop()
    }
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
