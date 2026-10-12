public enum OpenResourceRouting {
    public enum Destination: Equatable {
        case mobile
        case mac
    }

    public static func worktree(path: String, paneSessionName: String?, state: AppState) -> WorktreeEntry? {
        guard let paneSessionName, !paneSessionName.isEmpty else { return state.worktree(forPath: path) }
        return state.repos.lazy.flatMap(\.worktrees).first {
            $0.paneSlot(forSessionName: paneSessionName) != nil
        }
    }

    public static func destination(
        paneSessionName: String?,
        belongsToWorktree: Bool,
        ownershipStore: SessionDisplayOwnershipStore
    ) -> Destination {
        guard let paneSessionName, belongsToWorktree,
              ownershipStore.snapshot(sessionName: paneSessionName).ownerKind == .ios else {
            return .mac
        }
        return .mobile
    }
}
