import Foundation
import Testing
@testable import GrafttyKit

struct RemoteWorktreeDefaultAgentTests {
    @Test("@spec GIT-5.39: When a remote CLI requests worktree creation with the destination's default agent, the application shall use a distinct request type so older hosts reject the request rather than create a shell-only worktree.")
    func defaultAgentRequiresNewWireType() throws {
        for options in [(nil, nil), ("echo hello", nil), (nil, TeamHookRuntime.claude)] as [(String?, TeamHookRuntime?)] {
            let request = RemoteWorktreeRequest.create(.init(callerWorktree: "/source", project: "repo",
                worktreeName: "feature", branchName: "feature", existing: false, base: nil,
                command: options.0, agentRuntime: options.1, agentPrompt: nil, operationID: "operation"))
            let data = try JSONEncoder().encode(request)
            let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let usesDefault = options.0 == nil && options.1 == nil
            #expect(Set(object.keys) == [usesDefault ? "createDefaultAgent" : "create"])
            #expect(try JSONDecoder().decode(RemoteWorktreeRequest.self, from: data) == request)
            if usesDefault {
                #expect(throws: (any Error).self) { try JSONDecoder().decode(LegacyRequest.self, from: data) }
            } else {
                _ = try JSONDecoder().decode(LegacyRequest.self, from: data)
            }
        }
    }

    private enum LegacyRequest: Codable {
        case create(RemoteWorktreeCreation)
        case status(operationID: String)
    }
}
