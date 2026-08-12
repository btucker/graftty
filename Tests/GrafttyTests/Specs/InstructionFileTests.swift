import Testing
import Foundation
@testable import GrafttyKit

@Suite("@spec INSTR-3.1: The application shall recognize hierarchical files named GRAFTTY.md and map each containing directory to the same worktree key and its descendants; if a root contains a legacy GRAFTTY.<leaf>.md file, then the application shall treat it as a fallback alias for the equivalent hierarchical path, prefer the hierarchical file when both exist in that root, and skip every other filename.")
struct InstructionFileClassificationTests {

    @Test func rootInstructionFile() {
        #expect(InstructionFile.classify(relativePath: "GRAFTTY.md")
            == .scope(key: ""))
    }

    @Test func nestedInstructionFile() {
        #expect(InstructionFile.classify(relativePath: "research/GRAFTTY.md")
            == .scope(key: "research"))
    }

    @Test func legacyInstructionFilesMapToTheEquivalentScope() {
        let root = InstructionFile.classify(relativePath: "GRAFTTY.foo.md")
        #expect(root == .legacyScope(key: "foo"))
        #expect(root?.canonicalRelativePath == "foo/GRAFTTY.md")

        let nested = InstructionFile.classify(
            relativePath: "research/GRAFTTY.vector-db.md"
        )
        #expect(nested == .legacyScope(key: "research/vector-db"))
        #expect(nested?.canonicalRelativePath == "research/vector-db/GRAFTTY.md")
    }

    @Test func unrelatedFilenameIsSkipped() {
        #expect(InstructionFile.classify(relativePath: "README.md") == nil)
        #expect(InstructionFile.classify(relativePath: "research/notes.md") == nil)
        #expect(InstructionFile.classify(relativePath: "GRAFTTY..md") == nil)
        #expect(InstructionFile.classify(relativePath: "GRAFTTY.txt") == nil)
        #expect(InstructionFile.classify(relativePath: "graftty.md") == nil)
    }
}

@Suite("@spec INSTR-5.1: The application shall resolve a worktree instruction stack as the GRAFTTY.md file at the repository root and every directory component of the worktree key, ordered from root to the exact worktree.")
struct InstructionChainTests {

    @Test func nestedKeyWalksEveryAncestor() {
        #expect(InstructionChain.paths(forKey: "research/vector-db") == [
            "GRAFTTY.md",
            "research/GRAFTTY.md",
            "research/vector-db/GRAFTTY.md",
        ])
    }

    @Test func topLevelKeyHasRootAndOwnFile() {
        #expect(InstructionChain.paths(forKey: "foo") == [
            "GRAFTTY.md",
            "foo/GRAFTTY.md",
        ])
    }

    @Test func deeplyNestedKeyWalksEveryLevel() {
        #expect(InstructionChain.paths(forKey: "a/b/c") == [
            "GRAFTTY.md",
            "a/GRAFTTY.md",
            "a/b/GRAFTTY.md",
            "a/b/c/GRAFTTY.md",
        ])
    }

    @Test func aScopeFileAppliesToItsExactWorktree() {
        let chain = InstructionChain.paths(forKey: "research")
        #expect(chain == ["GRAFTTY.md", "research/GRAFTTY.md"])
    }
}
