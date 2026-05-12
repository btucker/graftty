# Native Host-Managed zmx Panes — Design Specification

Replace Graftty's native-pane zmx bootstrap with libghostty's host-managed I/O backend. zmx remains the durable session and mux layer; Graftty owns the short-lived native `zmx attach` client process and wires its PTY directly into libghostty.

## Goal

Opening a native pane should not boot a user shell just to type `exec zmx attach ...` into it. The pane should create one libghostty surface and one `zmx attach` client, with Graftty bridging bytes between them.

The user-visible behavior stays the same:

- zmx-backed panes survive Graftty quit, crash, and relaunch.
- Closing a pane kills the zmx session.
- Quitting Graftty detaches only the native client; the zmx daemon and shell continue.
- `exit` in the shell closes the pane.
- shell integration, PWD tracking, default-command behavior, attention events, agent hooks, web access, and iOS access keep working.

## Background

The current native path starts a normal libghostty exec surface, lets Ghostty spawn the user's shell, then writes an `initial_input` line:

```sh
exec '<zmx>' attach '<session>' '<wrapped-user-shell>'
```

This avoids libghostty's embedded `command` field because upstream Ghostty forces `wait-after-command = true` whenever `command` is set. With `wait-after-command` enabled, shell exit shows a "press any key to close" terminal state instead of firing the pane close flow Graftty needs.

That workaround has a cost: every pane pays for an outer shell startup, then zmx attach startup, then the inner shell startup. It also leaks bootstrap details into shell integration and title filtering.

`libghostty-spm` already exposes a patched host-managed I/O backend:

- `GHOSTTY_SURFACE_IO_BACKEND_HOST_MANAGED`
- `ghostty_surface_write_buffer`
- `ghostty_surface_process_exit`
- receive callbacks for terminal input and resize

Graftty already has `PtyProcess`, which can spawn `zmx attach` under a real PTY for web sessions. Native panes can use the same POSIX shape.

## Architecture

When zmx is available, native panes always use host-managed libghostty I/O. There is no legacy zmx bootstrap path and no hidden feature flag.

```
Graftty process
┌───────────────────────────────────────────────────────────────────┐
│ SurfaceHandle                                                     │
│   ├─ libghostty surface (host-managed backend)                    │
│   └─ NativePtySession                                             │
│        ├─ PTY master fd                                           │
│        └─ child: zmx attach graftty-<pane-id> <wrapped-user-shell>│
└───────────────────────────────────────────────────────────────────┘
              │
              ▼
        zmx daemon process
              │
              ▼
       user shell / agent
```

Byte flow:

```
keyboard/mouse input
  -> libghostty input encoding
  -> host-managed receive_buffer callback
  -> NativePtySession.write
  -> PTY master
  -> zmx attach
  -> zmx daemon
  -> shell

shell output
  -> zmx daemon
  -> zmx attach
  -> PTY master reader
  -> ghostty_surface_write_buffer
  -> libghostty renderer
```

Resize flow:

```
SurfaceNSView.setFrameSize
  -> ghostty_surface_set_size
  -> host-managed receive_resize callback
  -> PtyProcess.resize(masterFD, cols, rows)
  -> zmx attach / daemon / shell
```

Process-exit flow:

```
zmx attach exits
  -> PTY reader sees EOF/EIO
  -> NativePtySession calls ghostty_surface_process_exit
  -> libghostty close_surface_cb fires
  -> TerminalManager existing close/recovery policy runs
```

## Components

### New: `NativePtySession`

Owns one native pane's short-lived `zmx attach` client.

Responsibilities:

- spawn a PTY child with `PtyProcess.spawn`
- retain the child pid and PTY master fd
- start a reader thread that forwards PTY output into `ghostty_surface_write_buffer`
- write terminal input bytes to the PTY master
- apply terminal resize through `PtyProcess.resize`
- report child exit once through `ghostty_surface_process_exit`
- close idempotently by clearing callbacks, SIGTERMing the attach child, closing the master fd, and bounded `waitpid`

`NativePtySession` must kill only the `zmx attach` client. It must not kill the zmx daemon. Explicit pane close and Stop worktree remain responsible for `zmx kill`.

### New: `HostManagedZmxBackend`

Small adapter around libghostty's C callbacks.

It owns or references `NativePtySession` and provides:

```swift
ghostty_surface_receive_buffer_cb
ghostty_surface_receive_resize_cb
```

The callbacks recover the backend from `receive_userdata`, then call:

```swift
session.write(data)
session.resize(cols: rows:)
```

Keeping this adapter separate prevents `SurfaceHandle` from accumulating callback plumbing and process-management logic.

### New: `ZmxSpawnConfiguration`

Structured replacement for the current `(initialInput, zmxDir)` return value.

```swift
struct ZmxSpawnConfiguration {
    let sessionName: String
    let argv: [String]
    let env: [String: String]
    let workingDirectory: URL
}
```

This component centralizes zmx session launch details:

- deterministic session name
- `zmx attach <session> <wrapped-user-shell>` argv
- `ZMX_DIR`
- `GRAFTTY_SOCK`
- sanitized `PATH`
- `GRAFTTY_AGENT_HOOKS_BIN`
- zsh shell-integration env
- bash wrapper shell
- `ZMX_SESSION` stripping
- working directory

The current string-producing `attachInitialInput` API becomes obsolete and should be removed with the hard cutover.

### Modified: `SurfaceHandle`

When handed a `ZmxSpawnConfiguration`, `SurfaceHandle`:

1. Creates a host-managed surface.
2. Sets `config.backend = GHOSTTY_SURFACE_IO_BACKEND_HOST_MANAGED`.
3. Sets `config.receive_userdata`, `config.receive_buffer`, and `config.receive_resize`.
4. Does not set `config.command`.
5. Does not set `config.initial_input`.
6. After `ghostty_surface_new` succeeds, starts `NativePtySession`.

When zmx is unavailable, `SurfaceHandle` preserves the existing direct-shell fallback by creating a normal exec surface with no zmx session.

### Modified: `TerminalManager`

`TerminalManager` stops resolving zmx bootstrap text. It resolves a `ZmxSpawnConfiguration?`:

- non-nil when `zmxLauncher.isAvailable`
- nil when zmx is unavailable, causing direct-shell fallback

Existing lifecycle responsibilities remain:

- cold-start session-loss relabeling
- shell-ready/default-command decisions
- pane close
- Stop worktree
- zmx kill for explicit pane/session teardown
- shell PID lookup for port scanning and "Move to current worktree"

## Shell Integration And Agent Hooks

The sharp edge is replacing a shell-prefix trick with structured env.

Current zsh bootstrap depends on the outer shell having `ZDOTDIR` set to the agent-hook init directory. The `initial_input` line then re-injects Ghostty's zsh integration for the inner shell:

```sh
if [ -n "$ZDOTDIR" ]; then export GHOSTTY_ZSH_ZDOTDIR="$ZDOTDIR"; fi
ZDOTDIR='<ghostty-resources>/shell-integration/zsh'
exec zmx attach ...
```

In host-managed mode there is no outer shell. `ZmxSpawnConfiguration` must pass the equivalent environment directly:

```text
ZDOTDIR=<ghostty-resources>/shell-integration/zsh
GHOSTTY_ZSH_ZDOTDIR=<agent-hook-zsh-init-dir>
GRAFTTY_AGENT_HOOKS_BIN=<agent-hook-bin-dir>
PATH=<agent-hook-bin-dir>:<sanitized-path>
```

For bash, keep using `AgentHookInstaller.wrappedUserShell(...)`, which returns a launcher that executes bash with a Graftty-managed rcfile. That wrapped shell path is passed as the final `zmx attach` command argument.

The design intentionally preserves zmx's current model: zmx spawns the inner shell process using the attach client's argv/env. Graftty does not inject commands after attach to configure the shell.

## Data Flow

### New pane

1. User opens a worktree or splits a pane.
2. `TerminalManager` allocates or receives the `TerminalID`.
3. `TerminalManager` calls `makeZmxSpawnConfiguration(for:worktreePath:)`.
4. `SurfaceHandle` creates a host-managed surface.
5. `NativePtySession` starts `zmx attach <session> <wrapped-user-shell>` in the worktree directory.
6. zmx attaches to an existing daemon or creates a new one.
7. Output replay and live output flow through the PTY reader into libghostty.

### Relaunch

1. App state restores panes with stable `TerminalID`s.
2. Session names derive from the same IDs as before.
3. Native panes create new `zmx attach` clients.
4. Existing zmx daemons replay scrollback; missing daemons create fresh sessions.
5. Existing cold-start session-loss logic clears the rehydrated label when the daemon is absent, so default commands run only for fresh sessions.

### App quit

1. `SurfaceHandle` instances deinit.
2. Each `NativePtySession.close()` terminates its `zmx attach` client and closes the PTY fd.
3. zmx daemons and shells continue.

No `zmx kill` runs as part of app quit.

### User closes a pane

1. Existing pane-close flow removes the pane from the split tree.
2. `SurfaceHandle` closes its native attach client.
3. `TerminalManager.killZmxSession(for:)` kills the daemon and shell.

### Shell exits

1. Shell exit causes the zmx daemon/client path to terminate.
2. The native attach client exits.
3. PTY reader reports process exit to libghostty.
4. `close_surface_cb` fires.
5. Existing `TerminalManager` close policy removes or recovers the pane.

## Error Handling

- If the bundled zmx binary is missing or not executable, Graftty falls back to the direct-shell exec surface, matching the existing `ZMX-5.1` product behavior.
- If host-managed surface creation fails, `SurfaceHandle.init?` returns nil as it does today.
- If `NativePtySession.start` fails after surface creation, write a short diagnostic to the surface if possible, report process exit with nonzero status, and let the close callback converge.
- If PTY reads return EOF/EIO, report process exit exactly once.
- If PTY write fails because the fd is closed, ignore it; the exit path should arrive or already have arrived.
- If resize fails because the fd is closed, ignore it.
- `NativePtySession.close()` must be idempotent and nonblocking on UI-sensitive paths.
- Explicit `zmx kill` remains best-effort and idempotent; failed kills do not block pane removal.

## Testing

### Unit tests

- `ZmxSpawnConfiguration` builds expected argv/env for zsh.
- `ZmxSpawnConfiguration` builds expected argv/env for bash.
- disabled agent hooks use the raw user shell.
- missing Ghostty resources omit zsh integration env without crashing.
- env strips `ZMX_SESSION`.
- env includes `ZMX_DIR`, `GRAFTTY_SOCK`, sanitized `PATH`, and agent hook variables.
- native zmx surface configuration sets host-managed backend and never sets `command` or `initial_input`.

### PTY integration tests

- `NativePtySession` can spawn a simple PTY command and forward output to a fake surface sink.
- input writes reach the child process.
- resize changes are visible via `stty size`.
- close terminates only the client process.
- EOF triggers exactly one exit callback.

Where a real `ghostty_surface_t` is awkward, isolate the native session behind injectable closures:

```swift
writeToSurface(Data)
processExited(exitCode, runtime)
```

The production adapter uses `ghostty_surface_write_buffer` and `ghostty_surface_process_exit`; tests use closure probes.

### zmx integration tests

All zmx integration tests must use scoped `ZMX_DIR` under `/tmp/zmx-*`. Test helpers should refuse to run if the zmx dir is absent or outside that prefix.

- host-managed attach creates a zmx session.
- clean native-client close leaves the zmx daemon listed.
- reattach restores a marker from scrollback.
- explicit kill removes the daemon.
- inherited `ZMX_SESSION` cannot hijack the target session.

### Manual smoke tests

1. Open a new pane; prompt appears without the old bootstrap command echo.
2. Type `exit`; pane closes.
3. Run `echo hello`, quit Graftty, relaunch; `hello` is still visible.
4. Fresh pane default command runs.
5. Rehydrated live zmx session does not re-run the default command.
6. Delete `~/Library/Application Support/Graftty/zmx`, relaunch; default command runs in restored panes.
7. PWD tracking updates sidebar labels after `cd`.
8. Codex/Claude wrappers still win `PATH` lookup.
9. Web and iOS clients can attach to the same native-created session.
10. Stop worktree kills the relevant zmx sessions.

## SPECS.md Updates

Update `§13 zmx Session Backing` to replace the native bootstrap requirement with host-managed I/O requirements:

**ZMX-4.1 revised** When the application creates a native terminal pane and zmx is available, it shall create a libghostty surface using `GHOSTTY_SURFACE_IO_BACKEND_HOST_MANAGED` and shall spawn `zmx attach <session> <wrapped-user-shell>` itself through a real PTY. The application shall not set libghostty's `command` or `initial_input` fields for zmx-backed native panes.

**ZMX-4.1a** The application shall forward libghostty host-managed input bytes to the pane's PTY master and shall forward bytes read from the PTY master into libghostty with `ghostty_surface_write_buffer`.

**ZMX-4.1b** The application shall forward libghostty host-managed resize callbacks to the pane PTY with `TIOCSWINSZ`, including an initial size when available.

**ZMX-4.1c** When the native `zmx attach` client exits, the application shall call `ghostty_surface_process_exit` exactly once so libghostty fires the existing close-surface flow.

**ZMX-6.3 revised** For zsh panes, the application shall express Ghostty shell integration and Graftty agent-hook composition through environment variables passed to `zmx attach`: `ZDOTDIR=<ghostty-resources>/shell-integration/zsh`, `GHOSTTY_ZSH_ZDOTDIR=<agent-hook-zsh-init-dir>`, `GRAFTTY_AGENT_HOOKS_BIN=<agent-hook-bin-dir>`, and a sanitized `PATH` with the agent-hook bin prepended.

## Non-Goals

- Do not replace zmx as the durable session layer.
- Do not speak zmx's private daemon socket protocol.
- Do not change web or iOS session protocols.
- Do not redesign pane close policy.
- Do not preserve the old native `initial_input` zmx bootstrap path.

## Open Risks

- The zsh env composition needs targeted testing. It is the most likely place to break PWD reporting or agent wrappers.
- `NativePtySession` must be careful about fd reuse races between reader, writer, resize, and close.
- Reporting process exit through libghostty from a background thread must match the host-managed backend's thread-safety expectations.
- Startup may expose ordering bugs if zmx replays scrollback before SwiftUI has mounted the surface view. The design avoids this by creating the surface before starting the PTY process, but tests should still cover early output.
