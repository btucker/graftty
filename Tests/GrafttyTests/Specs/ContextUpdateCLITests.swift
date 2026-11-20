import Foundation
import Testing
import GrafttyProtocol
import GrafttyKit
@testable import GrafttyCLI

struct ContextUpdateCLITests {
    @Test("@spec CONTEXT-78: While a valid initialization from the same agent is durably queued, the context command shall accept later sparse updates without waiting for the host snapshot to catch up.")
    func queuedInitializationAllowsSubsequentSparseCommands() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let handoff = AttentionFileHandoff(rootDirectory: root)
        try handoff.publishContext(nil, worktree: "/wt", emoji: nil)
        let first = AttentionRecap(update: .init(purpose: .init(title: "Fix", context: "Startup fails."), now: .init(summary: "Started.")))
        try ContextUpdate.publish(first, worktree: "/wt", agentID: "one", handoff: handoff)
        try ContextUpdate.publish(.init(update: .init(now: .init(summary: "Tested."))), worktree: "/wt", agentID: "one", handoff: handoff)
        try ContextUpdate.publish(.init(update: .init(unchanged: true)), worktree: "/wt", agentID: "one", handoff: handoff)
        #expect(try handoff.context(worktree: "/wt").brief == nil)
        #expect(try handoff.takeActivities { _ in }.count == 3)
        #expect(throws: (any Error).self) {
            try ContextUpdate.publish(.init(update: .init(unchanged: true)), worktree: "/wt", agentID: "other", handoff: handoff)
        }
    }
    @Test("@spec CONTEXT-72: When the context update command receives sparse JSON, the CLI shall validate changed groups without requiring repeated identity fields and reject unknown top-level fields and unsafe drawings.")
    func sparseValidation() throws {
        let recap = try ContextUpdate.decodeUpdate(Data(#"{"now":{"summary":"Tests passed."}}"#.utf8))
        #expect(recap.isValid)
        #expect(recap.contextUpdate?.now?.summary == "Tests passed.")
        #expect(recap.emoji == nil)
        #expect(try ContextUpdate.decodeUpdate(Data(#"{"unchanged":true}"#.utf8)).isValid)
        for json in [#"{}"#, #"{"now":{"summary":"Done."},"typo":true}"#,
                     #"{"unchanged":true,"attention":{"kind":"ask","question":"Ship?"}}"#,
                     #"{"icon":"<svg viewBox='0 0 96 64'><script>x()</script></svg>"}"#] {
            #expect(throws: (any Error).self) { try ContextUpdate.decodeUpdate(Data(json.utf8)) }
        }
    }
}
