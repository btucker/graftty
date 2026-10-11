import GrafttyKit
import Foundation
import GrafttyProtocol
import Testing
@testable import GrafttyHostAgent

struct BrowserTunnelAuthorizationTests {
    @Test func portApprovalRequiresLiveHostResolutionAndHonorsDisabledCapability() async throws {
        let box = AuthenticatedPeerBox()
        let device = RemoteDeviceID(value: "port-tap-test")
        var capability = PairedDeviceCapabilities.defaultsAfterPairing
        box.peer = TrustedPeer(id: device, kind: .ipad,
            publicKey: try RemoteIdentityPublicKey(rawRepresentation: Data(repeating: 1, count: 32)),
            displayName: "iPad", capabilities: capability, pairedAt: .now, lastSeenAt: nil)
        let approvals = BrowserTunnelApprovalStore()
        let request = WorktreeManagementRequest.openResource(worktreeID: "/project", request: .port(3000))
        _ = await box.manage(request, using: { _ in
            .error(code: "port-unavailable", message: "Stopped", forceAllowed: false, shortStatus: nil)
        }, approvals: approvals)
        #expect(!approvals.isApproved(deviceID: device, host: "localhost", port: 3000))
        _ = await box.manage(request, using: { _ in .openResource(.url(URL(string: "http://localhost:3000/")!)) }, approvals: approvals)
        #expect(approvals.isApproved(deviceID: device, host: "localhost", port: 3000))
        #expect(!approvals.isApproved(deviceID: device, host: "localhost", port: 3001))
        capability.portTunnel = .disabled
        box.peer?.capabilities = capability
        let denied = await box.manage(request, using: { _ in
            Issue.record("A disabled device must not resolve ports")
            return .ok
        }, approvals: approvals)
        guard case .error(let code, _, _, _) = denied else { Issue.record("Expected denial"); return }
        #expect(code == "port-tunnel-disabled")
        #expect(!box.browserTunnelAllowed(host: "localhost", port: 3000))
    }

    @Test("@spec REMOTE-4.1: If a paired client requests a port tunnel under the default ask-each-time policy, then the host shall require an active approval created by graftty open URL or a discovered worktree port tap before connecting to the target.")
    func askEachTimeRequiresHostApproval() {
        #expect(!BrowserTunnelAuthorization.allows(
            capability: .askEachTime,
            host: "example.com",
            hasUserApproval: false
        ))
        #expect(BrowserTunnelAuthorization.allows(
            capability: .askEachTime,
            host: "example.com",
            hasUserApproval: true
        ))
        #expect(!BrowserTunnelAuthorization.allows(
            capability: .disabled,
            host: "localhost",
            hasUserApproval: true
        ))
    }

    @Test("@spec REMOTE-4.2: While a paired client has loopback-only port-tunnel permission, the host shall reject non-loopback targets before connecting to them.")
    func loopbackPermissionRejectsOtherTargets() {
        for host in ["localhost", "api.localhost", "127.0.0.1", "127.42.3.9", "::1"] {
            #expect(BrowserTunnelAuthorization.allows(
                capability: .allowedLoopback,
                host: host,
                hasUserApproval: false
            ))
        }
        for host in ["example.com", "192.168.1.1", "8.8.8.8", "::2"] {
            #expect(!BrowserTunnelAuthorization.allows(
                capability: .allowedLoopback,
                host: host,
                hasUserApproval: true
            ))
        }
    }
}
