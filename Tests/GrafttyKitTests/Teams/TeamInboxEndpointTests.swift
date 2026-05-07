import Foundation
import Testing
@testable import GrafttyKit

@Suite("TeamInboxEndpoint")
struct TeamInboxEndpointTests {
    @Test("@spec TEAM-5.4: When constructing a system endpoint, the application shall produce an endpoint with member='system', worktree=<repoPath>, and runtime=nil.")
    func systemEndpointShape() {
        let endpoint = TeamInboxEndpoint.system(repoPath: "/repo")
        #expect(endpoint.member == "system")
        #expect(endpoint.worktree == "/repo")
        #expect(endpoint.runtime == nil)
    }

    @Test("system endpoint round-trips through Codable")
    func systemEndpointCodable() throws {
        let endpoint = TeamInboxEndpoint.system(repoPath: "/repo")
        let data = try JSONEncoder().encode(endpoint)
        let decoded = try JSONDecoder().decode(TeamInboxEndpoint.self, from: data)
        #expect(decoded == endpoint)
    }
}
