import Foundation
import Testing
@testable import GrafttyProtocol

struct RemoteProjectOrderTests {
    @Test("@spec LAYOUT-2.152: When a host publishes a project's worktree order mode, the application shall retain that optional mode as its sorting capability while decoding older projects without it as unsupported.")
    func modeMetadataIsOptionalAndRoundTrips() throws {
        let legacy = Data(#"{"id":"project","repositoryID":"/repo","name":"Repo","isAvailable":true}"#.utf8)
        let old = try JSONDecoder().decode(SidebarProject.self, from: legacy)
        var json = try #require(JSONSerialization.jsonObject(with: legacy) as? [String: Any])
        json["worktreeOrderMode"] = "recentActivity"
        let current = try JSONDecoder().decode(SidebarProject.self, from: JSONSerialization.data(withJSONObject: json))
        let encoded = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(current)) as? [String: Any])
        #expect(encoded["worktreeOrderMode"] as? String == "recentActivity")
        let oldJSON = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(old)) as? [String: Any])
        #expect(oldJSON["worktreeOrderMode"] == nil)
    }

    @Test func orderRequestRoundTrips() throws {
        let wire = Data(#"{"type":"set_worktree_order","repositoryID":"opaque-repository","mode":"recentActivity"}"#.utf8)
        let request = try JSONDecoder().decode(WorktreeManagementRequest.self, from: wire)
        #expect(try JSONDecoder().decode(WorktreeManagementRequest.self, from: JSONEncoder().encode(request)) == request)
        let encoded = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any])
        #expect(encoded["repositoryID"] as? String == "opaque-repository")
        #expect(encoded["mode"] as? String == "recentActivity")
    }
}
