import Foundation
import GrafttyProtocol
import Testing
@testable import GrafttyKit

struct WorktreeBriefPersistenceTests {
    @Test("@spec CONTEXT-4: When a worktree report is viewed, dismissed, resumed, serialized, or sent to a paired device, the application shall retain its current brief and checkpoint history independently of unread attention.")
    func persistsAndProjectsBrief() throws {
        var worktree = WorktreeEntry(path: "/repo/work", branch: "work")
        let first = SidebarAgentStop(agentName: "Codex", stoppedAt: Date(timeIntervalSince1970: 100), recap: .init(title: "Worktree context", context: "Resume the task.", completed: "Chose A.", next: "Build.", checkpoint: "Chose brief and history"))
        worktree.recordAgentStop(first)
        worktree.acknowledgeAttention()
        worktree.clearAgentStopAttention(providerSessionKey: "codex:session:session", progressedAt: Date(timeIntervalSince1970: 200))
        #expect(worktree.brief?.title == "Worktree context")
        #expect(worktree.brief?.history.count == 1)
        let restored = try JSONDecoder().decode(WorktreeEntry.self, from: JSONEncoder().encode(worktree))
        #expect(restored.brief == worktree.brief)
        let metadata = SidebarHostNavigation.metadata(for: restored, projectID: "repo", folders: [])
        #expect(metadata.brief == restored.brief)
        let decoded = try JSONDecoder().decode(SidebarWorktreeMetadata.self, from: JSONEncoder().encode(metadata))
        #expect(decoded.brief == worktree.brief)
        var legacy = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(worktree)) as? [String: Any])
        legacy.removeValue(forKey: "brief")
        let migrated = try JSONDecoder().decode(WorktreeEntry.self, from: JSONSerialization.data(withJSONObject: legacy))
        #expect(migrated.brief?.title == "Worktree context")
    }
}
