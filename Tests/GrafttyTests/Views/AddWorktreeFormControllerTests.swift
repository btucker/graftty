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
}
