import Testing
import Foundation
import GrafttyKit
import GrafttyProtocol
@testable import Graftty

@Suite("AddWorktreeFormController")
struct AddWorktreeFormControllerTests {

    private func someEntry(name: String = "feat") -> BranchPickerEntry {
        BranchPickerEntry(
            name: name,
            source: .local,
            lastCommitDate: Date(),
            mountedWorktreePath: nil,
            pr: nil
        )
    }

    @Test func newBranchModeRequiresWorktreeNameAndBranchName() {
        let c = AddWorktreeFormController(initialWorktreeName: "")
        #expect(c.canSubmit == false)  // empty worktree name
        c.worktreeName = "wt"
        c.newBranchName = "wt"
        #expect(c.canSubmit == true)
    }

    @Test("@spec GIT-5.18: While the user is in existing-branch mode, the Create button shall remain disabled until a branch row is selected; the filter `TextField`'s contents shall not be treated as a freeform branch name.")
    func existingBranchModeRequiresSelection() {
        let c = AddWorktreeFormController(initialWorktreeName: "wt")
        c.branchMode = .existing
        #expect(c.canSubmit == false)  // no selection yet
        c.pickExistingBranch(someEntry(name: "feat"))
        #expect(c.canSubmit == true)
        #expect(c.selectedSelection == .useExisting(name: "feat", source: .local))
    }

    @Test("@spec GIT-5.19: When the user toggles the branch-mode picker between \"New branch\" and \"Existing branch\", the application shall preserve each mode's prior input independently — the new-branch name shall not be clobbered by an existing-branch selection, and an existing-branch selection shall not be cleared by a temporary switch to new-branch mode.")
    func modeSwitchPreservesEachModesInputIndependently() {
        let c = AddWorktreeFormController(initialWorktreeName: "")
        c.worktreeName = "my-worktree"
        c.newBranchName = "cool-thing-v2"   // user customized
        c.branchMirrorsWorktree = false

        // New → Existing → pick a branch.
        c.branchMode = .existing
        c.pickExistingBranch(someEntry(name: "feat-other"))
        #expect(c.newBranchName == "cool-thing-v2", "new-branch name must survive the mode switch")

        // Existing → New: new-branch name is still there.
        c.branchMode = .newBranch
        #expect(c.newBranchName == "cool-thing-v2")
        #expect(c.selectedSelection == .createNew(name: "cool-thing-v2"))

        // New → Existing again: prior pick is still there.
        c.branchMode = .existing
        #expect(c.existingSelection?.name == "feat-other")
        #expect(c.selectedSelection == .useExisting(name: "feat-other", source: .local))
    }
}
