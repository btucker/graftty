# Remote runner setup over Tailcat

Date: 23 November 2026. Status: awaiting approval of this document.

## Why

Adding a Linux machine to Graftty is harder than it should be.

- The setup sheet (`Sources/Graftty/Views/LinuxHostSetupSheet.swift`) asks for
  an SSH destination, project root, release version, development archive, two
  agent toggles, and a per-repository import list, with three paragraphs of
  explanation.
- After setup the Mac connects directly to TCP 8801, so that port must be
  reachable. The installer binds SSH 8801 and HTTP 8800 on `0.0.0.0`, which
  exposes both on a public machine such as an exe.dev box.
- A machine the Mac has never connected to fails setup. OpenSSH runs with
  `StrictHostKeyChecking=yes` and the error sends the user to Terminal.
- The Docker image is a separate product path: start it by hand with published
  ports, pair through **Add Remote Mac…** with a URL and a verification code
  read from `docker exec`, and **Update Host…** cannot touch it.
- Names disagree. The binary is `graftty-host`, the image is `graftty-runner`,
  and the UI says "Linux host".

## Goals

1. One sheet, **Add a Remote Runner**, with one text field.
2. The field accepts an SSH destination (with or without a leading `ssh `) or
   an invite printed by an already-running runner.
3. A machine the Mac has not seen before is confirmed inside the sheet.
4. Every runner added through the sheet or by invite is reached over Tailcat,
   and a new install has no port reachable from the network.
5. One name: `graftty-runner` for the binary, the systemd unit, the image, and
   "runner" in the UI.
6. A Docker runner is added through the same sheet as any other runner.

## Non-goals

- Importing projects during setup. It moves to after the runner is connected.
- Having Graftty start a container on a Docker host over SSH.
- Changing how Macs pair with each other, or the Mac's **Use Tailcat (beta)**
  setting for Mac-to-Mac and phone connections.
- Pairing a phone directly with a runner.
- Windows/WSL and AWS enrollment behavior, beyond following the rename. Both
  keep their current transport, and the runner's direct listener flags keep
  working for them.
- Retiring WebRTC.

## Anti-goals

- A sheet that grows options back. Anything beyond the one field needs a
  reason a first-time user would hit.
- A host-key check that can be clicked past without the fingerprint on screen.
- A Tailcat address or invite appearing in logs, error text, or the saved host
  list. Both contain secrets.

## Constraints

- Tailcat is built today only as an Apple xcframework
  (`scripts/build-tailcat-framework`, `Package.swift` `tailcatTargets`).
- `GrafttyTailcat/TailcatCredentials.swift` uses Keychain, which Linux lacks.
- `RemoteHostDialer.negotiate` only tries Tailcat when the link is a WebRTC
  `RemoteHostConnection` and the beta preference is on. Linux runners use the
  direct-SSH transport, which has no Tailcat path.
- Existing installs run `graftty-host.service` and existing saved runners
  connect to a direct endpoint.
- Requirements follow the repository's `@spec` and RED/GREEN process in
  `CLAUDE.md`; `SPECS.md` is regenerated, never edited.

## Approaches

### Setup UI

Three were mocked. All ask only for the destination.

- **A, stepped sheet.** Paste, confirm, progress, done, one screen each. Clear
  but modal for the whole setup and four screens for paste-and-wait.
- **B, inline in the sidebar.** The runner appears as a row immediately and
  sets itself up. Nothing modal, but a half-set-up runner must live in the
  saved list and the confirmation is easy to miss.
- **C, one live sheet. Chosen.** One compact sheet; the fingerprint and
  progress appear under the field. Shortest path for the common case, and the
  primary button becomes **Trust and Add Runner** for an unknown machine.

### Tailcat on Linux

- **Native in the runner binary. Chosen.** Build Tailcat's C archive for
  Linux and link it into the Swift binary, as `TailcatMacHost` does on the Mac.
  One process and one code path for Mac and Linux.
- **Go sidecar.** A second static binary forwards Tailcat streams to the
  runner on loopback. Avoids the link risk but adds a binary and a service.
- **Phone-home, as in the Cloudflare prototype.** The runner dials the Mac.
  Rejected: it reverses the SSH roles the product uses.

The link risk was checked by a throwaway spike on 23 November 2026 in
`swift:6.4.2-noble`. A Swift executable linked against the pinned Tailcat
archive ran a server and a client in one process and echoed 1 KiB. It passed
on arm64, on arm64 with `--static-swift-stdlib` as a non-root user without
`/dev/net/tun`, and on x86_64 under emulation. Only a direct route was
observed. The archive is about 50 MB and the spike binary 34 MB. The real
runner binary has not been linked yet.

### Adding a container

- **Paste an invite. Chosen.** The runner prints a one-time invite; the same
  field accepts it. Works where there is no inbound access at all.
- **Graftty starts the container over SSH.** Rejected for now: it needs SSH
  to the Docker host and does not cover hosted container platforms.

## Design

### Names

| Today | After |
| --- | --- |
| `graftty-host` binary and launcher | `graftty-runner` |
| `graftty-host.service` | `graftty-runner.service` |
| `GrafttyHost` executable target | `GrafttyRunner` |
| **Set Up Linux Host…** | **Add Remote Runner…** |
| **Update Host…** | **Update Runner…** |
| `docs/linux-host.md`, `docs/docker-runner.md` | one `docs/remote-runner.md` |

`GrafttyHostAgent` keeps its name; the Mac host uses it too. **Add Remote
Mac…** and the **Remote Hosts** menu title stay. An update of an existing
install stops, disables and removes `graftty-host.service` before enabling
`graftty-runner.service`, so a machine never runs both. State directories and
the runner's identity keep their paths so pairings survive the update.

### The sheet

One field with the prompt `ssh user@host or runner invite`. The sheet stays
one view and shows, under the field, whichever of these applies:

1. **Unknown machine.** The key type and SHA-256 fingerprint, a line asking
   the user to compare it with their provider, and the primary button
   **Trust and Add Runner**.
2. **Progress.** A checklist: host confirmed, runner installed, each agent
   tool, connected. **Cancel Setup** and **Hide**. Hide dismisses the sheet
   and setup continues; the runner's row under Remote Hosts shows progress
   and any failure.
3. **Failure.** The message, selectable, and **Retry**.
4. **Done.** The sheet closes when everything succeeded. If an agent tool
   failed to install it stays open with the outcome, as today.

Defaults replace the removed fields: project root `~/projects`, release
version equal to the app's version, Codex and Claude Code installed when
missing. A development archive is chosen through a control shown only when
the Option key is held. `graftty remote setup-linux` keeps its flags and
gains the alias `graftty remote add-runner`.

### What the field accepts

- `host`, `user@host`, or an `~/.ssh/config` alias, as today.
- The same with a leading `ssh `.
- `-p <port>` before or after the destination.
- A runner invite (below).

Any other SSH option is refused with a message pointing to `~/.ssh/config`.

### Confirming an unknown machine

Before running anything on the machine, setup resolves the destination with
`ssh -G` and checks `known_hosts` for the resolved host and port. If there is
no entry it fetches the key with `ssh-keyscan`, shows the fingerprint, and on
**Trust and Add Runner** appends the key to the user's `known_hosts`. Setup
then proceeds with `StrictHostKeyChecking=yes` unchanged. A key that conflicts
with an existing entry is never offered for trust; the existing error stays.
Destinations reached through `ProxyJump` or `ProxyCommand` cannot be scanned
directly, so they keep today's instruction to connect once in Terminal.

### Tailcat in the runner

- A Linux build of the Tailcat archive joins the Linux packaging pipeline
  (`scripts/linux/package.sh`, `.github/workflows/linux.yml`) for both
  architectures, pinned by the same `UPSTREAM_COMMIT` as the Apple build.
- `GrafttyTailcat` compiles on Linux. Known source changes: import Glibc,
  `SOCK_STREAM.rawValue`, and SIGPIPE handling in place of `SO_NOSIGPIPE`.
- Credentials on Linux live in a `0600` file under the runner's state
  directory. Keychain stays on Apple platforms.
- `graftty-runner serve` starts a Tailcat listener and passes accepted streams
  to `DirectSSHHostServer.accept(input:output:)`, as `TailcatMacHost` does. Its
  identity and address persist across restarts.
- New systemd installs bind the SSH and HTTP listeners to loopback, so
  Tailcat is the only network path.
- The container keeps listening on all interfaces inside its own network
  namespace, and the documented `docker run` drops `--publish`. Nothing is
  reachable unless the operator publishes a port, and a container already
  paired through published ports keeps working after an image update.
- The runner always listens on Tailcat. The Mac's beta preference does not
  gate runner connections.

### Connecting from the Mac

Saved runners gain a Tailcat transport next to direct SSH. The Mac stores the
runner's Tailcat endpoint in Keychain against the runner's key fingerprint,
dials it, and runs the existing pinned SSH client over the stream. A dial
failure reports the runner as unreachable; there is no fallback to another
transport for a Tailcat runner.

### Two ways in

**SSH install.** As today through the install step. `trust-client` enrolls the
Mac's key and now also returns the runner's Tailcat endpoint over the
authenticated OpenSSH session. The Mac pins the runner's key, saves the
endpoint, and connects over Tailcat.

**Invite.** `graftty-runner invite` prints one line, on demand. For a
container that is `docker exec graftty-runner graftty-runner invite`. Nothing
is printed at start by default, because the invite contains the runner's
permanent Tailcat address and container logs are retained. Setting
`GRAFTTY_PRINT_INVITE=1` prints one invite at first start when nobody is
paired, for platforms that expose logs but no exec. The invite carries the runner's Tailcat endpoint, its public-key
fingerprint, and a one-time enrollment secret that expires. The Mac dials the
endpoint, requires the SSH host key to match the fingerprint, and presents the
secret with its own public key. The runner enrolls that key and discards the
secret. The verification-code exchange and URL entry are not used for
runners. An invite works for any runner, including a systemd install done by
hand.

### Updating and existing runners

**Update Runner…** keeps working over OpenSSH for systemd installs and
performs the service rename. An update keeps the install's existing bind
address, so every Mac that saved the direct endpoint keeps connecting. The
updated runner also listens on Tailcat. Each Mac asks for the endpoint with
the existing `.tailcatEndpoint` request on its next direct connection, saves
it, and uses Tailcat from then on. Closing the direct port on an existing
install is a later, explicit step and not part of this work. Containers are
still updated by replacing the image. Adding an already-saved runner again by
invite replaces the saved entry when the key fingerprint matches.

### Project import

Removed from setup. **Add a Project…** on a connected runner offers the same
committed-history import the sheet does today, reusing
`LinuxHostSetup.validateProjects` and the import scripts.

Import and **Update Runner…** run over the saved OpenSSH destination, so they
are offered only for runners installed over SSH. A runner added by invite has
no destination: its projects are cloned on the runner and registered with
`graftty-runner project add`, and a container is updated by replacing its
image. The UI does not offer either action for such a runner. Carrying import
over Graftty's own channel is a possible follow-up outside this work.

## Delivery

Three pull requests, in order:

1. The rename, including the service migration and merged docs.
2. Tailcat in the runner, the Mac's Tailcat transport for runners, and
   invites.
3. The new sheet, in-app host confirmation, and project import moved out.

Each pull request leaves `main` releasable. The second one therefore includes
`graftty remote add-runner <invite>` so an invite can be redeemed before the
new sheet exists, and corrects the old sheet's text about port 8801.

The second pull request starts by linking the real runner binary with Tailcat
on both architectures and passing a forced-relay connection test, because the
spike covered neither. If either fails, work stops and the choice between a
Go sidecar and a direct fallback returns to the project owner.

## Left to the builder

- The invite's encoding and lifetime, and the SSH mechanism that carries the
  enrollment secret.
- How SIGPIPE is handled on Linux.
- Where the Linux Tailcat archive is cached in CI.
- Spec IDs and which existing `@spec` entries change or are removed.
- The row presentation for a hidden, in-progress setup, following the
  project's preference for subtle status cues (italic or dim, not color).

## Confirmed by the project owner on 23 November 2026

- Import and update are offered only for SSH-installed runners.
- Invites are printed on demand, with an opt-in variable for first start.

## Calls made by the author, not yet confirmed

- No direct-port fallback for newly added runners.
- Runner connections ignore the Tailcat beta preference.
- `-p <port>` is the only SSH option the field accepts.
- The development-archive control is hidden behind the Option key.
- Existing direct-endpoint runners migrate to Tailcat on their next update,
  not automatically.
- `ProxyJump` destinations keep the Terminal instruction for unknown hosts.
- An update leaves an existing install's direct port open; Macs move to
  Tailcat as they reconnect.
- The container keeps its in-namespace listeners; only the published ports
  go away from the documentation.
- WSL and AWS runners keep their current transport.
- Each pull request is releasable, with a CLI path for invites in the second.
- A failed real-binary link or relay test stops the work for a decision.
