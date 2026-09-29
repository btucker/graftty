// Auto-generated inventory of unimplemented specs in this section.
// Promote a @Test(.disabled(...)) entry to a real @Test in a *Tests.swift
// file before implementing the behavior, then delete the entry from this
// inventory file. SPECS.md is regenerated from these markers by
// scripts/generate-specs.py.

import Testing

@Suite("REMOTE — pending specs")
struct RemoteTodo {
    // MARK: - REMOTE-8.x — SSH session layer

    @Test("""
@spec REMOTE-8.1: While accepting a remote attach, the host shall negotiate SSH KEX restricted to the `curve25519-sha256` algorithm and reject any other KEX proposal.
""", .disabled("awaits upstream swift-nio-ssh algorithm-allowlist feature"))
    func remote_8_1() async throws { }

}
