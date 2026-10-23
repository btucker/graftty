import Foundation
import GrafttyProtocol
import Testing
@testable import GrafttyKit

@MainActor
struct WorktreePortTests {
    @Test("@spec PORTS-5.1: When a worktree publishes listening ports, the application shall combine its pane process bindings, deduplicate by port, sort numerically, and exclude bindings from other worktrees.")
    func aggregatesOnlyWorktreePanes() {
        let model = PortBindingsModel()
        let first = PaneSlotID(), second = PaneSlotID(), unrelated = PaneSlotID()
        model.set(first, [.init(port: 8080, scope: .loopback, processName: "node", pid: 12)])
        model.set(second, [.init(port: 8080, scope: .lan, processName: "worker", pid: 20),
                           .init(port: 3000, scope: .loopback, processName: "vite", pid: 30)])
        model.set(unrelated, [.init(port: 9000, scope: .lan, processName: "other", pid: 40)])
        let ports = model.ports(for: [second, first])
        #expect(ports.map(\.port) == [3000, 8080])
        #expect(ports.last?.processName == "node")
        #expect(ports.last?.scope == .lan)
        #expect(ports.last?.url?.absoluteString == "http://localhost:8080/")
        model.set(first, [])
        model.set(second, [])
        #expect(model.ports(for: [first, second]).isEmpty)
    }

    @Test("@spec REMOTE-4.4: When a paired device opens a discovered worktree port, the application shall approve only that device's connections to the advertised listening endpoint until the approval expires.")
    func approvalIsScopedToDeviceAndPort() {
        let approvals = BrowserTunnelApprovalStore()
        let phone = RemoteDeviceID(value: "phone"), other = RemoteDeviceID(value: "other")
        let expiry = Date(timeIntervalSince1970: 900), now = Date(timeIntervalSince1970: 899)
        approvals.approve(deviceID: phone, host: "127.0.0.1", port: 3000, until: expiry)
        #expect(approvals.isApproved(deviceID: phone, host: "127.0.0.1", port: 3000, now: now))
        #expect(!approvals.isApproved(deviceID: phone, host: "::1", port: 3000, now: now))
        #expect(!approvals.isApproved(deviceID: phone, host: "localhost", port: 3000, now: now))
        #expect(!approvals.isApproved(deviceID: other, host: "localhost", port: 3000, now: now))
        #expect(!approvals.isApproved(deviceID: phone, host: "localhost", port: 4000, now: now))
        #expect(!approvals.isApproved(deviceID: phone, host: "example.com", port: 3000, now: now))
        #expect(!approvals.isApproved(deviceID: phone, host: "127.0.0.1", port: 3000, now: expiry))
    }
}
