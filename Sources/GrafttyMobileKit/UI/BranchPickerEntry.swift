#if canImport(UIKit)
import Foundation

/// A branch row shown in `BranchPickerView`. Mirrors the shape of
/// `GrafttyKit.BranchPickerEntry` so the two can be kept in sync; defined
/// here to avoid a GrafttyMobileKit → GrafttyKit dependency.
public struct BranchPickerEntry: Sendable, Hashable {
    public let name: String
    public let lastCommitDate: Date
    /// Non-nil when this branch is currently mounted in another worktree of
    /// the same repo. The picker renders these rows as dim and disabled.
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
        lastCommitDate: Date,
        mountedWorktreePath: String? = nil,
        pr: PRSummary? = nil
    ) {
        self.name = name
        self.lastCommitDate = lastCommitDate
        self.mountedWorktreePath = mountedWorktreePath
        self.pr = pr
    }
}
#endif
