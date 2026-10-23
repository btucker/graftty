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
""", .disabled("deferred: parent sleep recovery"))
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

    // MARK: - REMOTE-28.x - Remote agent configuration

    @Test("""
@spec REMOTE-28.3: When preparing a managed remote agent environment, the application shall install the parent's compatible user-level skills and enabled plugins for the selected agent runtime before launching that agent, without copying keys or authentication stores.
""", .disabled("not yet implemented"))
    func remote_28_3() async throws { }

    @Test("""
@spec REMOTE-28.4: When preparing a project or worktree on a remote host, the application shall make its project-level and worktree-local skills available in the agent's execution environment while preserving runtime discovery precedence and isolation from other projects and parents.
""", .disabled("not yet implemented"))
    func remote_28_4() async throws { }

    @Test("""
@spec REMOTE-28.5: When launching or resuming a managed remote agent, the application shall reconcile its installed skill and plugin revision with the parent snapshot and report missing or incompatible dependencies without silently claiming configuration parity.
""", .disabled("not yet implemented"))
    func remote_28_5() async throws { }

    @Test("""
@spec REMOTE-28.6: When refreshing remote agent configuration, the application shall stage a complete revision before activating it for a new launch, preserve running agents' configuration, and remove obsolete Graftty-managed entries without deleting unrelated remote configuration.
""", .disabled("not yet implemented"))
    func remote_28_6() async throws { }

    // MARK: - REMOTE-29.x — AWS Spot evacuation

    @Test("""
@spec REMOTE-29.1: When configuring AWS compute, the application shall support Spot instances in the initial AWS provider implementation.
""", .disabled("not yet implemented"))
    func remote_29_1() async throws { }

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

    // MARK: - REMOTE-30.x - MCP access through the parent

    @Test("""
@spec REMOTE-30.1: When a managed Linux agent uses a granted parent MCP server, the application shall proxy standard MCP messages over the authenticated parent connection while retaining upstream authentication and refresh on the parent.
""", .disabled("not yet implemented"))
    func remote_30_1() async throws { }

    @Test("""
@spec REMOTE-30.2: When forwarding a worker MCP request, the parent shall require a current grant bound to the authenticated worker, repository, worktree, assignment generation, server ID, and expiry without accepting worker-supplied upstream commands, URLs, or credential configuration.
""", .disabled("not yet implemented"))
    func remote_30_2() async throws { }

    @Test("""
@spec REMOTE-30.3: When an MCP grant expires, is revoked, or is superseded by reassignment, the application shall reject new calls and close its sessions without transferring that authority through copied session data.
""", .disabled("not yet implemented"))
    func remote_30_3() async throws { }

    @Test("""
@spec REMOTE-30.4: While proxying MCP sessions, the application shall isolate messages and negotiated capabilities by delegation and enforce bounded messages, queues, concurrency, and deadlines.
""", .disabled("not yet implemented"))
    func remote_30_4() async throws { }

    @Test("""
@spec REMOTE-30.5: If the parent connection is lost during an MCP call, then the application shall report unavailable or unknown outcome without automatically replaying the call, copying credentials, or falling back to an unconfigured direct connection.
""", .disabled("not yet implemented"))
    func remote_30_5() async throws { }

    @Test("""
@spec REMOTE-30.6: If an existing MCP authentication source lacks a supported parent integration, then the application shall report authentication required or unsupported without scraping or exporting private authentication stores.
""", .disabled("not yet implemented"))
    func remote_30_6() async throws { }

    @Test("""
@spec REMOTE-30.7: When presenting MCP access in the CLI, Mac, or Mobile, the application shall identify the server, execution location, delegation, and readiness without exposing authentication material or recording tool payloads by default.
""", .disabled("not yet implemented"))
    func remote_30_7() async throws { }

    @Test("""
@spec REMOTE-30.8: When preparing or recovering a worktree, the application shall generate scoped MCP bridge configuration from current parent grants and check MCP readiness separately from container readiness and agent-runtime authentication.
""", .disabled("not yet implemented"))
    func remote_30_8() async throws { }

    @Test("""
@spec REMOTE-30.9: When configuring granted MCP servers for a remote agent, the application shall preserve their logical server names and upstream tool definitions through separate Graftty bridge entries without requiring an agent-facing forwarding tool.
""", .disabled("not yet implemented"))
    func remote_30_9() async throws { }

}
