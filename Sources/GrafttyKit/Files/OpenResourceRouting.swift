public enum OpenResourceRouting {
    public enum Destination: Equatable {
        case mobile
        case mac
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
