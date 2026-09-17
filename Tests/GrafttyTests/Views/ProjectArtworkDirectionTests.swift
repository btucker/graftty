import Foundation
import Darwin
import Combine
import GrafttyKit
import Testing
@testable import Graftty

@Suite("Project artwork direction")
@MainActor
struct ProjectArtworkDirectionTests {
    @Test("@spec LAYOUT-2.95: When generating worktree backgrounds, the application shall reuse a project metaphor category derived from bounded codebase context and the resolved project avatar, with distinct task-specific subjects inside that category.")
    func reusesDirectionAcrossWorktreesAndLaunches() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var calls = 0
        let source = ProjectArtworkSource(path: "/example", avatar: nil)
        let store = ProjectArtworkDirectionStore(directory: directory) { _ in
            calls += 1
            return .harbor
        }
        #expect(try await store.direction(for: source) == .harbor)
        #expect(try await store.direction(for: source) == .harbor)
        let restored = ProjectArtworkDirectionStore(directory: directory) { _ in
            calls += 1
            return .fallback
        }
        #expect(try await restored.direction(for: source) == .harbor)
        #expect(calls == 1)
        #expect(try await restored.direction(for: .init(path: "/another", avatar: nil)) == .fallback)
        #expect(calls == 2)
    }

    @Test("@spec LAYOUT-2.96: When a project's resolved avatar changes, the application shall use a separate cached art direction; cancelled inference shall not publish or cache a direction.")
    func avatarRevisionAndCancellation() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var calls = 0
        let store = ProjectArtworkDirectionStore(directory: directory) { _ in
            calls += 1
            if calls == 1 { throw CancellationError() }
            return .harbor
        }
        let source = ProjectArtworkSource(path: "/project", avatar: nil)
        await #expect(throws: CancellationError.self) { try await store.direction(for: source) }
        #expect(try await store.direction(for: source) == .harbor)
        #expect(try await store.direction(for: .init(path: source.path, avatar: Data([1]))) == .harbor)
        #expect(calls == 3)
    }

    @Test func malformedInferenceUsesOneStableFallback() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var calls = 0
        let store = ProjectArtworkDirectionStore(directory: directory) { _ in
            calls += 1
            return ProjectArtworkDirection(category: "", character: "", colors: [], subjects: [])
        }
        let source = ProjectArtworkSource(path: "/project", avatar: nil)
        #expect(try await store.direction(for: source) == .fallback)
        #expect(try await store.direction(for: source) == .fallback)
        #expect(calls == 1)
    }
    @Test("@spec LAYOUT-2.98: When project avatar resolution completes, the application shall make artwork requests eligible even if an override change resolves to the same image or no image.", .timeLimit(.minutes(1)))
    func unchangedAvatarPublishesResolvedReadiness() async throws {
        let host = SidebarHostController()
        var repo = RepoEntry(path: "/missing-project", displayName: "Example")
        repo.iconOverride = .initials("A")
        var publications = 0
        let subscription = host.objectWillChange.sink { publications += 1 }
        defer { subscription.cancel() }
        host.refreshIcons([repo])
        while host.artworkSource(for: repo) == nil, !Task.isCancelled { await Task.yield() }
        #expect(host.artworkSource(for: repo) != nil)
        let before = publications
        repo.iconOverride = .initials("B")
        #expect(host.artworkSource(for: repo) == nil)
        host.refreshIcons([repo])
        while host.artworkSource(for: repo) == nil, !Task.isCancelled { await Task.yield() }
        #expect(host.artworkSource(for: repo) != nil)
        #expect(publications > before)
    }

    @Test func directionValidationPreservesRegenerationChoiceGuarantees() {
        let base = ProjectArtworkDirection.harbor
        #expect(!ProjectArtworkDirection(category: base.category, character: base.character,
            colors: ["green", "copper", "cream"], subjects: base.subjects).isValid)
        #expect(!ProjectArtworkDirection(category: base.category, character: base.character,
            colors: ["green", "green", "green", "green"], subjects: base.subjects).isValid)
        #expect(!ProjectArtworkDirection(category: base.category, character: base.character,
            colors: ["green", "copper", "cream", "blue"], subjects: base.subjects + ["wharf"]).isValid)
    }

    @Test func codebaseBriefBoundsFilesAndSkipsSymlinksAndPipes() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try String(repeating: "z", count: 100000).write(to: root.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("Package.swift"), withDestinationURL: root.appendingPathComponent("README.md"))
        #expect(mkfifo(root.appendingPathComponent("package.json").path, 0o600) == 0)
        let brief = ProjectArtworkSource(path: root.path, avatar: nil).codebaseBrief()
        let json = try #require(JSONSerialization.jsonObject(with: Data(brief.utf8)) as? [String: String])
        #expect(json["readme"]?.utf8.count == 6000)
        #expect(json["manifest"] == "")
    }

    @Test func projectFamilySurvivesBothImageProvidersAndFallback() async throws {
        let project = ProjectArtworkDirection.harbor
        let exampleNames = ["claude-notifications", "paging-through-scrollback", "graftty-crash"]
        let twelveSubjects = ProjectArtworkDirection(category: project.category, character: project.character,
            colors: project.colors, subjects: project.subjects + ["dock", "diving bell", "winch", "barrel"])
        #expect(Set(exampleNames.map { twelveSubjects.subject(name: $0, variation: 0) }).count == 3)
        #expect(Set(exampleNames.map { project.palette(name: $0, variation: 0) }).count >= 2)
        let name = "notifications"
        let theme = WorktreeArtworkTheme(theme: GhosttyTheme(core: .init(
            backgroundRGB: .init(r: 40.0/255, g: 44.0/255, b: 52.0/255), foregroundRGB: .init(r: 1, g: 1, b: 1))))
        let prompt = WorktreeArtworkGenerator.codexPrompt(name: name, userContext: "Notify when a task completes",
            style: .illustration, variation: 1, theme: theme, project: project)
        #expect(prompt.contains(project.category))
        #expect(prompt.contains(project.subject(name: name, variation: 1)))
        #expect(prompt.contains(project.palette(name: name, variation: 1)))
        #expect(prompt.contains("#282c34"))
        #expect(!prompt.contains(CodexArtworkDirection(name: name, variation: 1).subjectDirection))
        let identity = try await WorktreeArtworkPrompt.identity(for: name, userContext: "Notify when a task completes",
            variation: 1, theme: theme, project: project) { input in
                #expect(input.contains(project.category))
                throw CocoaError(.fileReadUnknown)
            }
        #expect(identity.subject == project.subject(name: name, variation: 1))
        #expect(identity.fallbackConcepts.joined().contains(project.palette(name: name, variation: 1)))
        #expect(identity.fallbackConcepts.joined().contains(identity.subject))
        #expect(project.subject(name: name, variation: 0) != project.subject(name: name, variation: 1))
    }

}

extension ProjectArtworkDirection {
    static var harbor: Self {
        .init(category: "a working harbor", character: "painted wood and brass", colors: ["sea green", "copper", "cream", "blue"],
              subjects: ["lighthouse", "tugboat", "anchor", "buoy", "crane", "compass", "sailboat", "sextant"])
    }
}
