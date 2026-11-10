import Foundation
import Testing
@testable import GrafttyKit

private func skill(_ provider: String) throws -> String {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
    return try String(contentsOf: root.appendingPathComponent(
        "Sources/GrafttyKit/AgentPlugins/\(provider)/plugins/graftty/skills/graftty/SKILL.md"), encoding: .utf8)
}

@Suite("@spec AGENT-3.41: When the application renders agent recap guidance, it shall ask for a `catchUp` with every `need` and for Explain more as an option in every agent question that offers choices.")
struct AskCatchUpGuidanceTests {
    @Test func hookGuidanceAsksForACatchUp() {
        #expect(TeamHookRenderer.recapGuidance.contains("`catchUp`"))
        #expect(TeamHookRenderer.recapGuidance.contains("Explain more"))
    }

    @Test func skillsTeachTheCatchUp() throws {
        for provider in ["claude", "codex"] {
            let text = try skill(provider)
            #expect(text.components(separatedBy: "- Optional `catchUp`").count == 2, "The catch-up guidance appears once")
            #expect(text.contains("Explain more"))
            #expect(text.contains("\"catchUp\""), "The example report shows the field")
        }
    }
}
