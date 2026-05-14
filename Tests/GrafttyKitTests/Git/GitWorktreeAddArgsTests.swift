import Testing
import Foundation
@testable import GrafttyKit

@Suite("GitWorktreeAdd argv shape")
struct GitWorktreeAddArgsTests {
    @Test("createNew without startPoint uses -b <name> <path>")
    func createNewNoStart() {
        let argv = GitWorktreeAdd.argvFor(
            branch: .createNew(name: "feat-x"),
            worktreePath: "/repo/.worktrees/feat-x",
            startPoint: nil
        )
        #expect(argv == ["worktree", "add", "-b", "feat-x", "/repo/.worktrees/feat-x"])
    }

    @Test("createNew with startPoint appends the start point")
    func createNewWithStart() {
        let argv = GitWorktreeAdd.argvFor(
            branch: .createNew(name: "feat-x"),
            worktreePath: "/repo/.worktrees/feat-x",
            startPoint: "origin/main"
        )
        #expect(argv == ["worktree", "add", "-b", "feat-x", "/repo/.worktrees/feat-x", "origin/main"])
    }

    @Test("@spec GIT-5.10: When BranchSelection.useExisting is submitted with a local source, the application shall invoke `git worktree add <path> <name>` (no `-b` flag).")
    func useExistingLocal() {
        let argv = GitWorktreeAdd.argvFor(
            branch: .useExisting(name: "feat-x", source: .local),
            worktreePath: "/repo/.worktrees/feat-x",
            startPoint: nil
        )
        #expect(argv == ["worktree", "add", "/repo/.worktrees/feat-x", "feat-x"])
    }

    @Test("@spec GIT-5.12: When BranchSelection.useExisting is submitted with a remoteOnly source, the application shall pass `origin/<name>` so git creates a local tracking branch as a side effect.")
    func useExistingRemoteOnly() {
        let argv = GitWorktreeAdd.argvFor(
            branch: .useExisting(name: "feat-x", source: .remoteOnly),
            worktreePath: "/repo/.worktrees/feat-x",
            startPoint: nil
        )
        #expect(argv == ["worktree", "add", "/repo/.worktrees/feat-x", "origin/feat-x"])
    }
}
