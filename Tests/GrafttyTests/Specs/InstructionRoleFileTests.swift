import Foundation
import Testing
@testable import GrafttyKit

@Suite("@spec INSTR-8.1: When the user edits a pinned agent's role instructions, the application shall open its effective exact-worktree instruction file using normal precedence and legacy aliases, or create an empty GRAFTTY.md in the main checkout when no such file exists.")
struct InstructionRoleFileTests {
    @Test func unkeyedFileRejectsShadowingAndUnresolvedDefaultBranch() async throws {
        let fixture = try InstructionFilesystemFixture()
        defer { fixture.remove() }
        let app = try fixture.write("App policy", root: fixture.applicationSupport, relativePath: "GRAFTTY.md")
        do {
            _ = try await InstructionStore.prepareRoleFile(key: nil, repoPath: fixture.repo.path,
                worktreePath: fixture.worktree.path, applicationSupportDirectory: fixture.applicationSupport)
            Issue.record("Shadowed local instructions should not be edited")
        } catch {
            #expect(error.localizedDescription.contains(app.path))
        }
        #expect(!FileManager.default.fileExists(atPath: fixture.worktree.appendingPathComponent(".graftty/GRAFTTY.md").path))
        #expect(try String(contentsOf: app, encoding: .utf8) == "App policy")
        await #expect(throws: (any Error).self) {
            try await InstructionStore.prepareRoleFile(key: nil, repoPath: fixture.repo.path,
                worktreePath: fixture.repo.path, applicationSupportDirectory: fixture.applicationSupport)
        }
        #expect(!FileManager.default.fileExists(atPath: fixture.repo.appendingPathComponent(".graftty/GRAFTTY.md").path))
    }

    @Test("@spec INSTR-8.3: If a pinned worktree has no instruction role key, then the application shall edit its local base GRAFTTY.md or create it when absent, reject Application Support overrides, and leave wider instruction scopes unchanged.")
    func unkeyedWorktreeUsesItsOwnBaseInstructions() async throws {
        let fixture = try InstructionFilesystemFixture()
        defer { fixture.remove() }
        let repo = try fixture.write("Repository policy", root: fixture.repo, relativePath: "GRAFTTY.md")
        let file = try await InstructionStore.prepareRoleFile(key: nil, repoPath: fixture.repo.path,
            worktreePath: fixture.worktree.path, applicationSupportDirectory: fixture.applicationSupport)
        #expect(file == fixture.worktree.appendingPathComponent(".graftty/GRAFTTY.md"))
        #expect(try String(contentsOf: file, encoding: .utf8) == "# Role\n\n")
        #expect(try String(contentsOf: repo, encoding: .utf8) == "Repository policy")
        try "Local role".write(to: file, atomically: true, encoding: .utf8)
        let reopened = try await InstructionStore.prepareRoleFile(key: nil, repoPath: fixture.repo.path,
            worktreePath: fixture.worktree.path, applicationSupportDirectory: fixture.applicationSupport)
        #expect(reopened == file)
        #expect(try String(contentsOf: file, encoding: .utf8) == "Local role")
        let loaded = await InstructionStore.load(repoPath: fixture.repo.path, worktreePath: fixture.worktree.path,
            applicationSupportDirectory: fixture.applicationSupport, budget: .seconds(10))
        #expect(loaded?.sourcePaths["GRAFTTY.md"] == file.path)
        #expect(loaded?.documents["GRAFTTY.md"]?.shared == "Local role")
    }

    private func prepare(_ fixture: InstructionFilesystemFixture, key: String = "feature-login") async throws -> URL {
        try await InstructionStore.prepareRoleFile(key: key, repoPath: fixture.repo.path,
            worktreePath: fixture.worktree.path, applicationSupportDirectory: fixture.applicationSupport)
    }

    @Test func createsRoleFileOnlyWhenRequestedAndLoadsIt() async throws {
        let fixture = try InstructionFilesystemFixture()
        defer { fixture.remove() }
        let inherited = try fixture.write("Shared policy", root: fixture.repo, relativePath: "GRAFTTY.md")
        let file = try await prepare(fixture)
        #expect(file.path == fixture.repo.appendingPathComponent(".graftty/feature-login/GRAFTTY.md").path)
        #expect(try String(contentsOf: file, encoding: .utf8) == "# Role\n\n")
        #expect(try String(contentsOf: inherited, encoding: .utf8) == "Shared policy")
        try "Release manager responsibilities\n".write(to: file, atomically: true, encoding: .utf8)
        let reopened = try await prepare(fixture)
        #expect(reopened == file)
        #expect(try String(contentsOf: file, encoding: .utf8) == "Release manager responsibilities\n")
        let instructions = await InstructionStore.load(repoPath: fixture.repo.path, worktreePath: fixture.worktree.path,
            applicationSupportDirectory: fixture.applicationSupport, budget: .seconds(10))
        #expect(instructions?.documents["feature-login/GRAFTTY.md"]?.shared == "Release manager responsibilities")
        let team = try fixture.makeTeam()
        let peer = try #require(team.members.first { $0.worktreePath == fixture.repo.path })
        let peerInstructions = await InstructionSessionText.render(team: team, viewer: peer, defaultBranch: "main",
            applicationSupportDirectory: fixture.applicationSupport, loadBudget: .seconds(10))
        #expect(peerInstructions.contains("Release manager responsibilities"))
    }

    @Test func defaultBranchRoleUsesResolvedBranchKey() async throws {
        let fixture = try InstructionFilesystemFixture()
        defer { fixture.remove() }
        let key = try #require(InstructionKey.key(worktreePath: fixture.repo.path,
            repoPath: fixture.repo.path, defaultBranch: "trunk"))
        let file = try await InstructionStore.prepareRoleFile(key: key, repoPath: fixture.repo.path,
            worktreePath: fixture.repo.path, applicationSupportDirectory: fixture.applicationSupport)
        #expect(file == fixture.repo.appendingPathComponent(".graftty/trunk/GRAFTTY.md"))
        try "Integration agent\n\n## Private\nDefault-branch checks".write(to: file, atomically: true, encoding: .utf8)
        let team = try fixture.makeTeam()
        let viewer = try #require(team.members.first { $0.worktreePath == fixture.repo.path })
        let instructions = await InstructionSessionText.render(team: team, viewer: viewer, defaultBranch: "trunk",
            applicationSupportDirectory: fixture.applicationSupport, loadBudget: .seconds(10))
        #expect(instructions.contains("Integration agent"))
        #expect(instructions.contains("Default-branch checks"))
    }

    @Test func opensEffectiveFileWithoutCreatingShadows() async throws {
        let fixture = try InstructionFilesystemFixture()
        defer { fixture.remove() }
        let main = try fixture.write("Main role", root: fixture.repo, relativePath: "feature-login/GRAFTTY.md")
        #expect(try await prepare(fixture) == main)
        let local = try fixture.write("Local role", root: fixture.worktree, relativePath: "feature-login/GRAFTTY.md")
        #expect(try await prepare(fixture) == local)
        let app = try fixture.write("App role", root: fixture.applicationSupport, relativePath: "feature-login/GRAFTTY.md")
        #expect(try await prepare(fixture) == app)
        #expect(try String(contentsOf: main, encoding: .utf8) == "Main role")
        #expect(try String(contentsOf: local, encoding: .utf8) == "Local role")
        #expect(try String(contentsOf: app, encoding: .utf8) == "App role")
    }

    @Test func opensLegacyAliasWithoutMigratingIt() async throws {
        let fixture = try InstructionFilesystemFixture()
        defer { fixture.remove() }
        let legacy = try fixture.write("Legacy role", root: fixture.repo, relativePath: "GRAFTTY.feature-login.md")
        #expect(try await prepare(fixture) == legacy)
        #expect(!FileManager.default.fileExists(atPath: fixture.worktree.appendingPathComponent(".graftty/feature-login/GRAFTTY.md").path))
    }

    @Test func refusesSymlinkedDirectoryAndInvalidKey() async throws {
        let fixture = try InstructionFilesystemFixture()
        defer { fixture.remove() }
        let outside = fixture.root.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: fixture.repo.appendingPathComponent(".graftty"), withDestinationURL: outside)
        await #expect(throws: (any Error).self) { try await prepare(fixture) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
        await #expect(throws: (any Error).self) { try await prepare(fixture, key: "../escape") }
    }
}
