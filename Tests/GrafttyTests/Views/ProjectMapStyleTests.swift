import Foundation
import Testing
@testable import Graftty

@Suite @MainActor struct ProjectMapStyleTests {
    @Test("@spec LAYOUT-2.111: When repositories receive map styles, the application shall choose separate visual media before reusing a medium, persist each assignment across reordering and launches, and allow a project-specific override without changing other repositories.")
    func stylesRemainDistinctAndStableWithOverrides() throws {
        let suite = UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let styles = ProjectMapStyles(defaults: defaults)
        let paths = (0..<ProjectMapStyle.allCases.count).map { "/repo-\($0)" }
        styles.register(paths)
        let original = paths.map { styles.style(for: $0) }
        #expect(Set(original).count == paths.count)
        styles.register(["/new"] + paths.reversed())
        #expect(paths.map { styles.style(for: $0) } == original)
        styles.setOverride(.woodcut, for: paths[0])
        let restored = ProjectMapStyles(defaults: defaults)
        #expect(restored.style(for: paths[0]) == .woodcut)
        #expect(Array(paths.dropFirst()).map { restored.style(for: $0) } == Array(original.dropFirst()))
        restored.setOverride(nil, for: paths[0])
        #expect(restored.style(for: paths[0]) == original[0])
    }

    @Test func projectMediumChangesArtworkCacheAndConstrainsThePrompt() {
        var project = ProjectArtworkSource(path: "/project", avatar: nil)
        let oldKey = project.cacheKey
        project.mapStyle = .woodcut
        #expect(project.cacheKey != oldKey)
        let rows = [WorktreeMapRow(path: "task", name: "Task", height: 80, context: "Review code")]
        let input = WorktreeMapGeneration(rows: rows, project: project, style: .illustration,
            theme: nil, preservedPaths: [])
        let prompt = ProjectWorktreeMapGenerator.regionPrompt(rows[0], input: input, direction: .harbor)
        #expect(prompt.contains(ProjectMapStyle.woodcut.instructions))
        #expect(prompt.contains("No 3D render"))
    }

    @Test func appleConceptsRetainProjectMediumOnRetry() {
        let project = ProjectArtworkDirection(category: ProjectArtworkDirection.harbor.category,
            character: ProjectMapStyle.woodcut.character, colors: ProjectArtworkDirection.harbor.colors,
            subjects: ProjectArtworkDirection.harbor.subjects)
        let identity = WorktreeArtworkIdentity(name: "test", project: project)
        #expect(identity.concepts.contains(project.character))
        #expect(identity.fallbackConcepts.contains(project.character))
        #expect(project.isValid)
    }

    @Test func appleTerrainConceptsExcludeFocalObjectsEvenOnRetry() {
        var identity = WorktreeArtworkIdentity(name: "footer", project: .harbor)
        identity.terrainOnly = true
        identity.regionConcept = "Quiet terrain with no objects."
        #expect(identity.concepts.contains("Quiet terrain with no objects."))
        #expect(identity.fallbackConcepts == identity.concepts)
        #expect(!identity.concepts.joined().contains(identity.subject))
        #expect(!identity.concepts.joined().contains("Large recognizable silhouette"))
    }

    @Test func mediumDirectionSurvivesCacheReload() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = ProjectArtworkSource(path: "/project", avatar: nil, mapStyle: .woodcut)
        let store = ProjectArtworkDirectionStore(directory: directory) { _ in .harbor }
        let original = try await store.direction(for: source)
        #expect(original.character == ProjectMapStyle.woodcut.character)
        let restored = ProjectArtworkDirectionStore(directory: directory) { _ in
            Issue.record("A cached medium should not trigger inference")
            return .fallback
        }
        #expect(try await restored.direction(for: source) == original)
    }
}
