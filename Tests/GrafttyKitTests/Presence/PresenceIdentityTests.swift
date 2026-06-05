import Testing
import Foundation
@testable import GrafttyKit

@Suite("PresenceIdentity — slug and probe")
struct PresenceIdentityTests {
    @Test("@spec SYNC-1.3: The application shall derive the presence slug from the git user.email by lowercasing and replacing each run of non-alphanumeric characters with a single hyphen.")
    func slugDerivation() {
        #expect(PresenceIdentity.slug(forEmail: "ben@btucker.net") == "ben-btucker-net")
        #expect(PresenceIdentity.slug(forEmail: "Sarah.O'Neil+work@Example.COM") == "sarah-o-neil-work-example-com")
        #expect(PresenceIdentity.slug(forEmail: "--weird--@x.io") == "weird-x-io")
    }

    @Test("load reads user.name and user.email from the repo's git config.")
    func loadProbesGitConfig() async throws {
        let dir = try makeTempDir(prefix: "graftty-identity")
        defer { try? FileManager.default.removeItem(at: dir) }
        try shellInRepo("git init -b main && git config user.name 'Sarah' && git config user.email 'sarah@example.com'", at: dir)

        let identity = try await PresenceIdentity.load(repoPath: dir.path)
        #expect(identity.name == "Sarah")
        #expect(identity.email == "sarah@example.com")
        #expect(identity.slug == "sarah-example-com")
    }

    @Test("load throws when user.email is not configured.")
    func loadThrowsWithoutEmail() async throws {
        let dir = try makeTempDir(prefix: "graftty-identity-missing")
        defer { try? FileManager.default.removeItem(at: dir) }
        try shellInRepo("git init -b main", at: dir)

        await #expect(throws: (any Error).self) {
            _ = try await PresenceIdentity.load(repoPath: dir.path, scope: .local)
        }
    }
}
