import Foundation
import Testing
@testable import GrafttyKit

private func skill(_ provider: String) throws -> String {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
    return try String(contentsOf: root.appendingPathComponent(
        "Sources/GrafttyKit/AgentPlugins/\(provider)/plugins/graftty/skills/graftty/SKILL.md"), encoding: .utf8)
}

@Suite("@spec AGENT-3.36: When the application renders agent recap guidance, it shall explain the optional worktree drawing, varied compositions, its palette tokens and the redraw rule while still requiring an emoji.")
struct WorktreeDrawingGuidanceTests {
    @Test func hookGuidanceMentionsDrawing() {
        for text in [TeamHookRenderer.skillGuidance, TeamHookRenderer.recapGuidance] {
            #expect(text.contains("`icon`"))
            #expect(text.contains("emoji"))
        }
        #expect(TeamHookRenderer.skillGuidance.contains("purposeChanged"))
        #expect(TeamHookRenderer.skillGuidance.contains("Vary the composition"))
    }

    @Test func skillsTeachDrawing() throws {
        for provider in ["claude", "codex"] {
            let text = try skill(provider)
            #expect(text.contains("`icon`"))
            #expect(text.contains("`primary`"))
            #expect(text.contains("purposeChanged"))
            #expect(text.contains("`emoji`"))
            #expect(text.contains("Vary the composition"))
            #expect(text.contains("resolved Ghostty theme colors"))
            #expect(!text.contains("put the subject on the left"))
            #expect(text.components(separatedBy: "- Optional `icon`").count == 2, "The drawing guidance appears once")
        }
    }

    @Test func guidanceExamplesAreValidWideDrawings() throws {
        let blocks = try skill("claude").components(separatedBy: "```svg").dropFirst()
        #expect(blocks.count >= 2)
        for block in blocks {
            let example = try #require(block.components(separatedBy: "```").first)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            #expect(try WorktreeDrawingSVG.validate(example) == example)
            #expect(WorktreeDrawingSVG.canvas(of: example) == .wide)
        }
    }
}

@Suite("@spec AGENT-3.44: While a worktree's drawing uses the older square canvas, the application shall ask that worktree's agent at turn start to redraw it on the wide canvas.")
struct WideRedrawRequestTests {
    @Test func turnStartAsksForAWideRedraw() throws {
        let asking = try TeamHookRenderer.userPromptSubmit(drawingRedraw: .widen)
        #expect(asking.contains("0 0 96 64"))
        #expect(!(try TeamHookRenderer.userPromptSubmit()).contains("0 0 96 64"))
    }

    @Test func skillsTeachTheWideCanvas() throws {
        for provider in ["claude", "codex"] {
            let text = try skill(provider)
            #expect(text.contains("viewBox='0 0 96 64'"))
            #expect(!text.contains("viewBox='0 0 64 64'"))
        }
    }
}


@Suite("@spec AGENT-3.46: While a linked worktree needs a first drawing or a one-time redraw, the application shall list at turn start the descriptions of up to eight of the most recently adopted other drawings in its repository and ask for a different subject and composition.")
struct DrawingsInUseTests {
    private func drawing(_ description: String, at seconds: Double) -> WorktreeDrawing {
        WorktreeDrawing(svg: "<svg viewBox='0 0 96 64'><rect width='9' height='9' fill='ink'/></svg>", hue: 25,
                        description: description, adoptedAt: Date(timeIntervalSinceReferenceDate: seconds))
    }

    private func repos(own: WorktreeDrawing?, others: Int) -> [RepoEntry] {
        var worktrees = [WorktreeEntry(path: "/repo", branch: "main"), WorktreeEntry(path: "/repo/new", branch: "new")]
        worktrees[1].drawing = own
        for index in 0..<others {
            var other = WorktreeEntry(path: "/repo/w\(index)", branch: "w\(index)")
            other.drawing = drawing("drawing \(index)", at: Double(index))
            worktrees.append(other)
        }
        var elsewhere = WorktreeEntry(path: "/other/x", branch: "x")
        elsewhere.drawing = drawing("another project's drawing", at: 99)
        return [RepoEntry(path: "/repo", displayName: "Repo", worktrees: worktrees),
                RepoEntry(path: "/other", displayName: "Other", worktrees: [WorktreeEntry(path: "/other", branch: "main"), elsewhere])]
    }

    @Test func listsRecentDrawingsOfTheSameProject() {
        let listed = WorktreeDrawing.descriptionsInUse(besidesWorktreePath: "/repo/new", in: repos(own: nil, others: 10))
        #expect(listed == (2..<10).reversed().map { "drawing \($0)" })
    }

    @Test func listsDrawingsOnlyWhileTheWorktreeNeedsOne() throws {
        #expect(WorktreeDrawing.descriptionsInUse(besidesWorktreePath: "/repo/new",
                                                  in: repos(own: drawing("mine", at: 50), others: 3)).isEmpty)
        let square = WorktreeDrawing(svg: "<svg viewBox='0 0 64 64'></svg>", hue: 25)
        #expect(WorktreeDrawing.descriptionsInUse(besidesWorktreePath: "/repo/new",
                                                  in: repos(own: square, others: 1)) == ["drawing 0"])
        let legacy = ["svg": drawing("mine", at: 50).svg, "revision": "legacy:25"]
        let legacyWide = try JSONDecoder().decode(WorktreeDrawing.self, from: JSONEncoder().encode(legacy))
        #expect(WorktreeDrawing.descriptionsInUse(besidesWorktreePath: "/repo/new",
                                                  in: repos(own: legacyWide, others: 1)) == ["drawing 0"])
        #expect(WorktreeDrawing.descriptionsInUse(besidesWorktreePath: "/repo", in: repos(own: nil, others: 1)).isEmpty)
    }

    @Test func turnStartNamesDrawingsInUse() throws {
        let text = try TeamHookRenderer.userPromptSubmit(drawingsInUse: ["a clock beside a git branch", "a green box"])
        #expect(text.contains("Drawings already used in this project: a clock beside a git branch; a green box."))
        #expect(text.contains("Draw a different subject and composition"))
        #expect(!(try TeamHookRenderer.userPromptSubmit()).contains("already used"))
    }

    @Test func guidanceAsksForADescription() throws {
        #expect(TeamHookRenderer.skillGuidance.contains("`iconDescription`"))
        for provider in ["claude", "codex"] {
            let text = try skill(provider)
            #expect(text.contains("`iconDescription`"))
        }
    }
}

@Suite("@spec AGENT-3.48: When a host supplies resolved Ghostty theme colors, the application shall include them in each agent turn's drawing guidance as a contrast reference while requiring SVG palette tokens.")
@MainActor
struct WorktreeDrawingThemeGuidanceTests {
    @Test(arguments: [TeamHookRuntime.codex, .claude])
    func turnStartIncludesCurrentTheme(provider: TeamHookRuntime) async throws {
        let platform = try ControlRequestCoreTests.RecordingPlatform()
        platform.drawingThemeContext = "background = #282a36\nforeground = #f8f8f2\npalette = 1=#ff5555"
        let response = await ControlRequestCore.handleRequest(.teamHook(callerWorktree: "/repo",
            callerAgentID: nil, runtime: provider, event: .userPromptSubmit,
            sessionID: nil, paneSessionName: platform.paneSession), platform: platform)
        let output = try #require(response)
        guard case .teamHookOutput(let json) = output else {
            Issue.record("Expected hook output")
            return
        }
        let object = try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        let hook = try #require(object["hookSpecificOutput"] as? [String: Any])
        let context = try #require(hook["additionalContext"] as? String)
        #expect(context.contains(try #require(platform.drawingThemeContext)))
        #expect(context.contains("contrast reference"))
        #expect(context.contains("SVG palette tokens"))
    }

    @Test func hostsWithoutAThemeOmitTheReference() throws {
        let text = try TeamHookRenderer.userPromptSubmit()
        #expect(!text.contains("active Ghostty theme"))
    }
}
