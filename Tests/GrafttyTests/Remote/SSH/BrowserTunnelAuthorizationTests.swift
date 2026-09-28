import GrafttyKit
import Testing
@testable import GrafttyHostAgent

struct BrowserTunnelAuthorizationTests {
    @Test("@spec REMOTE-4.1: If a paired client requests a port tunnel under the default ask-each-time policy, then the host shall require an active approval created by graftty open URL before connecting to the target.")
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
