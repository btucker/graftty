import Testing
import Foundation
@testable import GrafttyKit

@Suite("@spec INSTR-2.1: The application shall derive a worktree instruction key from its path relative to the repository worktrees directory, from the resolved default branch for the main checkout, and shall produce no key for worktrees outside that directory.")
struct InstructionKeyTests {

    @Test func nestedWorktreeKeysOnRelativePath() {
        let key = InstructionKey.key(
            worktreePath: "/repo/.worktrees/research/vector-db",
            repoPath: "/repo",
            defaultBranch: "main"
        )
        #expect(key == "research/vector-db")
    }

    @Test func topLevelWorktreeKeysOnLeafName() {
        let key = InstructionKey.key(
            worktreePath: "/repo/.worktrees/foo",
            repoPath: "/repo",
            defaultBranch: "main"
        )
        #expect(key == "foo")
    }

    @Test func mainCheckoutKeysOnDefaultBranch() {
        let key = InstructionKey.key(
            worktreePath: "/repo",
            repoPath: "/repo",
            defaultBranch: "master"
        )
        #expect(key == "master")
    }

    @Test func mainCheckoutWithUnresolvedDefaultBranchHasNoKey() {
        let key = InstructionKey.key(
            worktreePath: "/repo",
            repoPath: "/repo",
            defaultBranch: nil
        )
        #expect(key == nil)
    }

    @Test func worktreeOutsideWorktreesDirectoryHasNoKey() {
        let key = InstructionKey.key(
            worktreePath: "/elsewhere/checkout",
            repoPath: "/repo",
            defaultBranch: "main"
        )
        #expect(key == nil)
    }

    @Test func trailingSlashesAndDotSegmentsAreNormalized() {
        let key = InstructionKey.key(
            worktreePath: "/repo/.worktrees/./research/vector-db",
            repoPath: "/repo/",
            defaultBranch: "main"
        )
        #expect(key == "research/vector-db")
    }
}
