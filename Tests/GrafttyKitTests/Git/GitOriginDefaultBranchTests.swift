import Testing
import Foundation
@testable import GrafttyKit
import GrafttyTestSupport

@Suite("GitOriginDefaultBranch", .serialized)
struct GitOriginDefaultBranchTests {

    @Test func returnsNilWhenNoRemote() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(try shellInRepo("git init -b main && git commit --allow-empty -m init", at: dir) == 0)

        let result = await GitOriginDefaultBranch.resolve(repoPath: dir.path)
        #expect(result == nil)
    }

    @Test func resolvesViaSymbolicRefWhenOriginHeadIsSet() async throws {
        // The clone has refs/remotes/origin/HEAD pointing to origin/main.
        let (root, clone, _) = try makeClonedRepo()
        defer { try? FileManager.default.removeItem(at: root) }

        let result = await GitOriginDefaultBranch.resolve(repoPath: clone.path)
        #expect(result == "main")
    }

    @Test func fallsBackToProbingMainWhenSymbolicRefMissing() async throws {
        let (root, clone, _) = try makeClonedRepo()
        defer { try? FileManager.default.removeItem(at: root) }

        // Remove the symbolic ref so only the probe fallback can succeed.
        #expect(try shellInRepo("git remote set-head origin --delete", at: clone) == 0)

        let result = await GitOriginDefaultBranch.resolve(repoPath: clone.path)
        #expect(result == "main")
    }

    @Test func fallsBackToMasterIfNoMain() async throws {
        let (root, clone, _) = try makeClonedRepo(defaultBranch: "master")
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(try shellInRepo("git remote set-head origin --delete", at: clone) == 0)

        let result = await GitOriginDefaultBranch.resolve(repoPath: clone.path)
        #expect(result == "master")
    }
}
