import Foundation
import Testing
@testable import GrafttyKit

@Suite("Existing branch source resolution", .serialized)
struct GitExistingBranchSourceTests {
    @Test("Local refs win and remote-only refs remain distinguishable")
    func resolvesExactRefs() async throws {
        let fixture = try makeClonedRepo()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        #expect(try shellInRepo(
            "git branch local-feature",
            at: fixture.clone
        ) == 0)
        #expect(try shellInRepo(
            """
            git --git-dir=\(fixture.upstream.path) branch remote-feature main && \
            git fetch origin
            """,
            at: fixture.clone
        ) == 0)

        #expect(try await GitExistingBranchSource.resolve(
            repoPath: fixture.clone.path,
            branchName: "local-feature"
        ) == .local)
        #expect(try await GitExistingBranchSource.resolve(
            repoPath: fixture.clone.path,
            branchName: "remote-feature"
        ) == .remoteOnly)
        #expect(try await GitExistingBranchSource.resolve(
            repoPath: fixture.clone.path,
            branchName: "missing"
        ) == nil)
    }
}
