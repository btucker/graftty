import Foundation
import Testing
@testable import GrafttyKit

struct ProjectRegistrationTests {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("project-registration-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("@spec PROJECT-1.6: When a local Git repository is registered, the application shall discover its worktrees and default branch without requiring or creating a commit.")
    func unbornRepository() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try await GitRunner.run(args: ["init", "-b", "trunk"], at: root.path)
        let prepared = try await ProjectRegistration.prepare(path: root.path)
        #expect(prepared.repo.path == CanonicalPath.canonicalize(root.path))
        #expect(prepared.repo.defaultBranchHint == "trunk")
        #expect(prepared.repo.worktrees.map(\.branch) == ["trunk"])
        #expect(prepared.repo.isGitTracked)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(".git/refs/heads/trunk").path))
    }

    @Test("@spec PROJECT-1.7: When a project is registered through a linked worktree or a symlink, the application shall register the canonical repository once and preserve existing project and pane state on repeated additions.")
    func linkedWorktreeAndDuplicate() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = root.appendingPathComponent("repo")
        let linked = root.appendingPathComponent("linked")
        let alias = root.appendingPathComponent("alias")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        _ = try await GitRunner.run(args: ["init", "-b", "trunk"], at: repo.path)
        _ = try await GitRunner.run(args: ["-c", "user.name=Test", "-c", "user.email=test@example.com", "commit", "--allow-empty", "-m", "initial"], at: repo.path)
        _ = try await GitRunner.run(args: ["worktree", "add", "-b", "feature", linked.path], at: repo.path)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: linked)
        let first = try await ProjectRegistration.prepare(path: alias.path)
        #expect(first.repo.path == CanonicalPath.canonicalize(repo.path))
        #expect(first.selectedWorktreePath == CanonicalPath.canonicalize(linked.path))
        #expect(first.repo.worktrees.count == 2)
        var state = AppState()
        first.apply(to: &state)
        state.repos[0].displayName = "Custom project"
        let slot = PaneSlotID()
        state.repos[0].worktrees[0].state = .running
        state.repos[0].worktrees[0].splitTree = SplitTree(root: .leaf(slot))
        _ = state.repos[0].worktrees[0].ensurePaneSession(for: slot)
        state.selectedWorktreePath = first.selectedWorktreePath
        let original = state
        let duplicate = try await ProjectRegistration.prepare(path: repo.path)
        duplicate.apply(to: &state)
        first.apply(to: &state)
        #expect(state == original)
    }

    @Test func malformedRepositoryIncludesGitDiagnostic() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".git"), withIntermediateDirectories: true)
        do {
            _ = try await ProjectRegistration.prepare(path: root.path)
            Issue.record("malformed repository was accepted")
        } catch {
            #expect(error.localizedDescription.contains("not a git repository"))
        }
    }

    @Test("@spec PROJECT-1.8: If a project path is missing, is a file, or is not in a Git repository, then project registration shall return an actionable error without initializing Git or changing app state.")
    func invalidPaths() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("file")
        try Data().write(to: file)
        for path in [root.path, file.path, root.appendingPathComponent("missing").path] {
            do {
                _ = try await ProjectRegistration.prepare(path: path)
                Issue.record("invalid path was accepted: \(path)")
            } catch {
                #expect(!error.localizedDescription.isEmpty)
                #expect(error.localizedDescription.contains(path))
            }
        }
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(".git").path))
    }
}
