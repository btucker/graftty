import Foundation
import Testing
@testable import GrafttyProtocol

struct WorktreePortWireTests {
    @Test("@spec PORTS-5.2: When a worktree snapshot includes listening ports, the application shall preserve their process names, bind scopes, and listener addresses on the wire and treat absent ports from older hosts as an empty list.")
    func portsRoundTripAndLegacyDefaults() throws {
        let legacy = Data(#"{"path":"/project","displayName":"main","repoDisplayName":"repo"}"#.utf8)
        let old = try JSONDecoder().decode(WorktreePanes.self, from: legacy)
        #expect(old.ports.isEmpty)
        let row = WorktreePanes(path: "/project", displayName: "main", repoDisplayName: "repo",
            displayBranch: "main", state: .running, isMainCheckout: true, prBadge: nil,
            stats: nil, attentionText: nil, layout: nil,
            ports: [.init(port: 3000, scope: .loopback, processName: "vite", host: "::1")])
        #expect(try JSONDecoder().decode(WorktreePanes.self, from: JSONEncoder().encode(row)) == row)
    }

    @Test func portOpenRequestAndURLRoundTrip() throws {
        let request = WorktreeManagementRequest.openResource(worktreeID: "/project", request: .port(3000))
        #expect(try JSONDecoder().decode(WorktreeManagementRequest.self, from: JSONEncoder().encode(request)) == request)
        let response = WorktreeManagementResponse.openResource(.url(URL(string: "http://localhost:3000/")!))
        #expect(try JSONDecoder().decode(WorktreeManagementResponse.self, from: JSONEncoder().encode(response)) == response)
    }
}
