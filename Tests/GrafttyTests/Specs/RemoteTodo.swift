// Auto-generated inventory of unimplemented specs in this section.
// Promote a @Test(.disabled(...)) entry to a real @Test in a *Tests.swift
// file before implementing the behavior, then delete the entry from this
// inventory file. SPECS.md is regenerated from these markers by
// scripts/generate-specs.py.

import Testing

@Suite("REMOTE — pending specs")
struct RemoteTodo {
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

    @Test("""
@spec REMOTE-6.1: When a client opens a channel with `channel_type: "panes_state"` over an authenticated `RemoteHostConnection`, the host shall accept the channel for any trusted peer holding the `terminal_control` capability.
""", .disabled("not yet implemented"))
    func remote_6_1() async throws { }

    @Test("""
@spec REMOTE-7.1: When a client opens a channel with `channel_type: "pane_control"` over an authenticated `RemoteHostConnection`, the host shall accept the channel only when the requesting trusted peer holds the `terminal_control` capability.
""", .disabled("not yet implemented"))
    func remote_7_1() async throws { }

    @Test("""
@spec REMOTE-7.6: If a trusted peer is revoked while a `pane_control` channel is open, the channel shall close and subsequent open requests from the revoked peer shall be rejected.
""", .disabled("not yet implemented"))
    func remote_7_6() async throws { }

    // MARK: - REMOTE-8.x — SSH session layer

    @Test("""
@spec REMOTE-8.1: While accepting a remote attach, the host shall negotiate SSH KEX restricted to the `curve25519-sha256` algorithm and reject any other KEX proposal.
""", .disabled("awaits upstream swift-nio-ssh algorithm-allowlist feature"))
    func remote_8_1() async throws { }

}
