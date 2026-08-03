import Testing
import Foundation
@testable import GrafttyKit

@Suite("@spec INSTR-4.1: The application shall split an instruction file at the first heading whose text is exactly Private, treating text above it as shared with every agent and text below it as private to the matching worktrees, and shall treat a file with no such heading as entirely shared.")
struct InstructionDocumentTests {

    @Test func fileWithoutMarkerIsEntirelyShared() {
        let doc = InstructionDocument.parse("Run the research loop nightly.")
        #expect(doc.shared == "Run the research loop nightly.")
        #expect(doc.privateText.isEmpty)
    }

    @Test func markerSplitsSharedFromPrivate() {
        let doc = InstructionDocument.parse("""
        Ask this worktree for dependency reviews.

        ## Private

        Use the scratch branch for spikes.
        """)
        #expect(doc.shared == "Ask this worktree for dependency reviews.")
        #expect(doc.privateText == "Use the scratch branch for spikes.")
    }

    @Test func markerIsRecognizedAtAnyHeadingLevel() {
        for hashes in ["#", "##", "###", "####", "#####", "######"] {
            let doc = InstructionDocument.parse("shared\n\(hashes) Private\nsecret")
            #expect(doc.shared == "shared")
            #expect(doc.privateText == "secret")
        }
    }

    @Test func markerMatchIsCaseInsensitive() {
        let doc = InstructionDocument.parse("shared\n## private\nsecret")
        #expect(doc.privateText == "secret")
    }

    @Test func fileBeginningWithMarkerHasNoSharedPortion() {
        let doc = InstructionDocument.parse("## Private\nonly for me")
        #expect(doc.shared.isEmpty)
        #expect(doc.privateText == "only for me")
    }

    @Test func onlyTheFirstMarkerSplitsAndLaterOnesAreContent() {
        let doc = InstructionDocument.parse("shared\n## Private\nfirst\n## Private\nsecond")
        #expect(doc.shared == "shared")
        #expect(doc.privateText == "first\n## Private\nsecond")
    }

    @Test func headingWithOtherTextIsNotAMarker() {
        let doc = InstructionDocument.parse("shared\n## Private notes\nstill shared")
        #expect(doc.shared == "shared\n## Private notes\nstill shared")
        #expect(doc.privateText.isEmpty)
    }

    @Test func hashWithoutSpaceIsNotAMarker() {
        let doc = InstructionDocument.parse("shared\n#Private\nstill shared")
        #expect(doc.privateText.isEmpty)
    }
}
