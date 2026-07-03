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

    // MARK: - REMOTE-8.x — SSH session layer

    @Test("""
@spec REMOTE-8.1: While accepting a remote attach, the host shall negotiate SSH KEX restricted to the `curve25519-sha256` algorithm and reject any other KEX proposal.
""", .disabled("awaits upstream swift-nio-ssh algorithm-allowlist feature"))
    func remote_8_1() async throws { }

}
