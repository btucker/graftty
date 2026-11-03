import Testing
import Foundation
import GrafttyKit
import GrafttyProtocol
@testable import Graftty

@Suite("AddWorktreeFormController")
struct AddWorktreeFormControllerTests {
    @Test("Agent choice and multiline task survive branch-mode changes; empty tasks remain optional")
    func agentAndTaskSurviveModeChanges() {
        let form = AddWorktreeFormController(initialWorktreeName: "feature")
        #expect(form.agent.provider == nil)
        #expect(form.agent.initialPrompt == nil)
        #expect(form.canSubmit)
        let prompt = "Fix the tests.\nKeep $(literal syntax).\n"
        form.agent.provider = "claude"
        form.agent.taskDescription = prompt
        form.branchMode = .existing
        form.pickExistingBranch(someEntry())
        form.branchMode = .newBranch
        #expect(form.agent.provider == "claude")
        #expect(form.agent.initialPrompt == prompt)
        form.agent.taskDescription = " \n\t"
        #expect(form.agent.initialPrompt == nil)
        #expect(form.canSubmit)
    }

    private func someEntry(name: String = "feat") -> BranchPickerEntry {
        BranchPickerEntry(
            name: name,
            source: .local,
            lastCommitDate: Date(),
            mountedWorktreePath: nil,
            pr: nil
        )
    }

    @Test func blankNewBranchNamesCanBeGenerated() {
        let c = AddWorktreeFormController(initialWorktreeName: "")
        #expect(c.canSubmit)
        #expect(c.selectedSelection == .createNew(name: ""))
        c.worktreeName = "wt"
        #expect(!c.canSubmit) // An independently cleared branch still requires input.
        c.newBranchName = "wt"
        #expect(c.canSubmit == true)
    }

    @Test func generatedSubmissionRetainsAgentAndExistingBranchSource() async throws {
        let form = AddWorktreeFormController(initialWorktreeName: "")
        form.agent = .init(provider: "claude", taskDescription: "Fix login\nKeep sessions")
        let fresh = try #require(await form.submission(repositoryName: "App", generate: { _ in "Fix Login" }))
        #expect(fresh.worktree == "fix-login")
        #expect(fresh.branch == .createNew(name: "fix-login"))
        #expect(fresh.agent == form.agent)

        form.branchMode = .existing
        form.existingSelection = BranchPickerEntry(name: "feature/login", source: .remoteOnly,
            lastCommitDate: Date(), mountedWorktreePath: nil, pr: nil)
        let existing = try #require(await form.submission(repositoryName: "App", generate: { _ in "Fix Login" }))
        #expect(existing.worktree == "fix-login")
        #expect(existing.branch == .useExisting(name: "feature/login", source: .remoteOnly))
        #expect(form.worktreeName.isEmpty)
    }

    @Test func automaticNamesAvoidKnownBranchesAndMountedDirectories() async throws {
        let form = AddWorktreeFormController(initialWorktreeName: "")
        let entries = [BranchPickerEntry(name: "fix-login", source: .local, lastCommitDate: Date(),
            mountedWorktreePath: "/repo/.worktrees/custom-directory", pr: nil)]
        for name in ["fix-login", "custom-directory"] {
            let submission = try #require(await form.submission(
                repositoryName: "App", branchEntries: entries, generate: { _ in name }
            ))
            #expect(submission.worktree.hasPrefix("worktree-"))
            #expect(submission.branch == .createNew(name: submission.worktree))
        }
    }

    @Test("@spec GIT-5.15: When the user selects a branch from the existing-branch picker, the application shall auto-fill the worktree name with the branch name unless the user has already edited the field.")
    func pickingExistingBranchAutoFillsWorktreeName() {
        let c = AddWorktreeFormController(initialWorktreeName: "")
        c.branchMode = .existing
        c.pickExistingBranch(someEntry(name: "feat-xyz"))
        #expect(c.worktreeName == "feat-xyz")

        // Once the user edits the worktree name (the View flips
        // worktreeMirrorsBranch=false), subsequent picks don't clobber it.
        c.worktreeMirrorsBranch = false
        c.pickExistingBranch(someEntry(name: "feat-zzz"))
        #expect(c.worktreeName == "feat-xyz", "edited worktree name must not be clobbered")
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

    @Test("""
@spec GIT-5.19: When the user toggles the branch-mode picker between "New branch" and "Existing branch", the application shall preserve each mode's prior input independently — the new-branch name shall not be clobbered by an existing-branch selection, and an existing-branch selection shall not be cleared by a temporary switch to new-branch mode.
""")
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
