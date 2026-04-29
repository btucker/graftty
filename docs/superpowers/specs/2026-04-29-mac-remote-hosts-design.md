# Mac Remote Hosts Design

## Summary

Add first-class remote hosts to the Mac app so one local Graftty instance can browse and attach to repositories/worktrees served by another Mac over SSH. This extends the SSH tunnel access model already used for mobile, but with a different key story: on macOS, users manage SSH keys, agents, and `~/.ssh/config` themselves.

The remote Mac must already be running Graftty in SSH tunnel mode. The local Mac app creates an SSH local-forward tunnel, talks to the remote Graftty web API through the forwarded loopback URL, and renders that remote host's repositories in the main sidebar.

## Goals

- Let the Mac app add and browse another Mac running Graftty without Tailscale.
- Keep local-only Graftty visually unchanged: no `This Mac` wrapper unless other hosts exist.
- Avoid unnecessary sidebar indentation when multiple hosts exist.
- Use the user's existing macOS SSH setup: keys, agent, config aliases, ports, and jump hosts.
- Keep `Add Repository` scoped to the currently selected host instead of mixing repository and transport setup.
- Make remote connection failures actionable, especially when SSH works but Graftty is not running remotely.

## Non-Goals

- No remote auto-launch of Graftty in V1.
- No Mac-side SSH key generation, import, password storage, or key management UI.
- No built-in SSH server in Graftty.
- No remote filesystem browsing outside the existing Graftty web API.
- No required Tailscale dependency for remote hosts.
- No nested tree wrapper for `This Mac` in the single-host state.

## User Model

A **host** is a Mac running Graftty.

`This Mac` is the implicit local host. It should exist in the data model, but it should not appear as a visible sidebar section while it is the only host. Remote hosts are user-added records containing SSH connection details and the remote Graftty port.

A **repository** belongs to one host. `Add Repository` adds a repository to the selected/current host. `Add Host` adds another Mac.

This separation keeps the mental model clean:

```text
Host: where Graftty is running
Repository: what project Graftty manages on that host
Transport: how this app reaches that host
```

## Sidebar UX

### Single Host

When only the local host exists, the sidebar stays as it is today:

```text
repo-a
repo-b
repo-c
```

No `This Mac` section header appears. Repositories remain top-level navigation items.

### Multiple Hosts

Once the user has at least one remote host, the sidebar groups repositories by host using section headers, not extra tree indentation:

```text
This Mac
repo-a
repo-b

dev-mini.local
repo-c
repo-d

192.168.1.42
repo-e
```

Repos remain visually aligned across host sections. The host label is grouping metadata, not a parent row the user must expand before seeing repositories.

If a remote host is disconnected, its last-known repositories should remain visible under that host header in a stale/disconnected style. This avoids sidebar reshuffling and preserves user orientation.

## Add Actions

The sidebar add control should expose two actions:

```text
Add Repository
Add Host
```

This can be a `+` menu or two adjacent affordances, depending on the sidebar's final layout. The important behavior is that `Add Repository` never asks whether the repository is local or SSH-backed. It always applies to the selected/current host.

## Add Host Flow

`Add Host` collects:

- Hostname, IP address, or SSH config alias.
- SSH username, optional. Default to the current macOS username when empty.
- SSH port, default `22`.
- Remote Graftty port, default `8799`.
- Display name, optional. Default to the hostname/alias.

The UI should explain the prerequisite clearly:

```text
The remote Mac must already be running Graftty with SSH Tunnel mode enabled.
Graftty will use your existing SSH keys and configuration.
```

There should be a `Test Connection` action before or during save.

## Connection Flow

The local Mac app uses the user's existing SSH environment. Conceptually:

```sh
ssh -N -L 127.0.0.1:<local-ephemeral-port>:127.0.0.1:<remote-graftty-port> user@host
```

Implementation can use either a managed `ssh` subprocess or a native SSH library, but V1 should prefer the path that best preserves user SSH config behavior. That includes aliases, `IdentityFile`, `ProxyJump`, `Include`, agent use, and other common OpenSSH configuration.

After the tunnel is established, the app probes:

```text
http://127.0.0.1:<local-ephemeral-port>/
```

Then it fetches the existing Graftty web API endpoints for repositories, worktrees, Ghostty config, and WebSockets through that forwarded base URL.

## Test Connection Behavior

The test flow should distinguish failures:

1. SSH failed.
   - Show an SSH-focused error.
   - Include the host and username being attempted.
   - Do not mention Graftty setup as the likely problem.

2. SSH succeeded, but Graftty did not respond through the tunnel.
   - Show a Graftty-focused error:

```text
SSH connected, but Graftty did not respond on the remote Mac.
Open Graftty on <host> and enable SSH Tunnel mode.
```

3. Graftty responded.
   - Save the host.
   - Load its repositories/worktrees into the sidebar.

This split matters because a generic "couldn't connect" error would make users debug the wrong layer.

## Tunnel Lifetime

Tunnels should be lazy.

- Start when the user selects, expands, refreshes, or otherwise accesses a remote host.
- Reuse one tunnel per active host while the user is working with that host.
- Stop after inactivity, app quit, or explicit disconnect.
- Do not create one SSH connection per worktree/session screen.

Remote terminal sessions should behave like mobile SSH sessions: fetchers and WebSocket clients receive a resolved runtime base URL and should not know whether it came from Tailscale, direct HTTP, or an SSH tunnel.

## Host Actions

Host section headers can expose a context menu when multiple hosts exist:

- Rename Host
- Test Connection
- Disconnect
- Remove Host
- Copy SSH Command

`Remove Host` removes the saved host and cached remote sidebar entries from local Graftty. It must not modify the remote Mac.

## Data Model

Add a host model for the Mac app, conceptually:

```swift
struct MacHost: Codable, Identifiable, Hashable {
    var id: UUID
    var label: String
    var kind: MacHostKind
    var addedAt: Date
    var lastConnectedAt: Date?
}

enum MacHostKind: Codable, Hashable {
    case local
    case ssh(SSHMacHostConfig)
}

struct SSHMacHostConfig: Codable, Hashable {
    var sshHost: String
    var sshUsername: String?
    var sshPort: Int
    var remoteGrafttyPort: Int
}
```

Repositories should become host-scoped. The local host can be migrated implicitly: existing repositories belong to `This Mac`.

The UI can hide this host grouping when only the local host exists.

## Open Questions

- Should the first implementation use the system `ssh` binary or reuse the native NIOSSH tunnel implementation?
  - System `ssh` better honors user config and agent behavior.
  - Native SSH gives more structured lifecycle/error handling, but may fail to match advanced SSH config behavior users expect on macOS.
- How long should a remote host stay connected after the last active view closes?
- Should cached remote repository entries persist across launches, or only during the current app session?
- Should search/quick-open include the host name when duplicate repository names exist?

## Recommended V1

Implement remote Mac support with:

- A first-class `Add Host` flow.
- System SSH/config/agent for authentication.
- A remote-Graftty-required prerequisite.
- Host section headers only when more than one host exists.
- No extra repository indentation under host headers.
- Lazy per-host local forwarding.
- Clear layered error messages.

Do not expand `Add Repository` into local-vs-SSH choices. Repositories are behind a host; SSH is how Graftty reaches the host.
