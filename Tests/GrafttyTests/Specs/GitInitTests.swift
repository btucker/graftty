import Darwin
import Foundation
import Testing
@testable import GrafttyKit

@Suite("@spec GIT-1.6: When the user chooses Initialize Git Repository at add-time, the application shall run `git init` followed by `git commit --allow-empty -m \"Initial commit\"` in the folder, then proceed through the standard Add Repository flow.")
struct GitInitTests {
    @Test("`GitInit.run` produces a .git directory and one commit")
    func initCreatesRepoWithOneCommit() async throws {
        // Skip when `git` isn't on PATH — matches the pattern other
        // git-touching tests in this suite use.
        guard FileManager.default.fileExists(atPath: "/usr/bin/git") ||
              FileManager.default.fileExists(atPath: "/opt/homebrew/bin/git") ||
              FileManager.default.fileExists(atPath: "/usr/local/bin/git") else {
            return
        }

        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("graftty-gitinit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        try await GitInit.run(at: tmpDir.path)

        var isDir: ObjCBool = false
        let gitExists = FileManager.default.fileExists(
            atPath: tmpDir.appendingPathComponent(".git").path,
            isDirectory: &isDir
        )
        #expect(gitExists)
        #expect(isDir.boolValue)

        let log = try await GitRunner.run(args: ["log", "--oneline"], at: tmpDir.path)
        let lines = log.split(separator: "\n").filter { !$0.isEmpty }
        #expect(lines.count == 1)
    }

    @Test("`GitInit.run` preserves the user's git identity when configured")
    func initRespectsConfiguredIdentity() async throws {
        guard FileManager.default.fileExists(atPath: "/usr/bin/git") ||
              FileManager.default.fileExists(atPath: "/opt/homebrew/bin/git") ||
              FileManager.default.fileExists(atPath: "/usr/local/bin/git") else {
            return
        }

        // Simulate "configured-user machine" via GIT_CONFIG_GLOBAL (git
        // >= 2.32) pointing at a temp config file with [user] block, so
        // GitInit's `git config user.email` probe sees a value and the
        // ephemeral `-c user.email=noreply@graftty.local` override is
        // suppressed.
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("graftty-gitinit-id-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let configFile = tmpDir.appendingPathComponent(".testgitconfig")
        try "[user]\n\tname = Test User\n\temail = test@example.com\n"
            .write(to: configFile, atomically: true, encoding: .utf8)

        setenv("GIT_CONFIG_GLOBAL", configFile.path, 1)
        defer { unsetenv("GIT_CONFIG_GLOBAL") }

        let repoDir = tmpDir.appendingPathComponent("repo")
        try FileManager.default.createDirectory(at: repoDir, withIntermediateDirectories: true)

        try await GitInit.run(at: repoDir.path)

        let author = try await GitRunner.run(
            args: ["log", "--format=%ae", "-1"], at: repoDir.path
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(author == "test@example.com")
    }
}
