import Testing
import Foundation
@testable import GrafttyKit

@Suite("PresenceDocument — encoding and building")
struct PresenceDocumentTests {
    @Test("@spec SYNC-1.2: Presence documents shall round-trip through JSON with ISO-8601 timestamps and stable key ordering.")
    func jsonRoundTrip() throws {
        let doc = PresenceDocument(
            version: 1,
            user: "Sarah",
            email: "sarah@example.com",
            updatedAt: Date(timeIntervalSince1970: 1_780_000_000),
            worktrees: [
                .init(name: "auth-refactor", branch: "auth-refactor", state: .running),
                .init(name: "fix-pairing", branch: "fix/pairing", state: .idle),
            ]
        )
        let data = try PresenceDocument.encode(doc)
        let decoded = try PresenceDocument.decode(data)
        #expect(decoded == doc)
        // Deterministic output (sorted keys) so unchanged docs compare equal as bytes.
        #expect(try PresenceDocument.encode(doc) == data)
        // ISO-8601 wire format, not epoch seconds.
        let json = String(decoding: data, as: UTF8.self)
        #expect(json.contains("Z\"") || json.contains("+00:00"))
    }

    @Test("@spec SYNC-1.1: When building a presence document from a repo's worktrees, the application shall include only worktrees with an on-disk checkout, mapping running to running and closed to idle.")
    func buildFiltersAndMapsStates() throws {
        var running = WorktreeEntry(path: "/tmp/wt/auth-refactor", branch: "auth-refactor")
        running.state = .running
        var closed = WorktreeEntry(path: "/tmp/wt/fix-pairing", branch: "fix/pairing")
        closed.state = .closed
        var stale = WorktreeEntry(path: "/tmp/wt/old", branch: "old")
        stale.state = .stale
        var creating = WorktreeEntry(path: "/tmp/wt/new", branch: "new")
        creating.state = .creating

        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let doc = PresenceDocument.build(
            user: "Sarah",
            email: "sarah@example.com",
            worktrees: [running, closed, stale, creating],
            now: now
        )
        #expect(doc.updatedAt == now)
        #expect(doc.worktrees == [
            .init(name: "auth-refactor", branch: "auth-refactor", state: .running),
            .init(name: "fix-pairing", branch: "fix/pairing", state: .idle),
        ])
    }

    @Test("Malformed JSON fails to decode rather than producing a partial document.")
    func malformedJSONThrows() {
        let junk = Data("not json".utf8)
        #expect(throws: (any Error).self) { try PresenceDocument.decode(junk) }
    }
}
