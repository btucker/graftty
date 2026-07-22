import Testing
@testable import GrafttyKit

@Suite("Worktree creation input validation")
struct WorktreeCreationInputTests {
    @Test func acceptsNestedSafeNames() {
        #expect(WorktreeCreationInput.validationError(
            worktreeName: "agents/fix-auth",
            branchName: "agents/fix-auth"
        ) == nil)
    }

    @Test func rejectsParentTraversalInWorktreeName() {
        #expect(WorktreeCreationInput.validationError(
            worktreeName: "../outside",
            branchName: "safe-branch"
        )?.contains("invalid path component") == true)
    }

    @Test func rejectsEmptyPathComponents() {
        #expect(WorktreeCreationInput.validationError(
            worktreeName: "agents//fix-auth",
            branchName: "safe-branch"
        ) != nil)
    }

    @Test func rejectsUnsanitizedCharacters() {
        #expect(WorktreeCreationInput.validationError(
            worktreeName: "fix auth",
            branchName: "fix-auth"
        )?.contains("unsupported") == true)
    }

    @Test(arguments: ["foo--bar", "café", "release-"])
    func preservesGitValidExistingBranchNames(_ branchName: String) {
        #expect(WorktreeCreationInput.validationError(
            worktreeName: "existing-branch",
            branchName: branchName,
            existing: true
        ) == nil)
    }
}
