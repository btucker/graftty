import Testing
import Foundation
@testable import GrafttyKit

@Suite("TeamEventRoutingPreferences")
struct TeamEventRoutingPreferencesTests {

    @Test func defaultsMatchSpec() {
        let prefs = TeamEventRoutingPreferences()
        #expect(prefs.prStateChanged == .worktree)
        #expect(prefs.prMerged == .root)
        #expect(prefs.ciConclusionChanged == .worktree)
        #expect(prefs.mergabilityChanged == .worktree)
    }

    @Test func recipientSetSupportsUnion() {
        var s: RecipientSet = []
        #expect(s.isEmpty)
        s.insert(.root)
        #expect(s.contains(.root))
        #expect(!s.contains(.worktree))
        s.insert(.worktree)
        #expect(s.contains(.root))
        #expect(s.contains(.worktree))
        s.remove(.root)
        #expect(!s.contains(.root))
        #expect(s.contains(.worktree))
    }

    @Test func codableRoundTripPreservesValues() throws {
        var prefs = TeamEventRoutingPreferences()
        prefs.prStateChanged = [.worktree, .root]
        prefs.ciConclusionChanged = []
        let data = try JSONEncoder().encode(prefs)
        let decoded = try JSONDecoder().decode(TeamEventRoutingPreferences.self, from: data)
        #expect(decoded == prefs)
        #expect(decoded.prStateChanged.contains(.worktree))
        #expect(decoded.prStateChanged.contains(.root))
        #expect(decoded.ciConclusionChanged.isEmpty)
    }

    @Test func rawRepresentableRoundTrip() {
        var prefs = TeamEventRoutingPreferences()
        prefs.prMerged = [.root, .otherWorktrees]
        let raw = prefs.rawValue
        #expect(!raw.isEmpty)
        let decoded = TeamEventRoutingPreferences(rawValue: raw)
        #expect(decoded == prefs)
    }

    @Test func rawRepresentableRecoversFromGarbage() {
        // Invalid JSON should decode as nil (so @AppStorage falls back to default).
        #expect(TeamEventRoutingPreferences(rawValue: "not json") == nil)
        #expect(TeamEventRoutingPreferences(rawValue: "") == nil)
    }
}
