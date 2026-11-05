import Foundation
import Testing
@testable import GrafttyKit

private func skill(_ provider: String) throws -> String {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
    return try String(contentsOf: root.appendingPathComponent(
        "Sources/GrafttyKit/AgentPlugins/\(provider)/plugins/graftty/skills/graftty/SKILL.md"), encoding: .utf8)
}

@Suite("@spec AGENT-3.36: When the application renders agent recap guidance, it shall explain the optional worktree drawing, its palette tokens and the redraw rule while still requiring an emoji.")
struct WorktreeDrawingGuidanceTests {
    @Test func hookGuidanceMentionsDrawing() {
        for text in [TeamHookRenderer.skillGuidance, TeamHookRenderer.recapGuidance] {
            #expect(text.contains("`icon`"))
            #expect(text.contains("emoji"))
        }
        #expect(TeamHookRenderer.skillGuidance.contains("purposeChanged"))
    }

    @Test func skillsTeachDrawing() throws {
        for provider in ["claude", "codex"] {
            let text = try skill(provider)
            #expect(text.contains("`icon`"))
            #expect(text.contains("`primary`"))
            #expect(text.contains("purposeChanged"))
            #expect(text.contains("`emoji`"))
        }
    }

    @Test func guidanceExampleIsValid() throws {
        let text = try skill("claude")
        let block = try #require(text.range(of: "```svg"))
        let start = try #require(text.range(of: "<svg", range: block.upperBound..<text.endIndex))
        let end = try #require(text.range(of: "</svg>", range: start.upperBound..<text.endIndex))
        let example = String(text[start.lowerBound..<end.upperBound])
        #expect(try WorktreeDrawingSVG.validate(example) == example)
    }
}
