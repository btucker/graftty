// Auto-generated inventory of unimplemented specs in this section.
// Promote a @Test(.disabled(...)) entry to a real @Test in a *Tests.swift
// file before implementing the behavior, then delete the entry from this
// inventory file. SPECS.md is regenerated from these markers by
// scripts/generate-specs.py.

import Testing

@Suite("REMOTE — pending specs")
struct RemoteTodo {
    @Test("""
@spec REMOTE-1.2: When a client pairs with a host, the application shall require a matching verification code and host-side confirmation before storing the client as a trusted peer.
""", .disabled("not yet implemented"))
    func remote_1_2() async throws { }

    @Test("""
@spec REMOTE-2.1: When a remote transport reconnects, the host shall require a fresh authenticated attach handshake before writing any bytes to the PTY.
""", .disabled("not yet implemented"))
    func remote_2_1() async throws { }

    @Test("""
@spec REMOTE-3.1: If a trusted peer is revoked on the host, then all active secure channels from that peer shall close and future attach requests from that peer shall be rejected.
""", .disabled("not yet implemented"))
    func remote_3_1() async throws { }

    @Test("""
@spec REMOTE-4.1: If a client requests a port tunnel without host approval under the default ask-each-time policy, then the host shall reject the channel open request before connecting to the target port.
""", .disabled("not yet implemented"))
    func remote_4_1() async throws { }

    @Test("""
@spec REMOTE-4.2: If a client requests a port tunnel to a non-loopback target under the default policy, then the host shall reject the channel open request.
""", .disabled("not yet implemented"))
    func remote_4_2() async throws { }

    @Test("""
@spec REMOTE-5.1: When a client attempts to use the retired `/ws` terminal endpoint, the host shall reject the request without attaching to a PTY.
""", .disabled("not yet implemented"))
    func remote_5_1() async throws { }

}
