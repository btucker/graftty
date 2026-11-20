import Foundation
import Testing
@testable import GrafttyKit

private func skill(_ provider: String) throws -> String {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
    return try String(contentsOf: root.appendingPathComponent(
        "Sources/GrafttyKit/AgentPlugins/\(provider)/plugins/graftty/skills/graftty/SKILL.md"), encoding: .utf8)
}

@Suite("@spec AGENT-3.41: When the application renders context-update guidance, it shall request sparse updates with a summary in one plain sentence, short history headlines, and explicit asks with options, brief costs, and background, within the existing per-turn guidance limit.")
struct AskCatchUpGuidanceTests {
    @Test func hookGuidanceUsesSparseAttention() {
        let guidance = TeamHookRenderer.recapGuidance
        #expect(guidance.contains("`options`"))
        #expect(guidance.contains("`background`"))
        #expect(guidance.contains("one plain sentence"))
        #expect(guidance.contains("changed groups only"))
        #expect(guidance.contains("unchanged"))
        #expect(guidance.contains("attention.kind"))
        #expect(!guidance.contains("`catchUp`"))
        #expect(!guidance.contains("Explain more"))
        // The per-turn text must not grow (1269 characters before options existed).
        #expect(guidance.count <= 1269)
    }

    @Test func skillsTeachOptionsAndBrevity() throws {
        for provider in ["claude", "codex"] {
            let text = try skill(provider)
            #expect(text.components(separatedBy: "## Explicit attention").count == 2, "The attention guidance appears once")
            #expect(!text.contains("- Optional `catchUp`"), "The old top-level field is no longer taught")
            #expect(text.contains("\"options\":["), "The example shows the field")
            #expect(text.contains("\"attention\":{\"kind\":\"ask\""))
            #expect(text.contains("\"background\":"))
            #expect(text.contains("few words of cost"))
            #expect(text.contains("one plain sentence"))
            #expect(text.contains("about 60 characters"))
            #expect(!text.contains("Explain more"))
        }
    }
}
