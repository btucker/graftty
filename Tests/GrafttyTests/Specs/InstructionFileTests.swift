import Testing
import Foundation
@testable import GrafttyKit

@Suite("@spec INSTR-3.1: The application shall recognize exactly two instruction filename forms — a group file named GRAFTTY.md applying to every key beneath its directory, and a leaf file named GRAFTTY.<leaf>.md applying to the single key formed by its directory and leaf — and shall skip every other name.")
struct InstructionFileClassificationTests {

    @Test func rootGroupFile() {
        #expect(InstructionFile.classify(relativePath: "GRAFTTY.md")
            == .group(directory: ""))
    }

    @Test func nestedGroupFile() {
        #expect(InstructionFile.classify(relativePath: "research/GRAFTTY.md")
            == .group(directory: "research"))
    }

    @Test func rootLeafFile() {
        #expect(InstructionFile.classify(relativePath: "GRAFTTY.foo.md")
            == .leaf(key: "foo"))
    }

    @Test func nestedLeafFile() {
        #expect(InstructionFile.classify(relativePath: "research/GRAFTTY.vector-db.md")
            == .leaf(key: "research/vector-db"))
    }

    @Test func leafNameContainingDotsIsPreserved() {
        #expect(InstructionFile.classify(relativePath: "GRAFTTY.api.v2.md")
            == .leaf(key: "api.v2"))
    }

    @Test func emptyLeafComponentIsSkipped() {
        #expect(InstructionFile.classify(relativePath: "GRAFTTY..md") == nil)
    }

    @Test func unrelatedFilenameIsSkipped() {
        #expect(InstructionFile.classify(relativePath: "README.md") == nil)
        #expect(InstructionFile.classify(relativePath: "research/notes.md") == nil)
        #expect(InstructionFile.classify(relativePath: "GRAFTTY.txt") == nil)
        #expect(InstructionFile.classify(relativePath: "graftty.md") == nil)
    }
}

@Suite("@spec INSTR-5.1: The application shall resolve a worktree instruction stack as the group file at every ancestor level from the root inward, followed by the worktree leaf file located at its parent level.")
struct InstructionChainTests {

    @Test func nestedKeyWalksEveryAncestor() {
        #expect(InstructionChain.paths(forKey: "research/vector-db") == [
            "GRAFTTY.md",
            "research/GRAFTTY.md",
            "research/GRAFTTY.vector-db.md",
        ])
    }

    @Test func topLevelKeyHasRootAndLeafOnly() {
        #expect(InstructionChain.paths(forKey: "foo") == [
            "GRAFTTY.md",
            "GRAFTTY.foo.md",
        ])
    }

    @Test func deeplyNestedKeyWalksEveryLevel() {
        #expect(InstructionChain.paths(forKey: "a/b/c") == [
            "GRAFTTY.md",
            "a/GRAFTTY.md",
            "a/b/GRAFTTY.md",
            "a/b/GRAFTTY.c.md",
        ])
    }

    @Test func groupFileDoesNotApplyToTheWorktreeNamedLikeTheGroup() {
        // `research/GRAFTTY.md` covers descendants only. The worktree whose
        // key is exactly `research` reads `GRAFTTY.research.md` one level up.
        let chain = InstructionChain.paths(forKey: "research")
        #expect(chain == ["GRAFTTY.md", "GRAFTTY.research.md"])
        #expect(!chain.contains("research/GRAFTTY.md"))
    }
}
