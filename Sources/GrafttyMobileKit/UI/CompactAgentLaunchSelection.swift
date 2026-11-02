import Foundation
import GrafttyProtocol

/// A launch reply and its inventory snapshot can arrive in either order.
struct CompactAgentLaunchSelection {
    private(set) var generation = UUID()
    private var isActive = false
    private var pendingSession: String?

    mutating func activate() {
        generation = UUID()
        isActive = true
        pendingSession = nil
    }

    mutating func invalidate() {
        generation = UUID()
        isActive = false
        pendingSession = nil
    }

    mutating func created(_ session: String, generation: UUID, in worktree: WorktreePanes?) -> String? {
        guard isActive, generation == self.generation else { return nil }
        pendingSession = session
        return takeReady(in: worktree)
    }

    mutating func takeReady(in worktree: WorktreePanes?) -> String? {
        guard isActive, let session = pendingSession,
              worktree?.layout?.leaves.contains(where: { $0.sessionName == session }) == true
                || worktree?.agents?.contains(where: { $0.presentationSessionName == session }) == true else { return nil }
        pendingSession = nil
        return session
    }
}
