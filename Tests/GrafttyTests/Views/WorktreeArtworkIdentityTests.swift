import AppKit
import ImagePlayground
import GhosttyKit
import Testing
@testable import Graftty

@Suite("Memorable worktree artwork")
struct WorktreeArtworkIdentityTests {
    @Test("@spec LAYOUT-2.75: When initially generating linked-worktree artwork, the application shall derive a stable fallback subject, color palette, and composition from the worktree name and send English visual descriptions instead of raw technical names to ImageCreator.")
    func identitiesAreStableDistinctAndConcrete() {
        let names = ["generate-icons", "claude-notifications", "graftty-crash", "paging-through-scrollback",
                     "wf_ec05fbc1-baf-1", "wf_ec05fbc1-baf-2", "wf_ec05fbc1-baf-3",
                     "research/lead", "research/trust", "research/nearshore", "jedi-sagemaker-spot"]
        let identities = names.map { WorktreeArtworkIdentity(name: $0) }
        #expect(Set(identities).count == names.count)
        #expect(Set(identities.map(\.palette)).count >= 6)
        #expect(Set(identities.map(\.subject)).count >= 6)
        for (name, identity) in zip(names, identities) {
            #expect(identity == WorktreeArtworkIdentity(name: name))
            #expect(!identity.concepts.joined().contains(name))
            #expect(identity.concepts.joined().unicodeScalars.allSatisfy { $0.isASCII })
            #expect(!identity.subject.isEmpty)
        }
    }

    @Test("@spec LAYOUT-2.84: When the user regenerates a worktree background, the application shall choose a fresh palette and composition and request a new task-related visual interpretation while preserving the chosen style and cached result until replacement succeeds.")
    @MainActor
    func regenerationVariesVisualChoicesAndTranslation() async throws {
        var variation: UInt64 = 0
        var previous = WorktreeArtworkIdentity(name: "calendar")
        for _ in 0..<32 {
            variation = WorktreeArtworkIdentity.nextVariation(after: variation)
            let next = WorktreeArtworkIdentity(name: "calendar", variation: variation)
            #expect(next.palette != previous.palette)
            #expect(next.composition != previous.composition)
            #expect(next.subject != previous.subject)
            #expect(next == WorktreeArtworkIdentity(name: "calendar", variation: variation))
            previous = next
        }
        var input = ""
        let result = try await WorktreeArtworkPrompt.identity(for: "calendar",
            userContext: "Help plan a garden", variation: variation) { prompt in
            input = prompt
            return "a seedling emerging from a cracked terracotta pot"
        }
        #expect(input.contains("Help plan a garden"))
        #expect(input.contains("fresh visual interpretation"))
        #expect(input.contains("Creative direction:"))
        #expect(result.subject.contains("seedling"))
        #expect(result.palette == previous.palette)
        let fallback = try await WorktreeArtworkPrompt.identity(for: "calendar", variation: variation) { _ in nil }
        #expect(fallback == previous)
    }

    @Test("@spec LAYOUT-2.85: When generating a worktree background, the application shall match the active Ghostty backdrop and use project colors for the subject when available, otherwise use ANSI accents, while retaining a distinct task-related subject and composition.")
    @MainActor
    func themeColorsGuideArtworkAndFallback() async throws {
        let dark = WorktreeArtworkTheme(theme: GhosttyTheme(
            core: .init(backgroundRGB: .init(r: 0, g: 0, b: 0), foregroundRGB: .init(r: 1, g: 1, b: 1)),
            palette: [.init(r: 1, g: 0, b: 0), .init(r: 0, g: 0, b: 1)]))
        let light = WorktreeArtworkTheme(theme: GhosttyTheme(
            core: .init(backgroundRGB: .init(r: 1, g: 1, b: 1), foregroundRGB: .init(r: 0, g: 0, b: 0)),
            palette: [.init(r: 1, g: 0, b: 0), .init(r: 0, g: 0, b: 1)]))
        #expect(dark.cacheKey != light.cacheKey)
        let identity = try await WorktreeArtworkPrompt.identity(for: "garden", userContext: "Grow flowers", theme: dark) { _ in "a blooming sunflower" }
        let projectIdentity = WorktreeArtworkIdentity(name: "garden", theme: dark, project: .harbor)
        #expect(projectIdentity.palette == ProjectArtworkDirection.harbor.palette(name: "garden", variation: 0))
        #expect(projectIdentity.concepts.first == identity.concepts.first)
        #expect(identity.subject == "a blooming sunflower")
        #expect(identity.palette.contains("red"))
        #expect(identity.palette.contains("blue"))
        #expect(identity.concepts.joined().contains("black"))
        #expect(identity.concepts.joined().contains("low-key lighting"))
        #expect(identity.fallbackConcepts.joined().contains("black"))
        let bright = WorktreeArtworkIdentity(name: "garden", theme: light)
        #expect(bright.concepts.joined().contains("white"))
        #expect(bright.concepts.joined().contains("soft daylight"))
        #expect(bright.composition == identity.composition)
        #expect(identity.concepts.joined().unicodeScalars.allSatisfy { $0.isASCII })
    }

    @Test("Artwork colors include Ghostty palette overrides and ignore split dimming")
    @MainActor
    func resolvedPaletteIncludesOverrides() throws {
        #expect(ghostty_init(0, nil) == 0)
        let config = GhosttyConfig()
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        let colors = ["000000", "ff0000", "00ff00", "ffff00", "0000ff", "ff00ff", "00ffff", "eeeeee",
                      "444444", "ff8888", "88ff88", "ffff88", "8888ff", "ff88ff", "88ffff", "ffffff"]
        let paletteConfig = colors.enumerated().map { "palette = \($0.offset)=#\($0.element)" }.joined(separator: "\n")
        try ("background = #101020\nforeground = #eeeeee\n" + paletteConfig + "\n")
            .write(to: file, atomically: true, encoding: .utf8)
        file.path.withCString { ghostty_config_load_file(config.config, $0) }
        ghostty_config_finalize(config.config)
        let theme = GhosttyTheme(config: config)
        #expect(theme.palette.count == 16)
        #expect(theme.palette[1] == .init(r: 1, g: 0, b: 0))
        #expect(theme.palette[4] == .init(r: 0, g: 0, b: 1))
        let differentDimming = GhosttyTheme(core: .init(backgroundRGB: theme.backgroundRGB,
            foregroundRGB: theme.foregroundRGB, unfocusedSplitOpacity: 0.2), palette: theme.palette)
        #expect(WorktreeArtworkTheme(theme: theme).cacheKey == WorktreeArtworkTheme(theme: differentDimming).cacheKey)
        let identities = (0..<12).map { WorktreeArtworkIdentity(name: "garden", variation: UInt64($0), theme: WorktreeArtworkTheme(theme: theme)) }
        #expect(Set(identities.map(\.palette)).count >= 4)
        #expect(identities.allSatisfy { $0.concepts.joined().contains("low-key lighting") })
    }

    @Test("@spec LAYOUT-2.87: When generating Apple artwork for a Ghostty theme with a dark low-saturation background, the application shall lead its image prompt with a charcoal backdrop and positive low-light instructions, and use project colors when available or muted theme accents otherwise.")
    func charcoalThemeLeadsPromptWithoutWhiteBackdropHints() {
        let theme = WorktreeArtworkTheme(theme: GhosttyTheme(core: .init(
            backgroundRGB: .init(r: 40.0 / 255, g: 44.0 / 255, b: 52.0 / 255),
            foregroundRGB: .init(r: 1, g: 1, b: 1)),
            palette: [.init(r: 0.8, g: 0.4, b: 0.4), .init(r: 0.54, g: 0.75, b: 0.72)]))
        let identity = WorktreeArtworkIdentity(name: "generate-icons", theme: theme)
        #expect(identity.concepts.first?.contains("charcoal") == true)
        #expect(identity.fallbackConcepts.first?.contains("charcoal") == true)
        #expect(identity.concepts.joined().contains("low-key lighting"))
        #expect(!identity.concepts.joined().contains("white"))
        #expect(!identity.concepts.joined().contains("rich red"))
        #expect(identity.palette.contains("muted red"))
    }

    @Test("The background prompt follows other configured colors instead of imposing charcoal")
    func otherThemeColorsRemainDistinct() {
        let violet = WorktreeArtworkTheme(theme: GhosttyTheme(backgroundRGB: .init(r: 0.2, g: 0.04, b: 0.3),
            foregroundRGB: .init(r: 1, g: 1, b: 1)))
        let light = WorktreeArtworkTheme(theme: GhosttyTheme(backgroundRGB: .init(r: 1, g: 1, b: 1),
            foregroundRGB: .init(r: 0, g: 0, b: 0)))
        #expect(violet.backgroundConcept.contains("violet"))
        #expect(!violet.backgroundConcept.contains("charcoal"))
        #expect(light.backgroundConcept.contains("white"))
        #expect(light.backgroundConcept.contains("soft daylight"))
        #expect(!light.backgroundConcept.contains("charcoal"))
    }

    @Test("@spec LAYOUT-2.78: When generating worktree artwork with an available on-device language model, the application shall first translate the worktree name and user-authored task context into a concrete English visual description and use its deterministic visual fallback if translation is unavailable or fails.")
    @MainActor
    func languageModelTranslatesNameBeforeImageGeneration() async throws {
        var receivedName: String?
        let identity = try await WorktreeArtworkPrompt.identity(for: "claude-notifications", userContext: "Notify me when a train is arriving") { name in
            receivedName = name
            return "a ringing brass bell with radiating sound waves"
        }
        #expect(receivedName?.contains("claude-notifications") == true)
        #expect(receivedName?.contains("Notify me when a train is arriving") == true)
        #expect(identity.concepts.joined().contains("ringing brass bell"))
        #expect(!identity.concepts.joined().contains("claude"))
        #expect(identity.palette == WorktreeArtworkIdentity(name: "claude-notifications").palette)
    }

    @Test @MainActor
    func unavailableFailedAndInvalidTranslationsUseFallback() async throws {
        let expected = WorktreeArtworkIdentity(name: "opaque-123")
        let failed = try await WorktreeArtworkPrompt.identity(for: "opaque-123") { _ in throw ImageCreatorWorktreeIcon.Failure.invalidImage }
        #expect(failed == expected)
        for description: String? in [nil, "   ", "铃铛", String(repeating: "word ", count: 60)] {
            let result = try await WorktreeArtworkPrompt.identity(for: "opaque-123") { _ in description }
            #expect(result == expected)
        }
    }

    @Test @MainActor
    func cancelledTranslationDoesNotStartFallback() async {
        do {
            _ = try await WorktreeArtworkPrompt.identity(for: "test") { _ in throw CancellationError() }
            Issue.record("Expected cancellation")
        } catch {
            #expect(error is CancellationError)
        }
    }

    @Test("@spec LAYOUT-2.76: If ImageCreator rejects an artwork description or fails creation, then the application shall retry once with a shorter English subject description, without retrying cancellation or device unavailability.")
    @MainActor
    func rejectedPromptRetriesOnce() async throws {
        guard #available(macOS 15.4, *) else { return }
        var errors: [ImageCreator.Error] = [.unsupportedLanguage, .creationFailed]
        if #available(macOS 26.0, *) { errors.append(.conceptsRequirePersonIdentity) }
        for error in errors {
            var requests: [[String]] = []
            let output = Data([1, 2, 3])
            let result = try await ImageCreatorWorktreeIcon.generate(identity: WorktreeArtworkIdentity(name: "wf_ec05fbc1-baf-2")) { concepts in
                requests.append(concepts)
                if requests.count == 1 { throw error }
                return output
            }
            #expect(result == output)
            #expect(requests.count == 2)
            #expect(requests[0] != requests[1])
            #expect(requests[1].joined().count < requests[0].joined().count)
        }
    }

    @Test @MainActor
    func retryIsBoundedAndUnavailabilityDoesNotRetry() async {
        guard #available(macOS 15.4, *) else { return }
        for (error, expectedCalls) in [(ImageCreator.Error.creationFailed, 2), (.unavailable, 1), (.creationCancelled, 1)] {
            var calls = 0
            do {
                _ = try await ImageCreatorWorktreeIcon.generate(identity: WorktreeArtworkIdentity(name: "test")) { _ in
                    calls += 1
                    throw error
                }
                Issue.record("Expected generation to fail")
            } catch { }
            #expect(calls == expectedCalls)
        }
    }

    @Test("@spec LAYOUT-2.77: While a worktree has no generated map, the application shall retain its normal background without a project-avatar placeholder.")
    @MainActor
    func mainWaitsForMapWithoutProjectIconPlaceholder() throws {
        let icon = NSImage(size: NSSize(width: 4, height: 4))
        icon.lockFocus()
        NSColor.orange.setFill()
        NSRect(x: 0, y: 0, width: 4, height: 4).fill()
        icon.unlockFocus()
        let data = try #require(icon.tiffRepresentation)
        #expect(WorktreeArtworkBackground.resolveImage(isMainCheckout: true, projectIcon: data, generated: nil) == nil)
        #expect(WorktreeArtworkBackground.resolveImage(isMainCheckout: true, projectIcon: nil, generated: icon) === icon)
        #expect(WorktreeArtworkBackground.resolveImage(isMainCheckout: true, projectIcon: data, generated: icon) === icon)
        #expect(WorktreeArtworkBackground.resolveImage(isMainCheckout: false, projectIcon: data, generated: icon) === icon)
    }
}
