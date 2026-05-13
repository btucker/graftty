import Foundation

public struct BranchPickerEntry: Sendable, Hashable {
    public let name: String
    public let source: BranchSelection.ExistingSource
    public let lastCommitDate: Date
    /// Non-nil when this branch is currently mounted in another
    /// worktree of the same repo. Used to render dim/disabled rows.
    public let mountedWorktreePath: String?
    public let pr: PRSummary?

    public struct PRSummary: Sendable, Hashable {
        public let number: Int
        public let title: String
        public init(number: Int, title: String) {
            self.number = number
            self.title = title
        }
    }

    public init(
        name: String,
        source: BranchSelection.ExistingSource,
        lastCommitDate: Date,
        mountedWorktreePath: String?,
        pr: PRSummary?
    ) {
        self.name = name
        self.source = source
        self.lastCommitDate = lastCommitDate
        self.mountedWorktreePath = mountedWorktreePath
        self.pr = pr
    }
}
