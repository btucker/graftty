import Foundation
import Testing
import GrafttyProtocol
@testable import Graftty

struct RemoteWorktreePortTargetTests {
    @Test("@spec PORTS-5.11: When opening a remote worktree port, the application shall forward only a currently advertised listener belonging to that pane on the directly connected host.")
    func validatesPaneAndDestination() throws {
        let binding = PortBinding(port: 3000, scope: .loopback, processName: "node", pid: 123, targetHost: "127.0.0.1")
        func worktree(relayed: Bool = false, bindings: [PortBinding] = []) -> WorktreePanes {
            WorktreePanes(path: "/repo", displayName: "main", repoDisplayName: "repo", displayBranch: "main",
                state: .running, isMainCheckout: true, prBadge: nil, stats: nil, attentionText: nil,
                layout: .leaf(sessionName: "pane", title: "node", attentionText: nil, isBusy: false, attentionSource: nil),
                origin: .init(deviceID: .init(value: "host"), deviceLabel: "Host", relayDepth: relayed ? 1 : 0),
                portBindings: ["pane": bindings])
        }
        let target = try RemoteWorktreePortTarget(worktree: worktree(bindings: [binding]), sessionName: "pane", binding: binding)
        #expect(target.host == "127.0.0.1" && target.port == 3000)
        #expect(throws: (any Error).self) { try RemoteWorktreePortTarget(worktree: worktree(), sessionName: "pane", binding: binding) }
        #expect(throws: (any Error).self) { try RemoteWorktreePortTarget(worktree: worktree(bindings: [binding]), sessionName: "other", binding: binding) }
        #expect(throws: (any Error).self) { try RemoteWorktreePortTarget(worktree: worktree(relayed: true, bindings: [binding]), sessionName: "pane", binding: binding) }
        for address in ["192.168.1.1", "127.0.0.1.evil.example", "0.0.0.0", "localhost.example"] {
            let unsafe = PortBinding(port: 3000, scope: .lan, processName: "node", pid: 123, targetHost: address)
            #expect(throws: (any Error).self) { try RemoteWorktreePortTarget(worktree: worktree(bindings: [unsafe]), sessionName: "pane", binding: unsafe) }
        }
    }
}
