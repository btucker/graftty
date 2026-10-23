# Parent MCP proxy

Remote agents need the parent's MCP tools without receiving its credentials. The
parent initiates SSH through the provider tunnel, then serves worker requests on
that same authenticated connection. No inbound port on the Mac is required.

## Current path

- `graftty remote mcp connect --provider aws --operation-id <enrollment> --policy <file>`
  owns a foreground connection to an already enrolled worker. Keep it running.
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

Container setup verifies the socket mount and executes the packaged bridge's
help command before reporting `mcpConfigured`. The image must be compatible with
the packaged Linux runtime, and its remote user must match the host UID. This
status describes installation; it does not establish current parent connectivity,
upstream authentication, or model login. The foreground parent connection must
still be running. Host restart recreates endpoints from completed placement
records; deletion and shutdown remove their sockets and close active sessions.
Native profiles remain on the host after container deletion.

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

Limits are 256 KiB per message, 32 active sessions per parent connection, 64
outstanding requests in each direction per session, 16 queued writes, 512 KiB of
queued writes and 256 KiB of queued replies. Unanswered requests expire after
120 seconds independently of other traffic. Idle sessions expire after one hour.
A channel retains at most 1,024 session identities before requiring a fresh
connection. Errors omit upstream diagnostics and payloads.

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

Persistent app ownership and reconnect, automatic policy/grant creation during
placement, configuration refresh for existing profiles, HTTP/OAuth adapters, and
shared Mac/Mobile readiness UI remain pending.
The foreground command and native configuration artifacts do not claim full
settings or plugin parity. Git/session replication and Spot recovery remain
separate unfinished work.

## Validation

The SSH loopback test uses the SDK's client, a worker bridge, real SSH and a real
parent subprocess. It verifies unchanged tool discovery, parent execution and
rejection of a stale assignment generation. Unit tests cover scoped grants,
revocation, callbacks, transport failure and request budgets.

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

Focused proxy and SSH tests passed. The full local suite had one Chrome
navigation timing failure; that test passed in isolation alongside the proxy
checks. No Chrome product code changed in this work.
