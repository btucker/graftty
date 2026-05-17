import Foundation
import Testing
@testable import GrafttyProtocol

@Suite("PanesStateMessage — snapshot encode/decode round-trip and unknown-type rejection.")
struct PanesStateEnvelopeTests {

    @Test
    func snapshotRoundTrips() throws {
        let layout: PaneLayoutNode = .leaf(sessionName: "abc", title: "shell", attentionText: nil)
        let worktree = WorktreePanes(
            path: "/repo/wt-1",
            displayName: "feature-branch",
            repoDisplayName: "graftty",
            displayBranch: "feature-branch",
            state: .running,
            isMainCheckout: false,
            prBadge: nil,
            stats: nil,
            attentionText: nil,
            layout: layout
        )
        let original: PanesStateMessage = .snapshot([worktree])
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(PanesStateMessage.self, from: data)
        #expect(decoded == original)
    }

    @Test
    func unknownTypeThrows() throws {
        let json = Data(#"{"type":"future-message-type","payload":42}"#.utf8)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(PanesStateMessage.self, from: json)
        }
    }
}
