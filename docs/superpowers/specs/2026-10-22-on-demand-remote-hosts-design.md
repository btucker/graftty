# On demand remote development hosts

Status: Draft, 2026-10-22. Product direction is captured below. Sections marked proposed describe implementation choices that still need validation.

Tracking: [GitHub issue #545](https://github.com/btucker/graftty/issues/545), which includes the complete design. Session discovery and resume UI remain separate in issue #544.

Graftty should let an agent place a worktree on available remote capacity, prepare the project's environment, and start work. Users register compute providers as well as individual hosts. AWS is the first provider, operated through the installed `aws` CLI, with Spot support in the first release.

Remote work remains ordinary Git history and native Claude or Codex session data. The initiating Mac retains copies so work can return home or resume on another host. Publication to `origin` is separate from replication to that Mac.

The behavioral backlog lives in [RemoteTodo.swift](../../../Tests/GrafttyTests/Specs/RemoteTodo.swift), under `REMOTE-24` through `REMOTE-30`. [SPECS.md](../../../SPECS.md) is generated from that inventory. The disabled entries describe required future behavior, not passing implementation tests.

## Implementation status

The CLI implements saved provider preferences, Spot offer comparison, and EC2 host inventory. Use `graftty provider configure|show|remove aws`, `graftty provider list`, `graftty provider offers aws`, and `graftty provider hosts aws`. Configuration is per user and references an existing AWS CLI profile. No credential contents are stored.

```sh
graftty provider configure aws --profile development --region us-east-1 \
  --instance-types t4g.large,t4g.xlarge,m7g.xlarge \
  --preferred-instance-type t4g.xlarge
graftty provider offers aws --architecture arm64 --min-cpus 4 --min-memory-mib 16384 --json
graftty provider hosts aws --json
graftty provider hosts aws --all --json
graftty provider configure aws --clear preferred-instance-type
```

Offer discovery requires AWS CLI v2 and queries instance metadata and current Linux Spot rates. It filters the configured pool by architecture, CPU, memory, selected zones, and an optional hourly limit. Results sort by price, with the preferred type breaking equal-price ties. Each result distinguishes when the rate took effect from when it was observed. Rates do not establish available capacity or host load. Failed or incomplete queries fail the command instead of producing a partial ranking.

Host inventory uses AWS CLI v2 [`describe-instances`](https://docs.aws.amazon.com/cli/latest/reference/ec2/describe-instances.html) across the saved regions. It defaults to the discovery tag `graftty:managed=true`; `--all` includes untagged instances. Each entry identifies its AWS account, region, and instance ID. It retains stopped and recently terminated instances and machines outside the current instance pool or placement zones. Hardware lookup batches up to 100 types per request and respects instance-specific CPU options.

Inventory is eventually consistent and does not establish trusted Graftty ownership. Tags are discovery hints. EC2 `running` is a lifecycle state, not agent readiness. JSON reports `readiness: "unknown"` and explicit nulls for CPU utilization, available memory, free disk, pending placements, and telemetry time until authenticated telemetry exists. Incomplete or failed regional queries fail the command instead of silently returning a partial inventory. The command needs a profile and region; it does not require an instance pool.

Paired Linux hosts now sample resources every five seconds and include observations in the existing authenticated panes-state stream. `graftty remote hosts --json` lists paired identities, connection state, resource observations, and freshness. Mac and Mobile share the wire model and client store. The Linux sampler uses successive `/proc/stat` counters, `MemAvailable`, and unprivileged `statvfs` free blocks. Disk measurements identify the filesystem path they describe. Missing or invalid metrics stay unknown. Hosts with admission support publish their pending placement count; older hosts may omit it.

`graftty remote plan --architecture arm64 --cpus 2 --memory-mib 4096 --disk-mib 8192 --json` compares connected Linux hosts using fresh measurements and configurable safety margins. It packs requests onto the smallest suitable remaining memory capacity, explains rejected hosts, and recommends refreshing unknown telemetry before inspecting provider offers. A plan is read-only and always requires host admission. Pending reservations may be unknown; filesystem scope and project readiness still need verification before creation.


`graftty remote placement create --host <paired-name-or-id> --operation-id <uuid> --repository <registered-remote-path> --name <worktree> --architecture arm64 --cpus 2 --memory-mib 4096 --disk-mib 8192 --json` requests host admission and ordinary worktree creation. Query it with `graftty remote placement status --host <paired-name-or-id> --operation-id <same-uuid> --json`. The host must already be paired, connected, and have the repository registered. Creation starts the host shell by default. Add `--dev-container` to create relative Git metadata, prepare an image or Dockerfile environment through the Dev Container CLI, and open its shell. Use `--dev-container-config <relative-path>` for a selected configuration. This does not launch or authenticate an agent.

Admission uses the SSH-authenticated parent device ID and public-key fingerprint, checks worktree-management permission, and persists the operation before Git or terminal startup. Retrying an operation with a different parent or changed arguments fails. Creation returns the durable `preparing` operation immediately after admission; the host owns setup independently of the request connection. Query status for completion. Successful retries return the saved result. Host shutdown cancels and awaits its placement jobs before releasing state ownership. Restart during creation and partial creation failures retain the claim with `outcomeUnknown`; they never automatically start creation again. Deleting a tracked worktree releases its claim while retaining the operation identity. Unresolved partial failures require inspection and removal of the partial worktree; automated reconciliation is still pending.

The host checks fresh CPU and memory measurements, probes the destination filesystem, and adds retained workload estimates to the new request. It uses an 80% CPU ceiling plus 512 MiB memory and 1 GiB disk margins. Estimates remain reserved for created worktrees until deletion, which can conservatively count some usage twice. A full history of 10,000 operations stops new admissions rather than forgetting retry identities. The CLI pins the selected host fingerprint; it does not reroute a failed request to another host. Mac and Mobile share the placement wire model, with CLI initiation on Mac; native placement UI is pending.

The consumer records receipt time, rejects future timestamps beyond five seconds, expires observations after thirty seconds, and clears them on disconnect. Replayed timestamps do not refresh receipt time. Legacy hosts and malformed optional telemetry do not break pane snapshots. EC2 inventory and paired-host observations are still separate; linking them requires trusted instance enrollment, not tag matching. The desktop Mac host does not yet publish resource samples; the new sampler runs in the headless Linux host.

`max-instances` and `credit-mode` are saved for future provisioning. `max-hourly-usd` currently filters individual offers; fleet spending enforcement requires the placement controller. This slice does not launch instances. Automatic placement and provisioning, complete Dev Container agent integration, parent replication, interruption handling, and the remote-host skill remain backlog work. The project-setup skill is bundled for both Claude and Codex; it guides version-controlled Dev Container setup, resource and authentication requirements, and verification across worktrees.

AWS public-key enrollment is available through `graftty provider enroll aws`. The instance must already run SSM Agent, have Systems Manager connectivity and permissions, and have a prepared Graftty host installation. Install binaries in the image, then run `graftty-host setup` as the development user on each instance at first boot. Do not bake generated identity files into an AMI. Enrollment uses that same user's existing identity and explicit state directory; it never generates a replacement private key during an enrollment retry.

```sh
graftty provider enroll aws --profile development --region us-east-1 \
  --account-id 123456789012 --instance-id i-0123456789abcdef0 \
  --operation-id <stable-uuid> --user ubuntu \
  --host-executable /home/ubuntu/.local/bin/graftty-host \
  --host-state-directory /home/ubuntu/.local/share/graftty --json
```

This explicit enrollment command requires the running Mac app. It retrieves the Mac's client and retained server public keys, records the operation and exact target, checks the selected profile's AWS account, and runs the host's `enroll-parent` command through SSM as the development user. The library accepts the same operation and exact instance from future provisioning code. It grants only replication permission to the worker on the Mac. The parent receives management permission on the worker. Repository/ref delegation and the actual callback connection are separate steps.

Pending enrollment retries resume the saved SSM command instead of submitting another one. Completed retries verify current trust without restoring revoked permissions. Changed identities, conflicting instance bindings, malformed output, and corrupt history fail closed. A crash after persisting a binding but before granting trust also fails closed on retry; inspect the binding and explicitly initiate a new enrollment operation after resolving it. A terminal SSM failure retains the failed command for diagnosis; fix its prerequisites and use a new operation UUID. There is no automated key-rotation or history-forgetting command.

Tests exercise provider errors and identity mismatches using an AWS CLI fixture. A real SSH loopback test then uses the enrolled worker key to prove possession and test scoped Git access. No live AWS infrastructure was created or enrolled during development.

`graftty provider probe aws --operation-id <enrollment-uuid> --json` now opens an SSH connection through AWS Session Manager and reads one authenticated resource observation. It requires AWS CLI v2 and the Session Manager plugin on the parent Mac, plus a running Graftty host and SSM Agent on the worker. The CLI checks the saved account, parent identities, worker key, and current trust before connecting, then pins that worker key during SSH authentication. It obtains the instance and SSH port from the completed enrollment; callers cannot override them. Missing measurements stay unknown. The probe closes its SSH connection and stops the proxy process group on completion, error, or cancellation. Tests cover real SSH over process pipes, bidirectional control, resource observations, mismatched keys, timeout, and process cleanup. Live validation passed on an ARM64 t4g.xlarge Spot instance using a temporary parent identity, the default AWS CLI profile, SSM, and a locally built Linux package. The installed Mac app used during testing predates the parent-server-identity API, so the app-backed CLI enrollment path still requires an updated app.

The first AWS transport uses the existing `AWS-StartSSHSession` document and the CLI's standard streams. The Mac opens the provider tunnel, and either endpoint can send requests inside the authenticated connection. No local TCP forwarding listener or inbound security-group rule is needed. This is the initial transport choice; persistent connection ownership, reconnect, and production worker-to-parent replication are still pending. It does not yet add the host to the app's connected-host inventory. [AWS SSH proxy documentation](https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-getting-started-enable-ssh-connections.html)

The Dev Container CLI adapter now resolves selected JSONC configuration, runs image/Dockerfile lifecycle setup, and verifies Git access in the returned container. It waits for process exit, records the selected configuration digest, labels containers by workspace and placement operation, and rejects Compose, escaping configuration paths, and unsupported absolute linked-worktree layouts. Relative worktrees require the upstream common-directory mount option. It does not inject credential mounts or report agent authentication readiness. Container placement uses a distinct protocol request, so older hosts reject it instead of silently creating a host-shell worktree. Git and Dev Container CLI compatibility checks run before admission. The host records the prepared container identity before pane startup and uses it for restored panes, splits, and explicit pane commands. Deletion rejects already-dirty worktrees before stopping their containers. It stops the retained or operation-discovered container before Git removal, restarts it if Git refuses deletion after stopping even when the caller cancels, and removes the stopped container after success. Cleanup failures retain the container ID in the placement result; volumes are preserved. Labels locate local resources only after operation authorization; they never establish parent identity.

Relative worktrees require compatible Git versions on the host and inside the container. The optional container shell does not yet provide Graftty agent integration, independent agent login automation, or durable native session mounts. Tests use a fake container CLI and real temporary Git repositories; the local Docker daemon was unavailable for a live container smoke test.

The parent-side Git delegation store persists the expected device and key fingerprint, repository ID, remote worktree, exact branch refs, assignment generation, and expiry. It reloads under a process lock on every access, rejects an entire request if any ref is unauthorized, and retains revocation across restarts. Reassignment advances the generation by one; changed retries and older generations fail. Ref and path comparisons preserve their UTF-8 bytes.

A native Git pre-receive hook now checks the complete update set against parent-owned authenticated context, rejects deletion and non-commit targets, and rechecks authority after inspecting quarantined objects. Real Git push tests verify that mixed authorized/unauthorized updates are rejected together and revoked assignments cannot update refs. The hook runs through `graftty internal git-receive-check`; its context must be created by the authenticated receiver, never accepted from a child request.

The receiver preparation component now allocates a private bare repository per delegation and generation, verifies its object format, and creates a receive command with an immutable parent-owned hook context. It supports SHA-1 and SHA-256, uses empty Git templates, and isolates the receive process from inherited Git configuration. Native push tests cover retry reuse, generation separation, and attempted hook overrides. Receive contexts remain on disk until the future transport owner can safely clean them up after process exit.

A separate Git control subsystem is available in the shared SSH implementation for direct and WebRTC connections. It is disabled until a receiver registers callbacks, requires desktop/host identity and explicit replication permission, and gives those callbacks the SSH-authenticated device and fingerprint. Direct SSH loopback tests verify bidirectional requests and reject disabled or unconfigured access.

The receive broker now bounds pending preparations, returns only a short-lived opaque token, and requires the authenticated data-channel peer to claim it once against the current delegation. It expires tokens using a monotonic clock, rechecks authority after preparation, and removes only unused hook contexts. Claimed contexts belong to the future process owner and must remain intact until Git and its children exit.

Git pack streaming, app/host receiver registration, and origin publication are not connected yet.

Replication permission defaults to disabled for new pairings and legacy records. Configured receivers admit replication-only workers without terminal or worktree-management permission; the dispatcher rejects their other channels. Git requests recheck the trust store, including on already-open control channels. Host-initiated startup and reconnect are also pending; the headless Linux host currently listens for direct SSH and does not include the Apple WebRTC framework.

Dev Container subprocesses opt into cancellation so host shutdown can terminate a running CLI command. Other CLI callers retain their existing completion behavior. A canceled Docker command can leave resources on the daemon; the placement remains uncertain and its operation labels support later inspection and cleanup.

The implemented requirements are `REMOTE-24.1`, `REMOTE-24.2`, `REMOTE-24.8`, and `REMOTE-24.10` through `REMOTE-24.20`, plus `REMOTE-25.1`, `REMOTE-25.6`, `REMOTE-25.7`, `REMOTE-26.10` through `REMOTE-26.14`, `REMOTE-26.17`, `REMOTE-26.18`, `REMOTE-26.20` through `REMOTE-26.27`, `REMOTE-28.1`, `REMOTE-28.2`, `REMOTE-29.2`, `REMOTE-29.8`, and `REMOTE-29.9`. The remaining disabled inventory entries still describe future behavior.

Both agent plugins now bundle the `remote-host` skill alongside `project-setup`. It explains the recorded parent, independently authenticated origin publication, parent fallback, separate Git/session receipts, and parent-proxied MCP execution location. It explicitly identifies runtime features still pending rather than inventing working commands. Packaging tests verify both skills remain readable after each provider caches its plugin independently and the preparation directory is removed.

The byte relay now uses SwiftNIO inbound backpressure and waits for each destination write to flush before forwarding EOF. It preserves the reverse stream for Git's final response and closes both endpoints on cancellation, deadline, failed authorization, or oversized input. A native Git push through Unix-socket and process-pipe endpoints verifies transferred refs, blob contents, and repository integrity. This validates the stream component; authenticated SSH data-channel integration, durable parent receipts, and periodic replication remain pending.

Connection preparation now uses a provider registry. The AWS adapter owns enrollment lookup, account verification, SSM arguments, and current-trust checks. Shared callers use an opaque provider binding and a pinned SSH identity. Tests exercise a second provider and reject changed bindings, transport substitutions, and revoked trust. This connection contract does not yet cover automatic provisioning or recovery.

Hosts configured with `graftty-host serve --compute-provider aws` now poll IMDSv2 independently of agent turns, before advertising readiness and every five seconds thereafter. The AWS adapter uses bounded curl requests with explicit proxy bypass and no redirects. A missing notice differs from a failed observation. The host status command exposes the last successful observation and a sanitized error. Other providers can implement the shared interruption-source protocol.

An interruption starts one durable drain operation containing the managed placement records. It rejects new admission and direct worktree creation, survives restart, retains existing request results, and only shortens the deadline when another warning arrives. Resource observations mark the host as no longer accepting placements, so shared Mac/Mobile placement models reject it. This currently establishes the drain barrier and operation record. Writer coordination, WIP commits, Git/session transfer acknowledgements, and replacement-host recovery are still pending; a drain record is not a claim that work has been saved.

## Agreed direction

The implementation must support additional providers after AWS. Shared placement, parent trust, Git/session replication, recovery, and progress models must depend on provider contracts. AWS CLI pricing, instance lifecycle, IAM/SSM bootstrap, and proxy construction belong to the AWS adapter. Exercise the contract with a fake second provider; AWS instance IDs, regions, and SSM documents must not become shared recovery identifiers.

- Configure the `aws` provider through the CLI using an existing AWS profile. Save each user's provider, region, instance-pool, and preferred-type settings.
- Compare Spot prices across eligible instance types and Availability Zones. Monitor host load to decide whether new work fits an existing host or needs another instance.
- Keep the preferred instance type configurable. `t4g.xlarge` is an example preference from this discussion, not a product-wide default.
- Prepare projects on demand. A host can serve multiple projects and multiple worktrees.
- Base project environment setup on the Development Container Specification. Provide a skill to prepare each project for this workflow.
- Regularly replicate commits and native agent session data to the initiating Mac, including unfinished work that has no PR or MR.
- Allow remote hosts to push directly to `origin` using credentials already configured there. Otherwise, let the agent push to its parent and request publication from the parent.
- Do not move private keys, copy authentication stores, or automatically forward credentials between machines.
- Let workers use granted MCP servers through a proxy on their parent Mac. Keep upstream authentication and refresh on the Mac; do not export MCP credentials to workers.
- Authenticate incoming work against the host and delegation the parent expects. A claimed hostname, branch, or Git author is not sufficient.
- On a Spot interruption warning, immediately drain the host and attempt to commit and transfer every affected worktree and its sessions to its parent before interruption.
- Add a remote-host skill that explains the parent relationship and publication fallback.

Worktree session discovery and a native Resume UI are tracked separately in [issue #544](https://github.com/btucker/graftty/issues/544). They can ship before cross-host replication.

## Scope and ownership

The **parent** is the initiating Mac that delegates a worktree. The **host** runs that worktree. A **compute provider** supplies machines. Claude and Codex are **agent runtimes**, not compute providers.

Parent ownership belongs to each delegation, not permanently to an instance. A reused machine may eventually hold work for different parents. Draining that machine routes each worktree to its recorded parent.

Mac and GrafttyMobile expose consistent host, preparation, replication, and drain state. Mobile requests go through the coordinating Mac. Mobile does not need an AWS CLI installation or copied AWS credentials. Choosing a coordinator for a mobile-initiated delegation remains a UI design question.

The first implementation supports Linux Dev Containers on AWS. It does not make macOS-only build tasks runnable in Linux containers. Platform and architecture compatibility must be checked before placement.

## Provider and instance preferences

Requirements: `REMOTE-24.1` through `REMOTE-24.3`.

The provider identifier is `aws`, without a separate alias such as `aws-dev`. Its configuration refers to an existing AWS profile and stores preferences, not credential material. Multiple named account configurations can be considered later. Proposed persisted settings include:

| Setting | Purpose |
| --- | --- |
| Provider identifier and AWS profile | Select an account through the installed AWS CLI |
| Allowed regions, Availability Zones, and subnets | Bound eligible locations and network access |
| Launch templates or equivalent image, storage, and network configuration | Define how a compatible host starts |
| Instance-type pool | Define the instance types the user allows |
| Preferred instance type | Express a preference within the pool without hard-coding one for all users |
| Spot policy and optional On-Demand fallback | Make purchasing behavior explicit |
| Maximum host count and hourly compute estimate | Bound automatic expansion |
| Burstable CPU mode | Make Standard versus Unlimited behavior explicit |
| Observation freshness and placement thresholds | Control how capacity decisions use telemetry |

Proposed precedence is explicit request, project placement preference, provider setting, then documented application default. Every JSON response includes the effective values and their source. An explicit request does not silently relax configured spending or host-count limits.

The following is illustrative CLI design, not an implemented command contract:

```sh
graftty provider configure aws --profile development --region us-east-1
graftty provider configure aws --instance-types t4g.large,t4g.xlarge,t4g.2xlarge
graftty provider configure aws --preferred-instance-type t4g.xlarge --market spot
graftty provider show aws --json
graftty provider hosts aws --json
graftty worktree plan fix-auth --provider aws --json
graftty worktree add fix-auth --provider aws --agent codex --prompt-stdin
```

The `provider` CLI implements list, show, update, clear, and removal of saved preferences. Removing a registration does not terminate its instances.

## Placement uses compatibility, capacity, and price

Requirements: `REMOTE-24.4` through `REMOTE-24.9`.

The CLI exposes observations and a placement plan so an agent can inspect or select a destination. Graftty also provides automatic selection using the same constraints. One parent service owns reservations and provisioning for its requests, preventing concurrent agents from independently allocating the same apparent free capacity.

Proposed selection sequence:

1. Resolve the repository, base commit, selected Dev Container configuration, runtime, and resource needs.
2. Exclude incompatible, unreachable, draining, or stale hosts. Treat missing telemetry as unknown, not idle.
3. Compare available memory, sustained CPU demand, disk space, active worktrees, and pending reservations on the remaining hosts.
4. Prefer a compatible existing host with sufficient headroom. Reusable project images and caches reduce preparation time.
5. If no host fits, compare eligible instance-type and Availability Zone combinations using fresh Spot price observations and the configured limits.
6. Reserve the placement before starting preparation or provisioning. Retrying an accepted request reuses its operation ID.
7. Return the selected host or pending instance, reasons, relevant observations, price timestamp, and preparation status.

Use normalized CPU utilization and available memory, not raw load average or worktree count alone. Include disk pressure and pending container builds. Resource requests must account for concurrent worktrees even when each is momentarily idle. The exact sampling interval, headroom, and reservation model are open.

AWS exposes price history through [`describe-spot-price-history`](https://docs.aws.amazon.com/cli/latest/reference/ec2/describe-spot-price-history.html). Select the latest applicable record for each type, product description, and Availability Zone. A price observation does not establish available capacity. Failed allocation attempts should try another eligible candidate with bounded retries rather than launch duplicates.

Proposed ranking is lowest observed compute cost among candidates that meet the workload and availability constraints. The preferred type breaks comparable choices or receives a user-configured premium allowance. It must not silently override a cheaper valid candidate by an unlimited amount. The preference strength needs a final CLI definition.

Do not move an active worktree merely because another pool becomes cheaper. Routine price changes affect new placements. Replacement after interruption is a distinct operation.

### The t4g.xlarge example

`t4g.xlarge` has 4 vCPUs, 16 GiB of memory, and an Arm-based processor. Its CPU baseline is 40% per vCPU. Those characteristics make architecture checks and sustained-load measurements necessary. [AWS T4g specifications](https://aws.amazon.com/ec2/instance-types/t4/)

Burstable instances consume CPU credits above baseline. Standard mode can reduce performance when credits run out; Unlimited mode can incur surplus-credit charges. The placement plan must expose the selected mode and avoid presenting the Spot instance rate as the complete cost of sustained builds. Storage, network charges, and any surplus-credit charges are separate from that rate. [AWS CPU credit behavior](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/burstable-credits-baseline-concepts.html)

## Host preparation and Dev Containers

Requirements: `REMOTE-25.1` through `REMOTE-25.5`.

Machine readiness and project readiness are separate. A new instance first needs a working Graftty host, trusted connectivity, Git, a container engine, and a compatible Dev Container CLI. Project-specific dependencies belong in the repository's environment definition.

Use the reference [`devcontainer` CLI](https://github.com/devcontainers/cli/blob/main/README.md) to resolve configuration, create environments, and execute commands. Do not recreate its configuration parser or lifecycle ordering in Swift. The specification supports images, Dockerfiles, Features, lifecycle commands, and Compose-based environments. A tested support matrix must identify which combinations Graftty initially supports. [Dev Container reference](https://github.com/devcontainers/spec/blob/main/docs/specs/devcontainerjson-reference.md)

Proposed preparation sequence:

1. Transfer the selected repository history and exact base commit, including unpushed commits available on the parent.
2. Register the project on the host, then create the requested worktree.
3. Read the Dev Container definition at that revision. Select a configuration explicitly when several exist.
4. Build or reuse the matching environment image and create the worktree's container environment.
5. Complete the required lifecycle setup and verify the requested agent executable and authentication readiness.
6. Start the pane and agent inside that environment, with Graftty integration and the recorded parent relationship.

Proposed default: one container environment per worktree, with shared immutable image layers and appropriate dependency caches on the machine. Multiple worktrees must not share mutable dependency directories or database state accidentally. Compose project names, volumes, and host port mappings need worktree-specific identities.

A shared project checkout or Git object store can avoid repeated clones. Container mounts must make linked-worktree Git metadata usable without granting arbitrary access to unrelated repositories. The mount layout and whether container workspaces use linked worktrees or independent clones need a compatibility experiment.

Honor configuration lifecycle semantics. In particular, `initializeCommand` runs on the remote machine, and `waitFor` determines the configured connection readiness point. Agent launch may require an additional application readiness check if dependencies are still being installed. Host requirements inform placement but do not reserve capacity by themselves. [Lifecycle and host requirements](https://github.com/devcontainers/spec/blob/main/docs/specs/devcontainerjson-reference.md)

Persist native agent session data outside disposable container writable layers. A rebuild must not erase conversation history. Tool installation and agent login remain distinct. No automatic copying of the parent's agent authentication files is part of this design.

## Git replication and publication

Requirements: `REMOTE-26.1` through `REMOTE-26.4`.

The host phones home to each recorded parent at startup and restores the connection after a disconnect. It retains the parent's public identity and connection information with the delegation. The connection authenticates both devices against their enrolled public keys; an address or instance tag never establishes trust. Enrollment must not copy a private key. The parent's grant to a worker permits only scoped replication, not control of the parent's terminals, worktrees, browsers, or agents. Multiple worktrees for one parent share a connection, while worktrees for different parents keep their authority separate.

Phone-home must work from Linux through the parent's usual NAT or firewall without requiring a publicly reachable SSH port on the Mac. The existing WebRTC implementation is Apple-only; Linux connectivity and rendezvous are explicit implementation work. Rendezvous or a relay locates and carries the connection but cannot authorize a peer or read the authenticated SSH stream. Dialing direction does not determine which device may request a Git transfer.

The host retries unavailable parents with bounded exponential backoff and jitter, and attempts reconnect promptly after a network change or interruption warning. Reconnects recheck current pairing and delegation authority. Revoked identities and obsolete generations cannot resume transfers. A reconnect reconciles receipts before retrying an operation whose outcome is unknown.

The connection carries readiness and load reports, Git and native-session transfer requests, acknowledgements, and Spot interruption notifications. The parent may also fetch committed work, and a remote agent may explicitly push to the parent. Both operations retain ordinary Git objects and refs. They do not require a PR, an MR, or publication to `origin`.

Parent sleep and wake recovery is deferred. The following wake behavior is a future extension, not a prerequisite for the first release. When the parent is unreachable, attempt to wake it before concluding that it will remain unavailable. Reuse Graftty's signed wake advertisements and bounded connection retries. The existing sender broadcasts only on a matching local IPv4 subnet; an AWS worker cannot use that path directly to reach the Mac's LAN. Remote wake requires a reachable, awake LAN peer or a configured router/wake proxy. Any peer-assisted wake request must authenticate the requester and restrict the target to the recorded parent. Wake relay support is additional work, not an existing capability. A routed VPN alone does not carry the local wake broadcast. [Tailscale's remote wake architecture](https://tailscale.com/blog/wake-on-lan-tailscale-upsnap)

A sent wake packet does not prove that the Mac woke or received work. Authenticate the restored connection and wait for Git and session receipts. Wake and connection attempts share the Spot interruption deadline and must not delay transfers to other reachable parents. If the parent remains unreachable, retain unacknowledged work locally while the host survives and report the last acknowledged Git commit and session progress separately. Parent-offline durability still requires a separately chosen durable destination.

Proposed transport is a dedicated Git subsystem over the existing authenticated SSH connection. It works with SSH over WebRTC and direct SSH. A Git remote helper can bridge standard Git traffic to the Graftty connection; Git performs object negotiation and transfer. [Git remote helpers](https://git-scm.com/docs/gitremote-helpers)

The parent receive path must be implemented explicitly. Existing terminal channels are not a generic reverse Git server. Channel negotiation, flow control, exit status, cancellation, and reconnection behavior need tests in both connection directions. Prefer the existing bulk transport where available so a large pack does not monopolize interactive traffic.

Expose a parent remote, provisionally `graftty-parent`. Receive work into host- and delegation-scoped refs or a bare repository. Receiving a branch must not replace the parent's active checkout or another delegation's branch. The exact storage layout is an implementation choice, not a new checkpoint format.

Publication is a separate request:

1. If the remote host has independently configured origin credentials, the agent may push directly.
2. Otherwise, the agent pushes to the parent and asks the parent to publish the received commit.
3. The parent resolves the destination from its own repository configuration and publishes the exact requested commit to the authorized ref.
4. The parent returns a result scoped to that request. A lost acknowledgement yields an unknown outcome until reconciliation, not an automatic force-push or a false success.

A missing credential or unavailable direct route can trigger the fallback. A non-fast-forward rejection still requires Git history resolution. Parent replication does not itself authorize origin publication. Routine commit frequency and whether ordinary commit guidance belongs in the main skill remain open; the Spot drain below is mandatory host behavior.

## The parent verifies the source of incoming work

Requirements: `REMOTE-26.5` through `REMOTE-26.9`, and `REMOTE-26.20`.

Reuse existing implementations at each boundary. The Dev Container CLI owns project configuration, container creation, Features, and lifecycle commands. It already runs through Graftty's adapter. Host authentication comes from the connection layer; the documented remote Dev Container workflows use SSH or Remote Tunnels underneath the environment setup. Graftty should not create another container engine or authentication protocol. [Dev Container CLI](https://containers.dev/supporting#dev-container-cli), [remote Dev Container connections](https://code.visualstudio.com/remote/advancedcontainers/develop-remote-host)

For AWS, use Systems Manager Run Command through the installed AWS CLI as the initial trust channel:

1. Record the launch operation, AWS account, region, and exact EC2 instance ID returned by AWS. Keep enrollment pending until the provider identity and host key are bound.
2. Target that exact instance with `aws ssm send-command`, rather than selecting by tags. The host generates its Graftty identity key locally. The command exchanges public identities and the enrollment operation ID; private keys stay on their originating machines. The Mac has separate client and server keys. Send both public keys, using the client key for incoming parent management and pinning the server key for callbacks.
3. Retrieve the result with `aws ssm get-command-invocation` for the recorded command and instance IDs in the same account and region. Require successful execution and a complete, bounded identity response for that pending operation. Persist the instance-to-public-key binding before accepting callbacks. A retry must return the same key; changed keys require explicit re-enrollment.
4. Authenticate phone-home through the existing SSH implementation. The host proves possession of the enrolled private key as part of the fresh SSH handshake, and verifies the parent's enrolled server key. The parent derives sender identity from that handshake, then checks each operation against its active delegation.

AWS provides the authenticated management path and command targeting; Graftty records the resulting binding. This approach requires SSM Agent, connectivity to Systems Manager, and an appropriately scoped instance role or supported Systems Manager management configuration. It uses the Mac's existing AWS CLI authentication and does not copy those credentials to the worker. If these prerequisites are missing, report the setup requirement rather than trusting the first callback. The enrollment path is implemented for explicitly selected, prepared instances; launching and preparing those instances automatically remains pending. [Run Command targeting](https://docs.aws.amazon.com/cli/latest/reference/ssm/send-command.html), [command results](https://docs.aws.amazon.com/cli/latest/reference/ssm/get-command-invocation.html), [instance permissions](https://docs.aws.amazon.com/systems-manager/latest/userguide/setup-instance-permissions.html)

An instance ID in a request, an IP address, or a signed EC2 instance identity document by itself does not bind the current connection to the worker's Graftty key. The identity document describes instance attributes; accepting a copy as a login credential would omit proof of possession for this connection. Keep the provider-mediated enrollment and standard SSH key authentication. [EC2 identity document fields](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/instance-identity-documents.html)

Before delegation, the parent records the repository identity, delegated worktree ID, expected remote device identity and public-key fingerprint, permitted refs, and current assignment generation. Instance IDs and labels help locate a host but do not authenticate it.

For every incoming transfer and publication request:

- Derive the sender from the authenticated connection. Do not accept a request field, hostname, Git author, or branch name as proof of identity.
- Match that sender to the active delegation and its allowed repository and refs.
- Reject expired assignments, revoked peers, and requests attributed to another host or worktree.
- Associate accepted refs and commit IDs with the authenticated sender and delegation before acknowledging receipt.
- Authorize publication against that receipt and the parent's configured destination. A child cannot supply an arbitrary URL for the parent to access using its credentials.
- Bind retries to the same sender, assignment, request ID, destination, and commit. Reject reuse with different contents.

The binding must also hold on bulk channels and after reconnects. Moving a worktree to another host changes its assignment generation so an old host cannot continue publishing as its successor.

Git receive validation must enforce the permitted refs before updating them, including multi-ref pushes and deletion requests. Git's pre-receive mechanism can reject the complete update set. [Git receive validation](https://git-scm.com/docs/git-receive-pack)

This establishes which paired host submitted the work and which delegation it may act for. It does not prove which process authored the code on a compromised host. A per-worktree local control endpoint can narrow ordinary agent access, but stronger isolation between hostile workloads is a separate requirement.

Graftty identity keys remain local to their devices. Public-key pairing is compatible with this design. Copying the parent's SSH private keys, Git authentication stores, AWS credentials, or agent authentication stores to a worker is not.

## MCP access through the parent

Requirements: `REMOTE-30.1` through `REMOTE-30.8`. The proxy approach is agreed; implementation is pending.

A Linux agent uses standard MCP through a local Graftty stdio bridge. The bridge connects through the existing authenticated parent connection to a parent-owned MCP client. That client talks to the selected upstream server. No public MCP listener or inbound Mac port is required. This is independent of AWS and works over the same authenticated connection whether its transport is WebRTC or SSH through a provider.

Reuse the [official Swift MCP SDK](https://github.com/modelcontextprotocol/swift-sdk) for client/server behavior and supported transports. Pin a tested version and negotiate its supported protocol version. Graftty owns delegation and transport integration, not a new OAuth implementation. The SDK exposes authorization and token-storage integration, but does not by itself unlock another application's credential store. Validate the chosen SDK release and each authentication adapter before claiming compatibility.

### Configuration and authority

The parent stores stable server IDs and reviewed upstream definitions. A worker selects an authorized ID; it cannot supply a parent command, environment override, credential reference, or upstream URL. Project setup records required server IDs without secrets. Per-user parent policy grants those servers to a project, and each placement receives a grant bound to the authenticated worker identity, repository, worktree, assignment generation, and expiry. Saved policy can authorize subsequent placements without repeated prompts. Discovering a server or pairing a host alone grants no MCP access.

Check current pairing and delegation before opening a session and before forwarding each request. Revocation, expiry, and reassignment stop new calls and close affected sessions. Replacement hosts need new grants; copied agent history and old bridge configuration confer no authority. Keep sessions, request IDs, notifications, and server-initiated requests isolated by delegation. Scope the worker-local bridge to its managed worktree/container. Processes controlling the entire worker remain within that worker's trust boundary.

The proxy authenticates upstream as the parent's configured client. It never sends upstream access tokens, refresh tokens, cookies, credential files, or credential-bearing configuration to Linux. A worker's transport identity is not an upstream bearer token. Upstream discovery and redirects must not let a worker redirect authenticated traffic to a destination of its choosing. [MCP security guidance](https://modelcontextprotocol.io/specification/2025-11-25/basic/security_best_practices)

### Compatibility and execution location

| Server or authentication source | Intended behavior |
| --- | --- |
| Parent-local stdio server | Run the approved command on the Mac with its local authentication; proxy MCP messages. |
| Remote HTTP server | Connect from the Mac using its configured authentication and refresh mechanism. |
| Authentication owned by Claude, Codex, or an app connector | Reuse only through a supported integration with the owning client. Otherwise report setup required or unsupported; do not scrape or export private stores. |
| Tool that needs the Linux worktree, filesystem, or shell | Configure a Linux-local server separately; a parent-local tool still operates on Mac resources. |

Support stdio and Streamable HTTP through upstream implementations. Preserve negotiated cancellation, progress, notifications, and supported server-to-client requests. Do not silently grant sampling, elicitation, or roots access on the Mac to compensate for a worker capability that is missing. Any credential entry or renewed upstream consent stays on the parent. [MCP transports](https://modelcontextprotocol.io/specification/2025-11-25/basic/transports)

MCP access is distinct from the agent runtime's own model-service login. The proxy does not establish a Claude or Codex subscription/API session on Linux. Tool output may itself contain sensitive data, even though Graftty does not forward its authentication material.

### Failure handling and visibility

Bound message sizes, concurrent calls, queues, and deadlines per delegation. Parent disconnection makes proxied servers unavailable; it never triggers credential copying or an unconfigured direct connection. Reconnect checks current authority and establishes a fresh session. A call whose reply was lost may already have changed upstream state. Report its outcome as unknown and do not automatically replay it. Cancellation and revocation cannot undo an upstream side effect already performed.

The CLI, Mac, and Mobile show server ID, execution location, delegation, readiness, and sanitized failure reason. Distinguish ready, parent unavailable, authentication required, unsupported, and revoked. Audit routing and outcomes without recording tokens, credential-bearing URLs, or tool payloads by default. Project setup checks MCP requirements separately from container build success. The remote-host skill explains which tools act on the Mac and how to handle unavailable or uncertain calls.

Acceptance tests must cover two parents and multiple projects, unauthorized server IDs, hostile URL/command substitutions, stale generations, expiry and revocation during a session, token refresh confined to the Mac, reconnect after a lost mutating reply, and supported callbacks. An integration test must exercise actual Claude and Codex MCP clients through the bridge using fixture credentials and verify that those credentials never reach worker configuration or protocol messages.

## Native session replication and restore

Requirements: `REMOTE-27.1` through `REMOTE-27.4`.

Claude and Codex need separate adapters that discover the native session files associated with a worktree. Back up that scoped data regularly and during an urgent drain. Do not recursively copy `.claude`, `.codex`, or the user's home directory.

Each adapter needs a versioned support contract for stable reads, associated files, path handling, and native resume. Transfer complete records or a consistent provider-supported snapshot. Keep partial transfers temporary until validated. Exclude authentication files, sockets, process IDs, and other machine-local live registration data from restore.

The parent reports Git and session replication separately: latest received commit, latest session progress, timestamps, failures, and whether a writer was still active. These are synchronization records, not Graftty-specific checkpoint artifacts. Independent copies do not automatically form an atomic snapshot.

To resume elsewhere, prepare a compatible project environment, restore the selected Git state and native session data, and use the runtime's native resume mechanism. Regenerate live Graftty registrations and authorized MCP bridge configuration on the destination. Agent-runtime authentication must already be available there or be completed independently; proxied MCP authentication stays on the parent.

Cross-host native resume is not yet validated. An absolute path embedded in history, a missing auxiliary file, or a runtime-version mismatch may prevent it. Preserve the copied data and explain incompatibility rather than presenting a new conversation as a successful resume. Normal migration must stop or hand off the old writer before continuing the same session on another host.

Session data can itself contain sensitive tool output. Excluding credential files does not make transcripts free of secrets; copies retain the source user's access scope.

## Spot interruption handling is part of the first AWS release

Requirements: `REMOTE-29.1` through `REMOTE-29.7`.

AWS normally issues a warning two minutes before a Spot stop or termination. Delivery is best effort. Hibernation starts immediately and does not provide the same window. AWS recommends checking notices every five seconds. The initial policy should use a supported stop or terminate behavior and must not rely on hibernation for drain time. [AWS interruption notices](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/spot-instance-termination-notices.html)

A host service monitors IMDSv2 outside the containers. This path does not depend on an agent noticing a message, a model API responding, or the parent's AWS session being active. It uses the notice's deadline rather than assuming a fresh 120 seconds after detection. Rebalance recommendations may trigger an earlier refresh of copies, but cannot replace interruption detection. [AWS rebalance recommendations](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/rebalance-recommendations.html)

On detection, the host immediately starts one drain operation:

1. Mark itself draining, stop accepting placements, and notify all affected parents.
2. Inventory every managed project, worktree, and native session, including idle sessions and work that has never been pushed.
3. Stop new agent turns and builds, and request bounded quiescence of existing writers. Do not wait indefinitely for a turn or process to exit.
4. Create ordinary WIP commits for outstanding source changes, including eligible untracked files and deletions. Push all required branch history to each recorded parent.
5. Transfer each worktree's native session data to its parent, using the runtime adapter's consistent-read rules.
6. Collect per-worktree acknowledgements for both Git and session transfers. Retry recoverable failures only within the remaining deadline.
7. Report complete, partial, or failed drain status, with the last confirmed commit and session copy for each worktree.

Transfers use bounded concurrency so one large repository or unreachable parent cannot starve every other worktree. Prioritize evacuation over new builds and routine background jobs. Repeated notices join the existing drain operation.

No test pass, PR creation, or LLM-generated commit message is a prerequisite for an emergency WIP commit. The implementation must coordinate writers and Git operations, preserve user staging where practical, and avoid deleting lock files or resolving conflicts destructively. Hook/signing behavior, conflict-state preservation, dirty submodules, and Git LFS objects need an explicit evacuation implementation before Spot support is considered complete. A commit of a submodule pointer alone does not preserve its uncommitted contents.

“All work” covers all managed worktrees' source changes and all associated native sessions, not credentials, dependency caches, build products, arbitrary ignored files, or database volumes. Project data outside that scope needs a declared persistence policy. If source cannot be represented by an ordinary WIP commit, report the specific gap; do not claim the work is saved.

The deadline cannot guarantee recovery if the parent is offline, the notice never arrives, or transfer volume exceeds the remaining bandwidth. Regular replication reduces this exposure. A second durable destination is an open design choice, not an implied fallback to `origin` or a reason to move credentials. Report data loss exposure explicitly when an evacuation remains unacknowledged.

Replacement placement can begin once the parent has usable state. Restoring to another instance reruns the Dev Container preparation and native-session compatibility checks. Saving the old host's work takes priority over provisioning its replacement.

## Skills

Requirements: `REMOTE-28.1` and `REMOTE-28.2`. Names below are proposed.

### graftty:project-setup

This skill helps an agent prepare a repository for remote execution. It inspects existing setup and preserves an existing Dev Container definition where possible. It creates or repairs the standard configuration, Dockerfile or Features, lifecycle scripts, required service definitions, and environment documentation.

The skill identifies architecture and resource requirements, verifies the supported build and test commands inside the environment, and checks that separate worktrees can run without conflicting ports or mutable state. It documents authentication prerequisites without embedding secrets or copying user credentials. Missing verification is reported rather than represented as readiness.

The output is reviewable, version-controlled project configuration. Running the skill does not implicitly provision cloud instances. macOS-only tasks remain identified as such. The skill can help choose project placement preferences, but user account and provider settings stay out of shared repository configuration.

### graftty:remote-host

This skill explains the current host, worktree, parent, and environment using Graftty-provided context. It teaches agents to inspect capacity through the CLI, work inside the prepared environment, and preserve ordinary Git history.

For publication, it permits a direct origin push with existing credentials. Otherwise it instructs the agent to push to the parent and request publication of an exact commit. It distinguishes parent receipt from origin publication and handles pending or unknown results without duplicate requests or unrequested force-pushes.

The skill never directs agents to copy keys or configure automatic credential forwarding. It explains Spot drain behavior, but the host service owns urgent evacuation. Instructions are not the enforcement mechanism for peer identity or delegated Git permissions.

## User-visible and CLI state

Proposed state families remain separate:

| Object | State or observations |
| --- | --- |
| Provider | Saved preferences, credential availability, configuration errors |
| Host | Provisioning, connecting, ready, draining, interrupted, unavailable, failed |
| Project environment | Absent, preparing, ready, failed, incompatible |
| Worktree | Placement, creation, agent readiness, replication progress |
| Git publication | Requested, accepted, succeeded, rejected, outcome unknown |
| MCP access | Server ID, execution location, delegation, ready, parent unavailable, authentication required, unsupported, revoked |
| Spot drain | Deadline, per-worktree commit result, Git acknowledgement, session acknowledgement |

Provider-running state is not equivalent to Graftty-ready state. Show stale timestamps instead of interpreting a disconnected host as empty. Mac and Mobile display these shared facts without requiring either client to infer success from an agent's prose.

## Existing implementation to reuse

- `Sources/GrafttyCLI/Worktree.swift`: remote creation, pending operation IDs, and agent launch.
- `Sources/GrafttyKit/HostSetup/LinuxHostSetup.swift`: Linux installation, project history import, and pairing.
- `Sources/GrafttyTunnel/DataChannel/SSHNIOTransport.swift`: SSH byte streams over WebRTC.
- `Sources/GrafttyHostAgent/SSH/Channels/SubsystemDispatcher.swift`: authenticated custom subsystems.
- `Sources/GrafttyRemoteClient/Remote/DirectSSHHostConnection.swift`: direct SSH transport.
- `Sources/Graftty/Remote/MacToMac/RemoteCLIWorktreeService.swift`: peer-scoped operation handling.
- `Sources/GrafttyKit/Teams/CodexHookSessionBinder.swift` and `ClaudeHookSessionBinder.swift`: native live-session identity binding.

These components do not yet provide compute-provider registration, capacity placement, native-session portability, or the proposed Git transport.

## Proposed delivery order and validation

These are implementation slices, not permission to omit Spot recovery from the first AWS release.

1. Define parent delegation, host-initiated phone-home, authenticated Git fetch and receive, and origin publication results. Implement Linux connectivity to a Mac behind NAT. Test startup, sleeping parents, network changes, impersonation, unauthorized refs, reconnects, duplicate requests, and exact-commit publication.
2. Build provider preferences and read-only host/price discovery. Test per-user persistence, preference clearing, architecture filtering, price freshness, and spending limits.
3. Add placement reservations, AWS lifecycle operations, and Dev Container preparation. Test concurrent placement, ambiguous launch outcomes, incompatible images, and two projects sharing one host.
4. Implement native session adapters and both skills. Prove actual Claude and Codex resume on another host using supported versions, including different filesystem paths.
   Implement the parent MCP proxy and regenerate scoped bridge configuration during placement and recovery. Validate supported authentication sources and real agent clients without exporting credentials.
5. Add Spot interruption monitoring and evacuation. Simulate interruption during edits, a running tool, a locked index, a conflict, session writes, and an in-flight replication. Verify every worktree is accounted for, including partial failures and an offline parent.
6. Exercise the complete workflow from Mac and Mobile, including capacity expansion and recovery onto a replacement host.

Before implementation, promote the relevant disabled inventory entries into failing behavioral tests. Regenerate `SPECS.md` as each requirement moves into its implementation test.

## Open decisions

- Exact CLI names, configuration location, and preference strength versus observed price.
- Initial eligible instance pool, regions, launch templates, CPU-credit mode, and default spending limits. None are implied by the `t4g.xlarge` example.
- Host telemetry cadence, placement headroom, reservation estimates, and treatment of long builds.
- Initial Dev Container support matrix, container/worktree mount layout, and agent integration injection.
- Ordinary commit cadence and its division between skills and runtime automation.
- Emergency commit semantics for staging, hooks, signing, merge conflicts, submodules, and LFS content.
- Session adapter version support, related files, stable-read boundaries, and path remapping.
- Parent-offline durability and whether users can select another durable destination.
- Native agent authentication on new hosts without copying existing credentials.
- Supported integrations for MCP authentication owned by existing agent clients or app connectors; compatibility must be demonstrated per integration.
- Exact SSM launch-template prerequisites and least-privilege IAM permissions for provider-mediated public-key enrollment.
- Parent reassignment when the initiating Mac is permanently unavailable, and lifecycle policy for idle machines.
