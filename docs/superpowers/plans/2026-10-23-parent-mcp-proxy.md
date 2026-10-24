# Parent MCP proxy

Remote agents need the parent's MCP tools without receiving its credentials. The
parent initiates SSH through the provider tunnel, then serves worker requests on
that same authenticated connection. No inbound port on the Mac is required.

## Current path

- `graftty remote mcp start --provider aws --operation-id <enrollment> --policy <file>`
  saves connection intent in the Mac app. The app connects without a foreground
  terminal, retries transport failures and restores saved intent on app launch.
- `graftty remote mcp status --json` reports `connecting`, `connected`, `retrying`,
  `blocked`, or `stopping`. `connected` means the authenticated transport is ready;
  each grant and upstream authentication are checked separately.
- `graftty remote mcp stop --provider aws --operation-id <enrollment>` removes
  saved intent before acknowledging shutdown. Transport cleanup can finish after
  the response; a stopping connection cannot be replaced until cleanup completes.
- `graftty remote mcp connect --provider aws --operation-id <enrollment> --policy <file>`
  remains available for an explicitly foreground connection. Do not run it alongside
  an app-owned connection to the same worker; a new parent channel replaces the old one.
- The worker's private control socket serves `graftty remote mcp bridge --config
  <file>`. Each invocation is an ordinary MCP stdio server for one grant.
- `graftty remote mcp stage --grants <json-array> --directory <new-directory>
  --executable <worker-cli> --socket <worker-socket>` creates private bridge
  addresses plus `claude-mcp.json` and `codex-mcp.toml`. `--agent-directory`
  supplies the directory as seen inside a container. Staging rejects an existing
  destination and does not overwrite an agent's settings. Installation into a
  prepared container remains a separate step.

Managed placement also accepts `graftty remote placement create ...
--dev-container --skill-revision <runtime:revision> --mcp-grants <file>`. The
file is a JSON array of `MCPProxyScope` addresses from explicit parent grants.
All selections must identify the new worktree, one repository and one assignment
generation. The host derives the parent identity from the authenticated placement
request. A distinct protocol request prevents old hosts from ignoring MCP setup.

This path installs native Codex and Claude user configuration into the new private
profile. It mounts a dedicated socket directory at `/run/graftty-mcp` and the
installed Linux Graftty runtime at `/opt/graftty-mcp`, both read-only. It does not
mount the host's general control socket. The endpoint admits only selected grants
and successfully opened sessions belonging to that profile. General host commands
are rejected. Native tools still use the original server names.

Dev Container CLI 0.89.0 rejects Docker's `readonly` flag in its `--mount`
option. The adapter adds these mounts to a private override of the configuration
returned by upstream `read-configuration`. It retains the original `--config`
path for relative Dockerfile/feature resolution, preserves project mounts and
lifecycle settings, and removes the override after preparation. The project file
is unchanged. See the upstream [argument parser](https://github.com/devcontainers/cli/blob/v0.89.0/src/spec-node/devContainersSpecCLI.ts)
and [configuration override handling](https://github.com/devcontainers/cli/blob/v0.89.0/src/spec-node/configContainer.ts).

Container setup verifies the socket mount and executes the packaged bridge's
help command before reporting `mcpConfigured`. The image must be compatible with
the packaged Linux runtime, and its remote user must match the host UID. This
status describes installation; it does not establish current parent connectivity,
upstream authentication, or model login. An app-owned or foreground parent
connection must still be running. Host-service restart recreates endpoints from
completed placement records; deletion and shutdown remove their sockets and close active sessions.
Native profiles remain on the host after container deletion. This does not yet
provide machine-reboot or replacement-host recovery.

The original logical MCP server names remain in native agent configuration. The
proxy forwards JSON-RPC messages, including notifications, cancellation and
server requests. It does not advertise a forwarding tool or add capabilities to
those negotiated by the agent and upstream server.

## Authority and failure behavior

The parent policy contains reviewed stdio commands and grants binding worker
identity and key fingerprint, repository, worktree path, assignment generation,
server ID and expiry. A worker supplies only that grant's address. It cannot
supply an upstream command, URL, environment or credential reference.

Current parent policy and enrollment trust are checked before opening and using
an upstream session. Idle sessions are checked every 250 ms for revocation,
expiry and policy changes. The worker also checks its current pairing with the
parent before forwarding a local bridge request. Pairing alone confers no MCP
grant.

Each SSH channel owns its upstream sessions. Disconnects close them and produce
an unknown outcome for calls whose replies were lost. Reconnect does not replay
calls. A bridge acceptance is only transport admission, not tool completion.
The worker registration handshake completes before the parent reports readiness.

The app saves only provider/enrollment identifiers and the parent-local policy
path, in a private file. It supports up to 32 saved connections. Each attempt
uses a fresh MCP broker, rechecks enrollment and parent identity, and closes its
upstream sessions before another attempt. It borrows the app's interactive SSH or
WebRTC connection when one already exists for the exact enrolled device and key.
Otherwise it owns a provider connection. Stopping MCP closes its own channel and
upstream sessions while leaving a borrowed interactive connection open. Retries
back off from one to 30 seconds; a connection stable for 30 seconds resets the backoff.
Local authorization failures produce a sanitized `blocked` status. Correct the
configuration, then stop/start that connection to retry. Network or provider
availability failures continue retrying. Policy and identity failures stop MCP on
that connection; individual grant revocation closes the affected MCP sessions.
App termination cancels reconnect tasks and synchronously stops tracked MCP and
provider-tunnel subprocess groups. Process creation and shutdown share a lock so
termination cannot miss a newly spawned child. Saved intent remains for the next
launch. The POSIX launcher closes unrelated inherited descriptors on macOS and
Linux; otherwise an MCP subprocess can keep an SSH socket alive after closure.

Limits are 256 KiB per message, 32 active sessions per parent connection, 64
outstanding requests in each direction per session, 16 queued writes, 512 KiB of
queued writes and 256 KiB of queued replies. Unanswered requests expire after
120 seconds independently of other traffic. Idle sessions expire after one hour.
A parent channel retains at most 1,024 session identities. The worker bridge and
each profile endpoint also retain up to 1,024 identities for their service
lifetime; reconnect alone does not reset those bounds. Errors omit upstream diagnostics and payloads.

## Reused components and compatibility

The official [Swift MCP SDK](https://github.com/modelcontextprotocol/swift-sdk)
provides stdio transport and is pinned to commit
`72a09adb79e0b7112df92949612533c013c6c664`. Release 0.11.0 fails Swift 6.4
concurrency checks in NetworkTransport; the pinned upstream revision fixes that
failure. Graftty reuses its existing SSH framing and duplex RPC channel code.

The generated Codex configuration follows the [native MCP table format](https://learn.chatgpt.com/docs/extend/mcp?surface=cli).
Claude receives a standard `mcpServers` configuration. Commands execute on the
parent, so their filesystem and shell access also occur on the parent.

Only explicitly configured parent-local stdio servers are enabled initially.
They may use their existing parent authentication. The parent passes the normal
HOME/PATH/TMPDIR/LANG variables and any explicitly approved environment keys.
The proxy does not read another client's private authentication database.

HTTP definitions currently fail closed. The pinned SDK's custom URLSession
initializer is internal, so authenticated HTTP support needs a supported way to
control redirects and integrate parent authentication. SDK support alone does
not make another application's OAuth tokens available. Model login on the
worker is also separate.

## Remaining integration

Automatic policy/grant creation during placement, configuration refresh for
existing profiles, HTTP/OAuth adapters, and
shared Mac/Mobile readiness UI remain pending.
The connection service and native configuration artifacts do not claim full
settings or plugin parity. Git/session replication and Spot recovery remain
separate unfinished work.

## Validation

The SSH loopback test uses the SDK's client, a worker bridge, real SSH and a real
parent subprocess. It verifies unchanged tool discovery, parent execution and
rejection of a stale assignment generation. App-owned reconnect tests cover direct
SSH and subprocess tunnels, a parent-side mutation whose reply is never received
by the worker, invalidation of old sessions, and provider revocation. A separate
integration test checks that stopping MCP leaves borrowed interactive channels
usable. Unit tests cover scoped grants,
revocation, callbacks, transport failure and request budgets.

The app-owned lifecycle passed 72 focused tests on 2026-10-23, including direct
SSH and subprocess-tunnel reconnect, lost-reply handling, revocation, borrowed
interactive connections, CLI routing and subprocess cleanup. A separate probe
ran the production POSIX launcher under Swift 6.2.3 on Ubuntu 24.04 and verified
that an unrelated descriptor was closed while stdout remained usable. This was
a launcher probe, not a full Linux package test run. The app-owned lifecycle has
not yet been exercised on a new Spot worker; the Spot results below cover the
earlier proxy and managed-profile paths.
The subsequent `scripts/swiftpm test --no-parallel` run passed in full, including
the native sidebar test that failed in the previous managed-mount run. Generated
specs, Linux test membership, and whitespace checks also passed.

`GRAFTTY_LIVE_AWS_MCP=1` enables the additional disposable-host path in
`AWSLiveHostTests`, alongside `GRAFTTY_LIVE_AWS_TARGET` and
`GRAFTTY_LIVE_AWS_RESULT`. The worker needs native Codex and Claude executables.
The test runs the production Linux service and CLI bridge, executes a tool on
the Mac, and queries both native agents for MCP discovery. It makes no model
turn and never transfers the parent's credential fixture. The test does not
provision infrastructure; resource lifecycle and cleanup belong to the live
harness.

Live validation passed on 2026-10-23 using an ARM64 m7g.xlarge Spot instance,
Ubuntu 24.04, the packaged Linux host/CLI, AWS SSM, Codex 0.164.0, and Claude
Code 2.1.309. Both native clients discovered `touch_parent` under the original
server entry. A standard MCP call through the worker CLI executed exactly once
on the Mac using a credential fixture that remained there. Altered assignment
generation and subsequently revoked grant addresses were rejected. The native
clients used fresh homes without model credentials; this validates MCP discovery
and transport, not a model turn or automatic container profile installation.


Managed-container validation also passed on 2026-10-23 with the same runtime
versions and an ARM64 m7g.xlarge Spot worker. Set
`GRAFTTY_LIVE_AWS_MCP_CONTAINER` to a registered disposable fixture repository to
exercise this path. The fixture used a relative Dockerfile, an existing read-only
project mount, and a lifecycle command checking that mount. Production placement
installed both native profiles and scoped bridge files. The test did not stage
or write their MCP settings itself.

Before and after a container restart, both clients discovered `touch_parent` and
a bridge call executed on the Mac. The parent credential fixture stayed on the
Mac. The test verified read-only socket/runtime mounts, rejection of general host
discovery, a changed generation, and another grant which the parent would have
authorized. That unselected grant never reached the parent. Deletion removed the
scoped socket and retained the profile. The successful live run took 46.5 seconds
and made no model turn. Host-service restart and machine recovery were not part
of this live test.

The live run caught the CLI mount syntax incompatibility described above. Its
regression passed with the container/profile suites, and generated-spec and
Linux-membership checks passed. A complete sequential suite passed before that
fix. The full rerun after the fix passed all Swift Testing suites but failed
`SidebarSortNativeTests.testSortTargetsInBothSidebarModes`, which also failed in
isolation while opening its native menu. That UI code was unchanged.
