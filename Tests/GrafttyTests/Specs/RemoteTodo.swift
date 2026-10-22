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

    // MARK: - REMOTE-24.x — Provider preferences and placement

    @Test("""
@spec REMOTE-24.3: When resolving placement preferences, the application shall report effective values and their sources without silently relaxing configured spending or host-count limits.
""", .disabled("not yet implemented"))
    func remote_24_3() async throws { }

    @Test("""
@spec REMOTE-24.4: When an agent lists remote hosts, the CLI shall report host identity, readiness, architecture, CPU capacity and utilization, available memory, free disk, pending placements, and observation timestamps.
""", .disabled("not yet implemented"))
    func remote_24_4() async throws { }

    @Test("""
@spec REMOTE-24.5: When placing a worktree, the application shall evaluate compatible existing hosts using current resource headroom and pending reservations before allocating another instance.
""", .disabled("not yet implemented"))
    func remote_24_5() async throws { }

    @Test("""
@spec REMOTE-24.6: When selecting new AWS Spot capacity, the application shall compare eligible instance-type and Availability Zone prices with timestamps, compatibility, configured preferences, and limits.
""", .disabled("not yet implemented"))
    func remote_24_6() async throws { }

    @Test("""
@spec REMOTE-24.7: If host telemetry or price observations are stale or absent, then the application shall expose the uncertainty rather than treating unknown capacity as idle or unknown prices as zero.
""", .disabled("not yet implemented"))
    func remote_24_7() async throws { }

    @Test("""
@spec REMOTE-24.9: When an AWS instance starts, the application shall verify trusted Graftty connectivity and project readiness before reporting the requested worktree ready.
""", .disabled("not yet implemented"))
    func remote_24_9() async throws { }

    // MARK: - REMOTE-25.x — Dev Container environments

    @Test("""
@spec REMOTE-25.2: When a project first receives a worktree on a host, the application shall transfer the required repository history and prepare its environment on demand while allowing other projects on the same host.
""", .disabled("not yet implemented"))
    func remote_25_2() async throws { }

    @Test("""
@spec REMOTE-25.3: When preparing worktrees with different environment definitions, the application shall preserve their selected revisions and prevent accidental sharing of mutable environment state.
""", .disabled("not yet implemented"))
    func remote_25_3() async throws { }

    @Test("""
@spec REMOTE-25.4: If container setup, required lifecycle commands, or agent readiness checks fail, then the application shall report the failed stage without claiming the agent is ready.
""", .disabled("not yet implemented"))
    func remote_25_4() async throws { }

    @Test("""
@spec REMOTE-25.5: When remote preparation state changes, the application shall expose consistent progress and failures to the CLI, Mac, and GrafttyMobile.
""", .disabled("not yet implemented"))
    func remote_25_5() async throws { }

    // MARK: - REMOTE-26.x — Git replication and authenticated parent publication

    @Test("""
@spec REMOTE-26.1: While a delegated host is reachable, the initiating Mac shall regularly fetch its committed work independently of publication to origin or creation of a PR or MR.
""", .disabled("not yet implemented"))
    func remote_26_1() async throws { }

    @Test("""
@spec REMOTE-26.2: When an agent pushes work to its recorded parent, the application shall transfer ordinary Git objects and refs over the authenticated Graftty connection without replacing the parent's active checkout.
""", .disabled("not yet implemented"))
    func remote_26_2() async throws { }

    @Test("""
@spec REMOTE-26.3: When a remote host can authenticate to origin using independently configured credentials, the application shall permit direct publication without requiring the parent route.
""", .disabled("not yet implemented"))
    func remote_26_3() async throws { }

    @Test("""
@spec REMOTE-26.4: When a remote agent cannot authenticate or connect to origin, the remote-host workflow shall support pushing to the parent and requesting publication of an exact received commit.
""", .disabled("not yet implemented"))
    func remote_26_4() async throws { }

    @Test("""
@spec REMOTE-26.5: When the parent receives Git work, the application shall derive sender identity from the authenticated connection and match it to the active host and worktree delegation.
""", .disabled("not yet implemented"))
    func remote_26_5() async throws { }

    @Test("""
@spec REMOTE-26.6: If an incoming Git update targets a repository or ref outside its active delegation, then the parent shall reject the update before changing refs.
""", .disabled("not yet implemented"))
    func remote_26_6() async throws { }

    @Test("""
@spec REMOTE-26.7: When the parent publishes delegated work, the application shall verify the received commit's association with the authenticated delegation and resolve the authorized destination from parent-owned configuration.
""", .disabled("not yet implemented"))
    func remote_26_7() async throws { }

    @Test("""
@spec REMOTE-26.8: When a transfer or publication request is retried, the application shall bind its identity to the sender, delegation generation, destination, and commit, rejecting changed contents and reconciling unknown outcomes.
""", .disabled("not yet implemented"))
    func remote_26_8() async throws { }

    @Test("""
@spec REMOTE-26.9: When remote hosts are provisioned or work is transferred, the application shall retain private keys and authentication stores on their existing devices without automatically copying or forwarding credentials.
""", .disabled("not yet implemented"))
    func remote_26_9() async throws { }

    @Test("""
@spec REMOTE-26.15: When a delegated host starts or loses its parent connection, the host shall initiate and retry an authenticated connection to each recorded parent without copying private keys or requiring a publicly reachable SSH port on the Mac.
""", .disabled("not yet implemented"))
    func remote_26_15() async throws { }

    @Test("""
@spec REMOTE-26.16: While a parent is unreachable, the host shall retain unacknowledged work locally while it survives, retry with bounded backoff, and report Git and session progress as saved only after their respective parent acknowledgements.
""", .disabled("not yet implemented"))
    func remote_26_16() async throws { }

    @Test("""
@spec REMOTE-26.19: When a delegated host cannot reach its parent and an authorized wake path is available, the host shall attempt Wake-on-LAN and retry authenticated connection within the remaining operation deadline, without treating a sent wake packet as a receipt or delaying transfers to other reachable parents.
""", .disabled("not yet implemented"))
    func remote_26_19() async throws { }

    // MARK: - REMOTE-27.x — Native session replication and restore

    @Test("""
@spec REMOTE-27.1: While a delegated host is reachable, the application shall regularly copy worktree-associated native Claude and Codex session data to the recorded parent, excluding authentication files.
""", .disabled("not yet implemented"))
    func remote_27_1() async throws { }

    @Test("""
@spec REMOTE-27.2: When receiving native session data, the application shall validate a consistent transfer before replacing a previously usable copy and report session and Git replication progress separately.
""", .disabled("not yet implemented"))
    func remote_27_2() async throws { }

    @Test("""
@spec REMOTE-27.3: When restoring work on another host, the application shall prepare a compatible environment, restore the selected Git and native session data, and invoke the supported native resume mechanism.
""", .disabled("not yet implemented"))
    func remote_27_3() async throws { }

    @Test("""
@spec REMOTE-27.4: If native session data, paths, runtime versions, or destination authentication prevent resumption, then the application shall preserve the copied data and report the incompatibility without claiming successful resume.
""", .disabled("not yet implemented"))
    func remote_27_4() async throws { }

    // MARK: - REMOTE-28.x — Remote development skills

    @Test("""
@spec REMOTE-28.2: When an agent uses the remote-host skill, the skill shall explain its recorded parent and direct or parent-mediated publication workflow without treating skill instructions as authentication or authorization enforcement.
""", .disabled("not yet implemented"))
    func remote_28_2() async throws { }

    // MARK: - REMOTE-29.x — AWS Spot evacuation

    @Test("""
@spec REMOTE-29.1: When configuring AWS compute, the application shall support Spot instances in the initial AWS provider implementation.
""", .disabled("not yet implemented"))
    func remote_29_1() async throws { }

    @Test("""
@spec REMOTE-29.2: While a managed Spot host runs, the host service shall monitor interruption notices independently of agent turns and initiate evacuation using the reported deadline.
""", .disabled("not yet implemented"))
    func remote_29_2() async throws { }

    @Test("""
@spec REMOTE-29.3: When a Spot interruption notice is detected, the host shall immediately stop accepting new placements and start one drain operation covering every managed worktree and its associated sessions.
""", .disabled("not yet implemented"))
    func remote_29_3() async throws { }

    @Test("""
@spec REMOTE-29.4: When draining a Spot host, the host service shall coordinate writers and attempt ordinary WIP commits and parent transfers for outstanding source changes without waiting for tests, PR creation, or an agent response.
""", .disabled("not yet implemented"))
    func remote_29_4() async throws { }

    @Test("""
@spec REMOTE-29.5: When draining a Spot host, the application shall transfer native session data to each worktree's recorded parent and track Git and session acknowledgements independently.
""", .disabled("not yet implemented"))
    func remote_29_5() async throws { }

    @Test("""
@spec REMOTE-29.6: If an evacuation operation fails or a parent is unreachable, then the host shall continue other worktree transfers within the deadline and report per-worktree partial or failed results without claiming unacknowledged work is saved.
""", .disabled("not yet implemented"))
    func remote_29_6() async throws { }

    @Test("""
@spec REMOTE-29.7: When repeated Spot warnings arrive, the host shall join the existing drain operation and bound retries and transfer concurrency by the remaining interruption deadline.
""", .disabled("not yet implemented"))
    func remote_29_7() async throws { }

}
