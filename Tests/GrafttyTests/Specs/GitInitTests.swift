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
}
