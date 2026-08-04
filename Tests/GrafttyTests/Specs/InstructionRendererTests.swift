import Testing
import Foundation
@testable import GrafttyKit

private func set(_ pairs: [String: String]) -> InstructionSet {
    var documents: [String: InstructionDocument] = [:]
    for (path, body) in pairs {
        documents[path] = InstructionDocument.parse(body)
    }
    return InstructionSet(documents: documents)
}

@Suite("@spec INSTR-6.1: The application shall render a session-start instructions section containing the viewer's own instruction stack, the shared portions of files applying to each other worktree, and the shared portions of files applying to no worktree, shall note in place of the shared text where a file has no shared portion, and shall omit any block that is empty and the whole section when nothing applies.")
struct InstructionRendererTests {

    @Test func ownStackConcatenatesRootThroughLeafWithPrivateText() {
        let text = InstructionRenderer.render(
            viewer: .init(key: "research/vector-db", displayName: "vector-db"),
            others: [],
            set: set([
                "GRAFTTY.md": "repo wide",
                "research/GRAFTTY.md": "group shared\n## Private\ngroup private",
                "research/GRAFTTY.vector-db.md": "leaf text",
            ])
        )
        #expect(text.contains("repo wide"))
        #expect(text.contains("group shared"))
        #expect(text.contains("group private"))
        #expect(text.contains("leaf text"))
        if let repoWide = text.range(of: "repo wide"),
           let leaf = text.range(of: "leaf text") {
            #expect(repoWide.lowerBound < leaf.lowerBound)
        } else {
            Issue.record("expected both the repo-wide and leaf sections")
        }
    }

    @Test func otherWorktreesContributeSharedTextOnly() {
        let text = InstructionRenderer.render(
            viewer: .init(key: "research/vector-db", displayName: "vector-db"),
            others: [.init(key: "product", displayName: "product")],
            set: set([
                "GRAFTTY.product.md": "ask product for roadmap calls\n## Private\nproduct internals",
            ])
        )
        #expect(text.contains("ask product for roadmap calls"))
        #expect(!text.contains("product internals"))
    }

    @Test func repoWideFileIsNotRepeatedPerOtherWorktree() {
        let text = InstructionRenderer.render(
            viewer: .init(key: "a", displayName: "a"),
            others: [.init(key: "b", displayName: "b")],
            set: set(["GRAFTTY.md": "repo wide"])
        )
        let occurrences = text.components(separatedBy: "repo wide").count - 1
        #expect(occurrences == 1)
    }

    @Test func filesMatchingNoWorktreeAreListedSeparately() {
        let text = InstructionRenderer.render(
            viewer: .init(key: "a", displayName: "a"),
            others: [],
            set: set(["marketing/GRAFTTY.md": "marketing brief"])
        )
        #expect(text.contains("marketing brief"))
        #expect(text.contains("marketing/GRAFTTY.md"))
    }

    @Test func viewerWithNoKeyStillReceivesTheRepoWideFile() {
        let text = InstructionRenderer.render(
            viewer: .init(key: nil, displayName: "detached"),
            others: [],
            set: set(["GRAFTTY.md": "repo wide"])
        )
        #expect(text.contains("repo wide"))
    }

    @Test func sharedAncestorFileIsNotRepeatedForAnotherWorktree() {
        let text = InstructionRenderer.render(
            viewer: .init(key: "research/vector-db", displayName: "vector-db"),
            others: [.init(key: "research/api", displayName: "api")],
            set: set([
                "research/GRAFTTY.md": "research team charter",
            ])
        )
        let occurrences = text.components(separatedBy: "research team charter").count - 1
        #expect(occurrences == 1)
    }

    @Test func nothingApplicableRendersAnEmptySection() {
        let text = InstructionRenderer.render(
            viewer: .init(key: "a", displayName: "a"),
            others: [],
            set: InstructionSet(documents: [:])
        )
        #expect(text.isEmpty)
    }

    @Test func privateOnlyFileForAnotherWorktreeRendersANote() {
        let text = InstructionRenderer.render(
            viewer: .init(key: "a", displayName: "a"),
            others: [.init(key: "b", displayName: "b")],
            set: set(["GRAFTTY.b.md": "## Private\nb internals"])
        )
        #expect(text.contains("`b`"))
        #expect(text.contains(InstructionRenderer.noSharedInstructionsNote))
        #expect(!text.contains("b internals"))
    }

    @Test func privateOnlyFileMatchingNoWorktreeRendersANote() {
        let text = InstructionRenderer.render(
            viewer: .init(key: "a", displayName: "a"),
            others: [],
            set: set(["marketing/GRAFTTY.md": "## Private\nmarketing internals"])
        )
        #expect(text.contains("marketing/GRAFTTY.md"))
        #expect(text.contains(InstructionRenderer.noSharedInstructionsNote))
        #expect(!text.contains("marketing internals"))
    }

    @Test func oneResolvedLeafIsSharedBySameKeyAudiences() {
        let text = InstructionRenderer.render(
            viewer: .init(key: "main", displayName: "main"),
            others: [
                .init(key: "main", displayName: "linked-main"),
            ],
            set: InstructionSet(
                documents: [
                    "GRAFTTY.main.md": .parse(
                        "main role\n## Private\nmain private"
                    ),
                ]
            )
        )

        #expect(text.contains("main role"))
        #expect(text.contains("main private"))
        #expect(text.components(separatedBy: "main role").count - 1 == 1)
    }
}
