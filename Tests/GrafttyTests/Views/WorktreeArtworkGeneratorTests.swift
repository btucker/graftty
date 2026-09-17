import Foundation
import Testing
@testable import Graftty

@Suite("Worktree artwork providers")
@MainActor
struct WorktreeArtworkGeneratorTests {
    @Test("@spec LAYOUT-2.90: When generating Codex worktree artwork, the application shall prioritize recognition at small sizes using stable worktree-specific subject directions, silhouettes, compositions, and dominant accents, while confining theme matching to the backdrop and leaving fading to the UI.")
    func worktreesReceiveDistinctVisualDirections() {
        let names = ["generate-icons", "claude-notifications", "graftty-crash", "paging-through-scrollback",
                     "wf_ec05fbc1-baf-1", "wf_ec05fbc1-baf-2", "research/lead", "research/nearshore"]
        let directions = names.map { CodexArtworkDirection(name: $0, variation: 0) }
        #expect(Set(directions).count == names.count)
        #expect(Set(directions.map(\.subjectDirection)).count >= 4)
        #expect(Set(directions.map(\.silhouette)).count >= 4)
        #expect(Set(directions.map(\.composition)).count >= 4)
        for (name, direction) in zip(names, directions) {
            #expect(direction == CodexArtworkDirection(name: name, variation: 0))
            let regenerated = CodexArtworkDirection(name: name, variation: 1)
            #expect(regenerated.subjectDirection != direction.subjectDirection)
            #expect(regenerated.silhouette != direction.silhouette)
            #expect(regenerated.composition != direction.composition)
            let prompt = WorktreeArtworkGenerator.codexPrompt(name: name, userContext: "Fix notification delivery",
                style: .illustration, variation: 0, theme: nil)
            #expect(prompt.contains(direction.subjectDirection))
            #expect(prompt.contains(direction.silhouette))
            #expect(prompt.contains(direction.composition))
            #expect(prompt.contains("Fix notification delivery"))
            #expect(prompt.contains("thumbnail"))
            #expect(!prompt.contains("fade detail"))
            #expect(!prompt.contains("tactile texture"))
        }
    }

    @Test func codexUsesOnlySelectedThemeAccentsWithoutDimmingTheSubject() {
        let theme = WorktreeArtworkTheme(theme: GhosttyTheme(core: .init(
            backgroundRGB: .init(r: 40.0/255, g: 44.0/255, b: 52.0/255),
            foregroundRGB: .init(r: 1, g: 1, b: 1)), palette: [
                .init(r: 1, g: 0, b: 0), .init(r: 0, g: 1, b: 0),
                .init(r: 0, g: 0, b: 1), .init(r: 1, g: 1, b: 0),
            ]))
        let first = theme.codexColorInstruction(index: 0, variation: 0)
        let second = theme.codexColorInstruction(index: 1, variation: 0)
        #expect(first.contains("#282c34"))
        #expect(first.contains("Dominant subject color: #ff0000"))
        #expect(second.contains("Dominant subject color: #00ff00"))
        #expect(!first.contains("#0000ff"))
        #expect(!first.contains("low-key lighting"))
        #expect(!first.contains("dim ambient shadows"))
        #expect(first != theme.codexColorInstruction(index: 0, variation: 1))
    }

    @Test("@spec LAYOUT-2.88: When generating worktree artwork, the application shall try installed Codex first and fall back to Apple on unavailability or generation failure, while propagating cancellation without starting a fallback.")
    func providerOrderAndCancellation() async throws {
        var calls: [String] = []
        let result = try await WorktreeArtworkGenerator.generate(preferred: {
            calls.append("codex")
            return Data([1])
        }, fallback: {
            calls.append("apple")
            return Data([2])
        })
        #expect(result == Data([1]))
        #expect(calls == ["codex"])

        calls = []
        let fallback = try await WorktreeArtworkGenerator.generate(preferred: {
            calls.append("codex")
            throw CocoaError(.fileNoSuchFile)
        }, fallback: {
            calls.append("apple")
            return Data([2])
        })
        #expect(fallback == Data([2]))
        #expect(calls == ["codex", "apple"])

        calls = []
        await #expect(throws: CancellationError.self) {
            try await WorktreeArtworkGenerator.generate(preferred: {
                throw CancellationError()
            }, fallback: {
                calls.append("apple")
                return Data()
            })
        }
        #expect(calls.isEmpty)
    }

    @Test func codexPromptPreservesContextStyleAndConfiguredColors() {
        let theme = WorktreeArtworkTheme(theme: GhosttyTheme(core: .init(
            backgroundRGB: .init(r: 40.0/255, g: 44.0/255, b: 52.0/255),
            foregroundRGB: .init(r: 1, g: 1, b: 1))))
        let prompt = WorktreeArtworkGenerator.codexPrompt(name: "garden", userContext: "Grow a fern",
            style: .sketch, variation: 42, theme: theme)
        #expect(prompt.contains("Grow a fern"))
        #expect(prompt.contains("Sketch"))
        #expect(prompt.contains("#282c34"))
        #expect(prompt.contains("42"))
        #expect(prompt.contains("fresh"))
        #expect(!WorktreeArtworkGenerator.codexPrompt(name: "x", userContext: String(repeating: "a", count: 9000),
            style: .animation, variation: 0, theme: nil).contains(String(repeating: "a", count: 4001)))
    }
}
