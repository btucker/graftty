import Foundation
import Observation
import GrafttyKit
import GrafttyProtocol

/// State holder for `AddWorktreeSheet`. Owns the user's inputs across
/// both branch modes (`newBranchName` for "New branch", `existingSelection`
/// for "Existing branch") and the mirroring flags that drive auto-fill
/// between worktree name and branch name. Keeping each mode's input in
/// its own field is what makes `GIT-5.19` (mode-switch preservation)
/// true by construction — toggling `branchMode` doesn't touch either.
@Observable
public final class AddWorktreeFormController {
    public enum BranchMode: Hashable { case newBranch, existing }

    public var worktreeName: String
    public var branchMode: BranchMode = .newBranch
    public var newBranchName: String
    public var existingSelection: BranchPickerEntry?

    /// Tracks whether the branch field is still mirroring the worktree
    /// name. Once the user types something different in the branch field
    /// (in `.newBranch` mode), we stop auto-syncing.
    public var branchMirrorsWorktree: Bool = true

    /// True while the worktree name should track the picker selection.
    /// Cleared once the user edits the worktree name independently —
    /// see `GIT-5.15`'s test for the resulting auto-fill behavior.
    public var worktreeMirrorsBranch: Bool = true

    public init(initialWorktreeName: String) {
        self.worktreeName = initialWorktreeName
        self.newBranchName = initialWorktreeName
    }

    public func pickExistingBranch(_ entry: BranchPickerEntry) {
        if existingSelection != entry { existingSelection = entry }
        if worktreeMirrorsBranch && worktreeName != entry.name {
            worktreeName = entry.name
        }
    }

    public var canSubmit: Bool {
        guard !WorktreeNameSanitizer.trimForSubmit(worktreeName).isEmpty else {
            return false
        }
        return selectedSelection != nil
    }

    public var selectedSelection: BranchSelection? {
        switch branchMode {
        case .newBranch:
            let trimmed = WorktreeNameSanitizer.trimForSubmit(newBranchName)
            return trimmed.isEmpty ? nil : .createNew(name: trimmed)
        case .existing:
            guard let entry = existingSelection else { return nil }
            return .useExisting(name: entry.name, source: entry.source)
        }
    }
}
