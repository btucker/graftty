# Windows headless host

V1 targets the existing Linux headless host and Graftty-patched zmx inside
WSL2 on Windows 11. Retain the same session ownership, detach and reattach,
replay, history, and resize behavior as Mac and Linux. A separate Windows
session broker is not the v1 approach. Native Windows remains follow-up work.

The Windows machine initiates its connection to the parent Mac. Installation
and enrollment run locally on Windows and do not require an SSH login into it.
The current Linux setup wizard requires SSH and an inbound host connection,
so WSL2 alone does not complete this setup or transport work.

V1 targets background operation while the Windows user is signed in, including
screen lock. Operation after logout or before sign-in is a v2 goal. The WSL
lifecycle needs a Windows 11 test with terminal windows closed. Enabling
systemd alone does not establish that the host and sessions remain available.

The host, agent CLIs, shells, and repositories run in Linux for v1. Native
PowerShell and Windows toolchain parity require separate integration work.

## WSL2 resource policy

Use the machine's available capacity rather than accepting a small VM budget.
Microsoft documents a default WSL2 memory limit of 50% of Windows RAM and a
default CPU count equal to all Windows logical processors. These limits are
configured through WSL Settings or `%UserProfile%\.wslconfig` and apply across
WSL2 distributions. See [Microsoft's configuration reference](https://learn.microsoft.com/en-us/windows/wsl/wsl-config).

Recommend a memory ceiling close to physical RAM, with explicit headroom for
Windows and any other Windows workloads. On a dedicated 64 GB machine,
56–60 GB is an initial tuning range, not a measured guarantee. For example:

```ini
[wsl2]
memory=56GB
```

Leave `processors` unset to retain the documented all-processor default.
Inspect existing settings before proposing changes, and preserve unrelated
settings. A WSL restart is required for changes to take effect. Do not restart
active distributions during setup without accounting for their running work.

Report effective CPU availability, guest memory capacity, available memory,
and any tighter process or container limits. Verify these after a restart.
Base work placement on available guest resources. Do not count swap as RAM or
advertise the Windows physical total as available Linux capacity. Tune memory
and concurrency under a representative build and multi-agent workload before
claiming full-machine utilization.

Keep repositories, worktrees, and build caches in the WSL Linux filesystem,
such as `~/projects`, for the Linux workload.
[Microsoft recommends this location for performance](https://learn.microsoft.com/en-us/windows/wsl/filesystems#file-storage-and-performance-across-file-systems).

## Native Windows groundwork

This branch starts the port with `GrafttyWindowsTerminal`, a Swift library
backed by Win32 ConPTY. **There is no Windows `graftty-host.exe` yet.**
The Windows package builds this library, `GrafttyTunnel`, and their bootstrap tests. The full host and
CLI still require the platform work below.

## What exists

`WindowsTerminalSession` starts a native executable with a working directory,
arguments, environment, and terminal size. It accepts terminal input, emits
UTF-8 VT output on a dedicated reader thread, resizes the pseudoconsole, and
closes the console process tree. Shutdown keeps draining output to avoid the
ConPTY deadlock described in [Microsoft's session guide](https://learn.microsoft.com/en-us/windows/console/creating-a-pseudoconsole-session).

`WindowsTerminalLaunch` encodes Windows argument quoting and UTF-16 environment
blocks. These tests run on Mac and Linux too. Shell command parsing remains
the caller's responsibility. For example, passing a script to `cmd.exe /C`
has different escaping rules from passing arguments to an ordinary executable.

The native session tests exercise real ConPTY shells on Windows, including
input, output, resize, repeated close, and failed launch. The new Windows CI
workflow runs them on Windows Server 2025. A successful server run does not
establish Windows 11 compatibility.

`NativeSSHTransportTests` exercise a real TCP loopback connection, Ed25519
authentication, host-key pinning, and Graftty's existing framing codecs with
a message spanning multiple network reads. Negative cases reject unexpected
host and client keys without accepting a timeout as success. The same tests
run on Mac, Linux, and Windows. Their delegates are fixtures, so this does not
yet validate the host's production trust store or pairing path.

The reverse-channel test creates a listener only on the parent side. After the
headless client authenticates and announces readiness, the parent opens a new
application channel back over the same connection. This proves the direction
required by the Windows deployment without inbound access to the Windows PC.

The library owns a shell for its lifetime. It does not provide persistent
sessions, detach and reattach, replay, pairing, or remote access.

## Shared host and connection design

Keep the existing Swift state model, zmx integration, and Graftty wire
protocols. WSL2 reuses the Linux implementation. A native port must retain zmx
and its behavior rather than introduce a second session implementation.

### Local setup and outbound connection

The following is the proposed setup flow, not a shipped installer:

1. The Mac's **Add Headless Host** flow creates a short-lived enrollment offer.
2. The user runs a Windows installer locally and pastes the enrollment offer.
3. Windows creates its device identity locally and connects to the parent.
4. The Mac confirms the new host's identity and records its permissions.
5. Windows retains the parent identity and reconnects after network loss or
   restart, with bounded retries and backoff. Enrollment secrets expire and
   are not reused as permanent credentials.

Windows needs no SSH server, remote shell account, or inbound listening port.
The current transport experiment uses Graftty's encrypted SSH library inside
the outbound connection. This does not invoke `ssh.exe` or provision Windows
through SSH. Both peers authenticate; the Mac can open terminal and control
channels back over the established connection.

An accepted connection must not give the Windows host permission to operate
the Mac's local terminals. Register the remote host under its authenticated
device ID and key, and keep host registration separate from client-control
permissions. Revocation must close the active link and prevent reconnect.

`graftty-server` is the selected public signaling service. Both devices make
outbound authenticated requests to it. ICE tries direct connectivity with
STUN, with TURN as the proposed fallback when the direct path fails. The
direct LAN or VPN connection remains useful, but cloud-routed setup must not
require a publicly reachable listener on either device.

### Security boundary and cross-project work

The server helps devices meet. Resource access remains authorized locally
against paired device keys. A stolen account credential, altered room message,
or compromised signaling service must not authorize a terminal attachment or
silently replace either device's identity. The server and TURN can still deny
service and observe connection metadata; end-to-end encryption does not hide
every address, timing, or traffic-volume detail.

The existing authenticated-signaling and pairing types are useful starting
points. The May 21 SSH-over-WebRTC design supersedes the May 15 server design's
custom Noise handshake. Retain the existing key-authenticated SSH protection
inside the data channel. HTTPS protects the service connection but does not
replace the paired-device authentication layer. WebRTC encryption by itself
does not establish Graftty's local resource permissions.

The Windows integration requirements are inventoried as `REMOTE-32.4` through
`REMOTE-32.11`. They are disabled backlog specs, not implemented guarantees.
They cover server-independent pairing, authenticated signaling transcripts,
end-to-end protection, fresh authentication on reconnect, revocation, direction
of authority, and Windows private-key protection.

Coordination with the main graftty-server agent has been requested for the
server-side assessment and shared API contract. The request covers Windows enrollment, discovery,
room membership and lifetime, delivery to outbound-connected devices, limits,
revocation checks, TURN issuance and refresh, and sensitive-data logging.
Protocol changes need agreement between the two projects before implementation.
The enrollment wire value and outbound parent room-discovery mechanism
are pending confirmation. For WSL2, distinguish the Windows deployment from
the Linux runtime rather than assuming a native Windows enrollment value.
The inspected server currently enrolls only `mac`
and `phone`, and its room target must be a Mac. Signaling roles can describe
connection establishment without deciding which device owns terminal resources.

| Boundary | Owner | Acceptance evidence required |
| --- | --- | --- |
| Account and device authentication, room membership | graftty-server | Wrong-account, wrong-device, expired-room, and revoked-device requests fail |
| Signaling delivery and TURN credentials | graftty-server | Bounded messages, queues, requests, and allocations; short-lived credentials; no secret or payload logs |
| Pairing and pinned device identity | Mac and Windows | Account access cannot create trust; substituted or changed keys fail until explicitly verified |
| Session and signaling authenticity | Mac and Windows | Tampered, expired, cross-session, and replayed messages fail before terminal access |
| Terminal input, commands, and port forwarding | Resource-owning device | Current peer capabilities are checked locally; revocation stops live access |
| Reconnect and room recreation | Both projects | Fresh authentication; no duplicate replay of terminal input or mutating commands |
| Local keys and installation | Each platform | Windows user-bound cryptographic protection and file access; authenticated release artifacts |

A release needs adversarial tests with a malicious signaling intermediary,
not only a happy-path relay test. In particular, expiration of a server token
or TURN credential is not evidence that an existing terminal connection has
closed. Live revocation must be enforced by the resource-owning endpoint.

This is a scoped design and source inspection. The deployed service and the
native Windows cloud path have not been security-audited or validated here.

V1 keeps terminal persistence in the existing zmx daemon. Verify that viewer
disconnect, network loss, and Mac restart leave sessions intact. Use the pinned
Graftty-patched build, including its history extensions, rather than an
arbitrary upstream binary. These behaviors still need WSL2 integration tests.
WSL termination or Windows reboot ends running Linux processes.

Private-key protection also needs WSL2 validation. The native Windows
cryptographic-storage requirement does not establish protection for a Linux
process or its virtual disk. Verify the chosen WSL identity store, Linux file
permissions, and Windows access to that storage before release.

For a future native port, the current host's
`HostTerminalDriver` takes `ZmxSpawnConfiguration`, and its SSH streams attach
through `ZmxAttachEngine`. Merely implementing `HostTerminalDriver` would leave
launch configuration, SSH attachment, replay, and shutdown coupled to zmx.

Native Windows therefore needs a zmx port with Windows process, terminal,
and local IPC support. ConPTY is groundwork for that terminal backend, not a
replacement for zmx. If sessions must survive host upgrades, the zmx daemon
must outlive the host process. Disconnecting a viewer must never close the
session's pseudoconsole.

The pinned SwiftNIO 2.98 checkout contains a Windows `WSAPoll` backend.
That is a reason to test the existing SSH stack on Windows before choosing a
replacement, not proof that Graftty's networking dependency graph builds there.
Windows must retain Graftty's identity authentication and typed SSH channels.
The parent must adopt the accepted connection as a remote host link rather
than starting a second connection back to Windows.

## Remaining work in dependency order

1. Validate the existing Linux archive and patched zmx on Ubuntu 24.04 under
   WSL2. Exercise session ownership, detach and reattach, history, replay,
   resize, agent hooks, and both Mac and Mobile viewers.
2. Add local installation and enrollment without SSH. Reuse Linux packaging
   while handling Windows sign-in startup and WSL background lifetime.
3. Agree the enrollment and room-discovery contract with graftty-server, then
   implement the authenticated outbound link and Mac transport adoption.
4. Validate pairing, tampered signaling, revocation, network loss, and Mac
   restarts against real WSL2 sessions. Keep the existing security boundaries.
5. Inspect and tune the machine's WSL resource configuration. Verify effective
   resources and sustained build throughput without starving Windows.
6. Run a clean Windows 11 installation and recovery test. Document that logout,
   WSL termination, and reboot are outside v1 session persistence guarantees.

## Native Windows follow-up

1. Run the native terminal tests on Windows 11. Include PowerShell 7 and both
   agent CLIs, Unicode repository paths, sustained output, concurrent shutdown,
   Ctrl-C, interactive prompts, and terminal size changes.
2. Run the isolated native SSH tests on Windows to prove the existing SwiftNIO,
   NIOSSH, Crypto, framing, and parent-originated reverse channels. The bootstrap
   package excludes Apple renderer and updater dependencies.
3. Port the pinned Graftty-patched zmx to native Windows, including process
   creation, ConPTY ownership, and local IPC. Test session survival on viewer
   disconnect and reconnect, plus parity for replay and paged history.
4. Port process execution and shell startup. Use native argument vectors and
   environment blocks. PowerShell startup and agent hooks need Windows scripts.
   Bash snippets and `/usr/bin/env` cannot be the Windows launch path.
5. Port local control, state paths, locking, and private-file storage. Named
   pipes need access control for the current user. Win32 file locks and ACLs
   must replace `lockf`, Unix socket permissions, and secret-file mode bits.
   Keep the current atomic publication and durability guarantees explicit.
6. Port Git invocation and path comparison, worktree monitoring, process
   identity, resource sampling, and listening-port discovery. Test drive paths,
   UNC paths, case handling, and Git for Windows worktrees.
7. Implement local enrollment and a reconnecting outbound host connection.
   Let the Mac adopt that accepted transport for the shared headless runtime
   and channels. Verify pairing,
   repository registration, worktree creation, panes, agent hooks, Attention,
   team messaging, and authenticated port forwarding from Mac and Mobile.
8. Add a per-user installation and startup path, checksummed Windows archives,
   upgrade rollback, and a clean Windows 11 smoke test. Operation after Windows
   logout or before sign-in remains a v2 goal.

## References

- [Install Swift on Windows](https://www.swift.org/install/windows/)
- [Microsoft pseudoconsoles](https://learn.microsoft.com/en-us/windows/console/pseudoconsoles)
- [CreatePseudoConsole](https://learn.microsoft.com/en-us/windows/console/createpseudoconsole)
- [SwiftNIO Windows selector](https://github.com/apple/swift-nio/blob/2.98.0/Sources/NIOPosix/SelectorWSAPoll.swift)
- [zmx supported features](https://github.com/neurosnap/zmx#features)
