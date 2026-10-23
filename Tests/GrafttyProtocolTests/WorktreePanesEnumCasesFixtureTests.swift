import Foundation
import Testing
@testable import GrafttyProtocol

/// Every raw value of every enum the web client mirrors
/// (`web-client/src/paneTypes.ts`), encoded by the host into
/// `Fixtures/worktree-panes-enum-cases.json`. The web client's
/// `paneTypes.wireFixture.test.ts` parses the same file, so a renamed raw value
/// changes the golden here and fails the browser parser there.
///
/// Adding a Swift case stops `requireListed` compiling. Add the case both to
/// that switch and to its list below; only the list reaches the golden.
///
/// Regenerate after an intended change with
/// `GRAFTTY_UPDATE_WIRE_FIXTURES=1 scripts/swiftpm test --filter WorktreePanesEnumCasesFixtureTests`,
/// then run the tests normally: the test bundle holds the previous copy.
@Suite("WorktreePanes enum-case wire fixture")
struct WorktreePanesEnumCasesFixtureTests {
    static let states: [WorktreeWireState] = [.closed, .running, .stale, .creating, .deleting]
    static let sources: [AttentionSource] = [.agentStop, .userNotify, .commandFinished]
    static let prStates: [PRInfo.State] = [.open, .merged, .closed]
    static let checks: [PRInfo.Checks] = [.pending, .success, .failure, .none]
    static let mergeables: [PRInfo.Mergeable] = [.mergeable, .conflicting, .unknown]

    // Exhaustive switches: adding a case fails to compile here, prompting the
    // matching addition to the list above.
    private static func requireListed(_ value: WorktreeWireState) {
        switch value { case .closed, .running, .stale, .creating, .deleting: break }
    }
    private static func requireListed(_ value: AttentionSource) {
        switch value { case .agentStop, .userNotify, .commandFinished: break }
    }
    private static func requireListed(_ value: PRInfo.State) {
        switch value { case .open, .merged, .closed: break }
    }
    private static func requireListed(_ value: PRInfo.Checks) {
        switch value { case .pending, .success, .failure, .none: break }
    }
    private static func requireListed(_ value: PRInfo.Mergeable) {
        switch value { case .mergeable, .conflicting, .unknown: break }
    }

    /// One row per index up to the longest list; each list cycles, so every
    /// value appears at least once.
    static var rows: [WorktreePanes] {
        let counts: [Int] = [states.count, sources.count, prStates.count, checks.count, mergeables.count]
        let count: Int = counts.max() ?? 0
        return (0..<count).map(row)
    }

    private static func row(_ i: Int) -> WorktreePanes {
        let badge = PRBadge(
            number: i + 1,
            state: prStates[i % prStates.count],
            checks: checks[i % checks.count],
            mergeable: mergeables[i % mergeables.count],
            url: URL(string: "https://example.com/pr/\(i + 1)")!)
        let layout: PaneLayoutNode = .leaf(
            sessionName: "graftty-\(i)", title: "", attentionText: "attention",
            isBusy: false, attentionSource: sources[i % sources.count])
        return WorktreePanes(
            path: "/repo/case-\(i)",
            displayName: "case-\(i)",
            repoDisplayName: "repo",
            displayBranch: "case-\(i)",
            state: states[i % states.count],
            isMainCheckout: false,
            prBadge: badge,
            stats: nil,
            attentionText: nil,
            layout: layout
        )
    }

    private static var fixtureURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/worktree-panes-enum-cases.json")
    }

    @Test
    func everyMirroredCaseIsListed() {
        Self.states.forEach(Self.requireListed)
        Self.sources.forEach(Self.requireListed)
        Self.prStates.forEach(Self.requireListed)
        Self.checks.forEach(Self.requireListed)
        Self.mergeables.forEach(Self.requireListed)
        #expect(Set(Self.rows.map(\.state)) == Set(Self.states))
        #expect(Set(Self.rows.compactMap(\.prBadge).map(\.checks).map(\.rawValue)) == Set(Self.checks.map(\.rawValue)))
    }

    @Test
    func currentEncoderProducesTheCommittedFixture() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let encoded = try encoder.encode(Self.rows)
        let committedData: Data
        if ProcessInfo.processInfo.environment["GRAFTTY_UPDATE_WIRE_FIXTURES"] == "1" {
            try (encoded + Data("\n".utf8)).write(to: Self.fixtureURL)
            committedData = try Data(contentsOf: Self.fixtureURL)
        } else {
            committedData = try WireFixture.data("worktree-panes-enum-cases")
        }
        let current = try JSONSerialization.jsonObject(with: encoded) as? NSArray
        let committed = try JSONSerialization.jsonObject(with: committedData) as? NSArray
        #expect(current != nil)
        #expect(current == committed)
    }
}
