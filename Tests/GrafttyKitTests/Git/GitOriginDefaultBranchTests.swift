import Testing
import Foundation
@testable import GrafttyKit

@Suite("GitOriginDefaultBranch", .serialized)
struct GitOriginDefaultBranchTests {

    func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("graftty-origin-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @discardableResult
    func shell(_ command: String, at dir: URL) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-c", command]
        process.currentDirectoryURL = dir
        process.environment = [
            "PATH": "/usr/bin:/bin:/usr/local/bin",
            "HOME": NSHomeDirectory(),
            "GIT_AUTHOR_NAME": "Test",
            "GIT_AUTHOR_EMAIL": "test@test.com",
            "GIT_COMMITTER_NAME": "Test",
            "GIT_COMMITTER_EMAIL": "test@test.com",
        ]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }

    @Test func returnsNilWhenNoRemote() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try shell("git init -b main && git commit --allow-empty -m init", at: dir)

        let result = await GitOriginDefaultBranch.resolve(repoPath: dir.path)
        #expect(result == nil)
    }

    @Test func resolvesViaSymbolicRefWhenOriginHeadIsSet() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let upstream = root.appendingPathComponent("upstream.git")
        let clone = root.appendingPathComponent("clone")

        // A bare upstream with a 'main' branch, then clone it. The clone
        // will have refs/remotes/origin/HEAD pointing to origin/main.
        try FileManager.default.createDirectory(at: upstream, withIntermediateDirectories: true)
        try shell("git init --bare -b main", at: upstream)
        let seed = root.appendingPathComponent("seed")
        try FileManager.default.createDirectory(at: seed, withIntermediateDirectories: true)
        try shell("""
            git init -b main && \
            git commit --allow-empty -m init && \
            git remote add origin \(upstream.path) && \
            git push -u origin main
            """, at: seed)
        try shell("git clone \(upstream.path) \(clone.path)", at: root)

        let result = await GitOriginDefaultBranch.resolve(repoPath: clone.path)
        #expect(result == "main")
    }

    @Test func fallsBackToProbingMainWhenSymbolicRefMissing() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let upstream = root.appendingPathComponent("upstream.git")
        let clone = root.appendingPathComponent("clone")

        try FileManager.default.createDirectory(at: upstream, withIntermediateDirectories: true)
        try shell("git init --bare -b main", at: upstream)
        let seed = root.appendingPathComponent("seed")
        try FileManager.default.createDirectory(at: seed, withIntermediateDirectories: true)
        try shell("""
            git init -b main && \
            git commit --allow-empty -m init && \
            git remote add origin \(upstream.path) && \
            git push -u origin main
            """, at: seed)
        try shell("git clone \(upstream.path) \(clone.path)", at: root)

        // Remove the symbolic ref so only the probe fallback can succeed.
        try shell("git remote set-head origin --delete", at: clone)

        let result = await GitOriginDefaultBranch.resolve(repoPath: clone.path)
        #expect(result == "main")
    }

    @Test func fallsBackToMasterIfNoMain() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let upstream = root.appendingPathComponent("upstream.git")
        let clone = root.appendingPathComponent("clone")

        try FileManager.default.createDirectory(at: upstream, withIntermediateDirectories: true)
        try shell("git init --bare -b master", at: upstream)
        let seed = root.appendingPathComponent("seed")
        try FileManager.default.createDirectory(at: seed, withIntermediateDirectories: true)
        try shell("""
            git init -b master && \
            git commit --allow-empty -m init && \
            git remote add origin \(upstream.path) && \
            git push -u origin master
            """, at: seed)
        try shell("git clone \(upstream.path) \(clone.path)", at: root)
        try shell("git remote set-head origin --delete", at: clone)

        let result = await GitOriginDefaultBranch.resolve(repoPath: clone.path)
        #expect(result == "master")
    }
}
