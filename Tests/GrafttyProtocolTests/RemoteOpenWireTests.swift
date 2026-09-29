import Foundation
import Testing
@testable import GrafttyProtocol

struct RemoteOpenWireTests {
    @Test func requestAndReplyRoundTrips() throws {
        let id = UUID()
        let requests: [WorktreeManagementRequest] = [
            .openResource(worktreeID: "/project", request: .list),
            .openResource(worktreeID: "relay-worktree-123", request: .read(id: id, offset: 4096))
        ]
        for request in requests {
            #expect(try JSONDecoder().decode(WorktreeManagementRequest.self, from: JSONEncoder().encode(request)) == request)
        }
        let responses: [WorktreeManagementResponse] = [
            .openResource(.offers([.init(id: id, filename: "test.csv", byteCount: 3)])),
            .openResource(.chunk(Data([0, 128, 255])))
        ]
        for response in responses {
            #expect(try JSONDecoder().decode(WorktreeManagementResponse.self, from: JSONEncoder().encode(response)) == response)
        }
    }
}
