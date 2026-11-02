public enum SidebarMergedWorktreeRemoval {
    public static func isAvailable(prState: PRInfo.State?, isMainCheckout: Bool, state: WorktreeWireState) -> Bool {
        prState == .merged && !isMainCheckout && state.hasOnDiskWorktree
    }
}
