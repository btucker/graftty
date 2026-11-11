import Foundation
import Testing
@testable import GrafttyKit

private func skill(_ provider: String) throws -> String {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
    return try String(contentsOf: root.appendingPathComponent(
        "Sources/GrafttyKit/AgentPlugins/\(provider)/plugins/graftty/skills/graftty/SKILL.md"), encoding: .utf8)
}

@Suite("@spec AGENT-3.41: When the application renders agent recap guidance, it shall ask for a one-sentence plain completed state, short plain history headlines, and, for a question with clear choices, options with a few words of cost each in place of a catch-up paragraph, without lengthening the per-turn guidance.")
struct AskCatchUpGuidanceTests {
    @Test func hookGuidanceAsksForOptions() {
        let guidance = TeamHookRenderer.recapGuidance
        #expect(guidance.contains("`options`"))
        #expect(guidance.contains("`catchUp`"))
        #expect(guidance.contains("one plain sentence"))
        #expect(!guidance.contains("Explain more"))
        // The per-turn text must not grow (1269 characters before options existed).
        #expect(guidance.count <= 1269)
    }

    @Test func skillsTeachOptionsAndBrevity() throws {
        for provider in ["claude", "codex"] {
            let text = try skill(provider)
            #expect(text.components(separatedBy: "- Optional `options`").count == 2, "The options guidance appears once")
            #expect(text.components(separatedBy: "- Optional `catchUp`").count == 2, "The catch-up guidance appears once")
            #expect(text.contains("\"options\":["), "The example shows the field")
            #expect(text.contains("one plain sentence"))
            #expect(text.contains("about 60 characters"))
            #expect(!text.contains("Explain more"))
        }
    }
}
