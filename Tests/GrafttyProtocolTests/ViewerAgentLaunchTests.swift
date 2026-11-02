import Foundation
import Testing
@testable import GrafttyProtocol

struct ViewerAgentLaunchTests {
    @Test("@spec AGENT-6.148: When a paired viewer adds an agent, the application shall round-trip the worktree identity, optional provider, and stable launch operation ID independently of any existing pane.", arguments: ["codex", "claude", nil] as [String?])
    func launchWithoutPaneRoundTrips(provider: String?) throws {
        var object: [String: Any] = ["type": "add_agent", "worktreeID": "opaque-worktree", "operationID": UUID().uuidString]
        object["provider"] = provider
        let request = try JSONDecoder().decode(WorktreeManagementRequest.self, from: JSONSerialization.data(withJSONObject: object))
        let encoded = try JSONEncoder().encode(request)
        let result = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: String])
        #expect(result == object as? [String: String])
        #expect(try JSONDecoder().decode(WorktreeManagementRequest.self, from: encoded) == request)
    }

    @Test("@spec IOS-9.18: When an iPhone or iPad creates a worktree, the application shall request its host's default agent as the first session while preserving shell-only creation for clients that do not request an agent.")
    func creationCarriesDefaultAgentIntent() throws {
        for launch in [false, true] {
            let object: [String: Any] = ["type": "create", "repositoryID": "repo", "worktreeName": "feature",
                "branchName": "feature", "launchDefaultAgent": launch]
            let request = try JSONDecoder().decode(WorktreeManagementRequest.self, from: JSONSerialization.data(withJSONObject: object))
            let encoded = try JSONEncoder().encode(request)
            let result = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
            #expect(result["launchDefaultAgent"] as? Bool == launch)
        }
        let old = Data(#"{"type":"create","repositoryID":"repo","worktreeName":"feature","branchName":"feature"}"#.utf8)
        let request = try JSONDecoder().decode(WorktreeManagementRequest.self, from: old)
        let result = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any])
        #expect(result["launchDefaultAgent"] as? Bool == false)
    }
}
