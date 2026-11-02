import Foundation
import Testing
@testable import GrafttyProtocol

struct ViewerAgentLaunchTests {
    @Test("@spec GIT-5.37: When a worktree creation request specifies an agent or task, the application shall use a distinct request type so older hosts reject the request rather than silently discard its configuration.")
    func configuredCreationUsesDistinctRequestType() throws {
        for agent in [WorktreeAgentConfiguration(provider: "claude"), .init(taskDescription: "Fix this.\nThen test.")] {
            let request = WorktreeManagementRequest.create(repositoryID: "repo", worktreeName: "feature",
                branchName: "feature", existingSource: nil, agent: agent)
            let data = try JSONEncoder().encode(request)
            let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            #expect(object["type"] as? String == "create_with_agent")
            #expect(try JSONDecoder().decode(WorktreeManagementRequest.self, from: data) == request)
        }
        let legacy = WorktreeManagementRequest.create(repositoryID: "repo", worktreeName: "feature",
            branchName: "feature", existingSource: nil)
        let object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(legacy)) as? [String: Any])
        #expect(object["type"] as? String == "create")
    }

    @Test("@spec GIT-5.35: When a client creates a worktree with an agent choice and optional task description, the application shall preserve the provider and exact multiline description across transport and use the destination's default agent when the provider is omitted.")
    func creationPreservesAgentAndTask() throws {
        let prompt = "Fix the tests.\nKeep $(literal syntax).\n"
        for provider in [nil, "codex", "claude"] as [String?] {
            var agent: [String: Any] = ["taskDescription": prompt]
            agent["provider"] = provider
            let object: [String: Any] = ["type": "create", "repositoryID": "repo", "worktreeName": "feature",
                "branchName": "feature", "agent": agent]
            let request = try JSONDecoder().decode(WorktreeManagementRequest.self, from: JSONSerialization.data(withJSONObject: object))
            let result = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any])
            let encoded = try #require(result["agent"] as? [String: Any])
            #expect(encoded["provider"] as? String == provider)
            #expect(encoded["taskDescription"] as? String == prompt)
            #expect(result["launchDefaultAgent"] as? Bool == true)
        }
    }

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

    @Test("@spec IOS-9.18: When a paired client creates a worktree, the application shall request its host's default agent as the first session unless the request explicitly selects shell-only creation.")
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
        #expect(result["launchDefaultAgent"] as? Bool == true)
    }
}
