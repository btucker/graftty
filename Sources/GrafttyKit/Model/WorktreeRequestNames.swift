import GrafttyProtocol

public enum WorktreeRequestNames {
    public static func resolve(name: String, branch: String?, existing: Bool) -> (worktree: String, branch: String) {
        let worktree = normalize(name)
        let requestedBranch = branch ?? (existing ? name : worktree)
        return (worktree, existing ? requestedBranch : normalize(requestedBranch))
    }

    private static func normalize(_ value: String) -> String {
        WorktreeNameSanitizer.trimForSubmit(WorktreeNameSanitizer.sanitize(value))
    }
}
