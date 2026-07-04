import Foundation
import Testing
@testable import GrafttyKit

@Suite("FlowStateStore")
struct FlowStateStoreTests {
    /// @spec FLOW-1.3: When Flow State stores a recommendation, summary, note, or snooze, the application shall persist it under the Flow State root and load it after store reinitialization.
    @Test
    func persistsRecommendationSummaryNoteAndSnooze() throws {
        let root = try temporaryDirectory()
        let store = FlowStateStore(rootDirectory: root)
        let generatedAt = Date(timeIntervalSince1970: 1_783_108_800)
        let recommendation = FlowRecommendationEnvelope(
            schemaVersion: 1,
            generatedAt: generatedAt,
            primary: FlowPrimaryRecommendation(
                worktreeRef: "repo:feature",
                intent: .stay,
                title: "Stay",
                reason: "Nearby work",
                confidence: .medium
            )
        )
        try store.writeRecommendation(recommendation)
        try store.writeSummary(FlowWorktreeSummary(
            worktreeRef: "repo:feature",
            updatedAt: generatedAt,
            summary: "Tests are running",
            nextAction: "Wait for tests",
            needsHuman: false
        ))
        try store.writeNote(FlowWorktreeNote(
            worktreeRef: "repo:feature",
            updatedAt: generatedAt,
            body: "User prefers to finish this repo first."
        ))
        try store.writeSnooze(FlowSnooze(
            worktreeRef: "repo:other",
            updatedAt: generatedAt,
            until: .nextFocusBreak,
            reason: "High reload cost"
        ))

        let reloaded = FlowStateStore(rootDirectory: root)
        #expect(try reloaded.recommendation()?.primary.title == "Stay")
        #expect(try reloaded.summaries()["repo:feature"]?.nextAction == "Wait for tests")
        #expect(try reloaded.notes()["repo:feature"]?.body.contains("finish this repo") == true)
        #expect(try reloaded.snoozes()["repo:other"]?.until == .nextFocusBreak)
    }

    @Test("worktree ref storage filenames are collision resistant")
    func worktreeRefStorageFilenamesAreCollisionResistant() throws {
        let root = try temporaryDirectory()
        let store = FlowStateStore(rootDirectory: root)
        let updatedAt = Date(timeIntervalSince1970: 100)

        try store.writeSummary(FlowWorktreeSummary(
            worktreeRef: "repo:a/b",
            updatedAt: updatedAt,
            summary: "slash",
            nextAction: "one",
            needsHuman: false
        ))
        try store.writeSummary(FlowWorktreeSummary(
            worktreeRef: "repo:a_b",
            updatedAt: updatedAt,
            summary: "underscore",
            nextAction: "two",
            needsHuman: false
        ))

        let summaries = try FlowStateStore(rootDirectory: root).summaries()
        #expect(summaries["repo:a/b"]?.summary == "slash")
        #expect(summaries["repo:a_b"]?.summary == "underscore")
    }
}
