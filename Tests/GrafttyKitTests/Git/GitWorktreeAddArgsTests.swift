import Testing
import Foundation
@testable import GrafttyKit

@Suite("GitWorktreeAdd argv shape")
struct GitWorktreeAddArgsTests {
    @Test("createNew without startPoint uses -b <name> <path>")
    func createNewNoStart() {
        let argv = GitWorktreeAdd.argvForTesting(
            branch: .createNew(name: "feat-x"),
            worktreePath: "/repo/.worktrees/feat-x",
            startPoint: nil
        )
        #expect(argv == ["worktree", "add", "-b", "feat-x", "/repo/.worktrees/feat-x"])
    }

    @Test("createNew with startPoint appends the start point")
    func createNewWithStart() {
        let argv = GitWorktreeAdd.argvForTesting(
            branch: .createNew(name: "feat-x"),
            worktreePath: "/repo/.worktrees/feat-x",
            startPoint: "origin/main"
        )
        #expect(argv == ["worktree", "add", "-b", "feat-x", "/repo/.worktrees/feat-x", "origin/main"])
    }

    @Test("@spec GIT-5.10: useExisting local uses bare name, no -b")
    func useExistingLocal() {
        let argv = GitWorktreeAdd.argvForTesting(
            branch: .useExisting(name: "feat-x", source: .local),
            worktreePath: "/repo/.worktrees/feat-x",
            startPoint: nil
        )
        #expect(argv == ["worktree", "add", "/repo/.worktrees/feat-x", "feat-x"])
    }

    @Test("@spec GIT-5.12: useExisting remoteOnly uses origin/<name>, no -b")
    func useExistingRemoteOnly() {
        let argv = GitWorktreeAdd.argvForTesting(
            branch: .useExisting(name: "feat-x", source: .remoteOnly),
            worktreePath: "/repo/.worktrees/feat-x",
            startPoint: nil
        )
        #expect(argv == ["worktree", "add", "/repo/.worktrees/feat-x", "origin/feat-x"])
    }

    @Test("useExisting ignores startPoint")
    func useExistingIgnoresStartPoint() {
        let argv = GitWorktreeAdd.argvForTesting(
            branch: .useExisting(name: "feat-x", source: .local),
            worktreePath: "/repo/.worktrees/feat-x",
            startPoint: "origin/main"
        )
        #expect(argv == ["worktree", "add", "/repo/.worktrees/feat-x", "feat-x"])
    }
}
