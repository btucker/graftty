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
@spec REMOTE-6.2: Immediately after accepting a `panes_state` channel, the host shall send a `{"type":"snapshot","worktrees":[…]}` frame containing the current `[WorktreePanes]` array.
""", .disabled("not yet implemented"))
    func remote_6_2() async throws { }

    @Test("""
@spec REMOTE-6.3: While a `panes_state` channel is open, on any change to the host's `AppState.repos[*].worktrees`, splittree, attention state, or PR status, the host shall send a fresh `{"type":"snapshot","worktrees":[…]}` frame.
""", .disabled("not yet implemented"))
    func remote_6_3() async throws { }

    @Test("""
@spec REMOTE-6.4: When the `RemoteHostConnection` tears down (client background, host switch, network failure, peer revocation), any open `panes_state` channels shall close.
""", .disabled("not yet implemented"))
    func remote_6_4() async throws { }

}
