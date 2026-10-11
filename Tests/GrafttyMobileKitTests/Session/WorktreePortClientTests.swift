import Foundation
import GrafttyProtocol
import Testing
@testable import GrafttyMobileKit

struct WorktreePortClientTests {
    private let port = WorktreePort(port: 3000, scope: .loopback, processName: "vite")
    private func row(route: WorktreeRoute? = nil, ports: [WorktreePort]? = nil) -> WorktreePanes {
        WorktreePanes(path: "/project", displayName: "main", repoDisplayName: "repo",
            displayBranch: "main", state: .running, isMainCheckout: true, prBadge: nil,
            stats: nil, attentionText: nil, layout: nil, route: route, ports: ports ?? [port])
    }

    @Test("@spec PORTS-5.4: When an iPhone or iPad user taps a worktree port, the application shall request approval for that worktree's listener and open the returned URL in the paired host browser through the authenticated connection.")
    func tapRequestsWorktreeScopedApproval() async throws {
        var requests: [WorktreeManagementRequest] = []
        let url = try await WorktreePortClient.open(port, in: row()) { request in
            requests.append(request)
            return .openResource(.url(try #require(port.url)))
        }
        #expect(url == port.url)
        #expect(requests == [.openResource(worktreeID: "/project", request: .port(3000))])
    }

    @Test("@spec PORTS-5.5: If a worktree port is stale, denied, or belongs to a relayed Mac without a browser route, then the application shall report the failure and shall not open a URL on the wrong host.")
    func rejectsStaleRelayedAndDeniedPorts() async throws {
        for worktree in [row(ports: []), row(route: .init(repositoryID: "relay-repository-1", worktreeID: "relay-worktree-1"))] {
            await #expect(throws: WorktreePortClient.Failure.self) {
                try await WorktreePortClient.open(port, in: worktree) { _ in
                    Issue.record("An unavailable port must not request a tunnel")
                    return .openResource(.url(try #require(port.url)))
                }
            }
        }
        do {
            _ = try await WorktreePortClient.open(port, in: row()) { _ in
                .error(code: "port-tunnel-disabled", message: "Port tunnels are disabled.", forceAllowed: false, shortStatus: nil)
            }
            Issue.record("Denied ports must fail")
        } catch { #expect(error.localizedDescription == "Port tunnels are disabled.") }
        await #expect(throws: WorktreePortClient.Failure.self) {
            try await WorktreePortClient.open(port, in: row()) { _ in
                .openResource(.url(URL(string: "http://localhost:9000/")!))
            }
        }
    }
}
