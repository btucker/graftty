# Remote runners

A remote runner is Graftty's headless host on Linux. Install it from your Mac
over SSH, or run it as a container; see [Run the runner in Docker](#run-the-runner-in-docker).

Use Graftty on your Mac to install a headless Swift host on Linux,
import committed projects, and open persistent remote terminals.

## Prepare the host

1. Use a Linux host with an x86_64 or ARM64 CPU and systemd. Archives are built and tested on Ubuntu 24.04. Other distributions and releases are untested, but setup allows them when the required capabilities and binaries work.
2. Install Git, curl, Bash, GNU tar, GNU coreutils, and flock on the host.
3. Verify that your Linux account has a working systemd user session:

   ```sh
   systemctl --user show-environment
   ```

4. From Terminal on your Mac, connect with `ssh user@host` or your SSH config
   alias. Complete authentication and verify the server's SSH host key.
5. Verify that the same destination works without an interactive prompt:

   ```sh
   ssh -o BatchMode=yes -o StrictHostKeyChecking=yes user@host true
   ```

6. Make sure the host has outbound internet access. Graftty reaches the runner
   over Tailcat, an encrypted connection that needs no open inbound port. Setup
   binds the runner's own listeners to loopback, so nothing new is exposed. A
   release that predates Tailcat is instead installed listening on all
   interfaces, and your Mac needs a direct route to its port 8801.

Setup checks and enables lingering for your account so the user service keeps
running after SSH disconnects. It does not request interactive authorization.
If the host denies this change, setup stops before installing and asks the host
administrator to run `sudo loginctl enable-linger USER`, then retry.

## Install and connect

1. In Graftty's **Remote Hosts** menu, choose **Add Remote Runner…**.
2. Enter the SSH destination and Linux project root.
3. Select a release version that includes Linux archives. For a local build,
   choose **Choose Development Archive…** and select the archive for the host's CPU.
4. Review **Install Codex if missing** and **Install Claude Code if missing**. Both are selected by default. Existing installations are preserved.
5. Select the local repositories to import and choose a branch for each.
6. Choose **Set Up and Connect**.

The setup flow verifies release archive checksums and checks that the host, CLI, and terminal binaries can execute before modifying an existing installation. Incompatible runtime libraries or architectures produce an error. It then installs a service for your Linux
account, and exchanges public identity keys through your existing SSH connection.
The host then appears among your saved remote connections, reached over Tailcat.

Only committed branch and tag history is imported, including unpushed commits.
Working edits, untracked files, ignored files, stashes, and local Git configuration
are excluded. Set up repository credentials on Linux separately if you need to
fetch or push using the restored origin.

## Set up from the Mac CLI

Keep Graftty running on the Mac, then run:

```sh
graftty remote setup-linux user@host --version 1.2.3 --project ~/projects/app
```

Use a published version with a Linux archive. For a local build, replace
`--version 1.2.3` with `--archive /path/to/graftty-linux.tar.gz`.
Repeat `--project PATH` to import multiple repositories, or omit it to install
only the host. Each project checks out its current local branch; `--branch NAME`
selects the same branch in every chosen repository. `--project-root '~/projects'`
sets the Linux destination directory. Quote `"~/projects"` to preserve the Linux
home-relative path rather than expanding it in the Mac shell.

Progress is written to stderr. Add `--json` for a machine-readable final result.
The command installs the host and missing agent CLIs, imports committed history,
saves the pairing in the Mac app, and requests a connection. A successful return
acknowledges that request; check the app sidebar for connection status. Ctrl-C
cancels setup; completed installation and repository imports remain for retry.

The Linux archive includes the same `graftty` CLI for pane control, worktree
creation/removal, team messaging, hooks, and Attention reports, plus
`graftty-runner` for service administration. Mac GUI operations, enrollment from
Linux, and managing onward host connections are not supported by the headless
runtime.

## Add a runner with an invite

A runner that is already running, such as a container or a service you
installed by hand, prints a one-time invite on request:

```sh
graftty-runner invite
```

On the Mac, with Graftty running, pass that line to:

```sh
graftty remote add-runner 'graftty-invite-1:…'
```

The invite carries the runner's identity, its Tailcat address and a secret that
works once and expires after an hour. Treat it like a password: anyone who sees
it before you use it can add their own Mac. Restarting the runner cancels
unused invites. A runner added this way has no SSH destination saved, so the
Mac does not offer **Update Runner…** or project import for it; clone projects
on the runner and register them with `graftty-runner project add`.

## Prepare development tools and agents

Install the project's compilers and dependencies on Linux. The Mac setup wizard
can install missing Codex and Claude executables using their official native
installers. Installing an archive manually with `install.sh` does not install
agent tools; install them separately or use **Update Runner…** after connecting.
Authenticate Codex or Claude using that provider's Linux CLI. Mac credentials
and installed tools are not copied during setup.

The host prepares the selected provider's Graftty plugin when launching an agent.
To install the available provider plugins explicitly, run:

```sh
~/.local/bin/graftty-runner setup --install-agent-plugins --json
```

Use ordinary Graftty worktree, pane, and team commands inside the remote terminal.
The host exports its socket and state paths to each pane.


## Open a remote development server

Start the server in a Graftty terminal on the host. Its listening ports appear
beside that pane in the Mac sidebar. Click a port to open it in your Mac browser.
Graftty forwards through the existing authenticated connection and chooses an
unused local port, so different hosts can both run a server on port 3000.
The TCP forwarder carries HTTP and WebSocket traffic. Mac-to-Mac connections
reuse the same forwarding code over WebRTC.
The local listener closes when you disconnect from the host.

Bind the server to localhost or all interfaces. A server bound only to a specific
LAN address cannot use localhost forwarding. Ports on relayed worktrees require
a direct connection to the host that owns the worktree.

Linux setup grants the enrolled Mac permission to forward localhost ports.
For a host enrolled before this feature, update the Mac app and Linux host, then
run setup again.
Setup preserves an explicit disabled permission. On a Mac host, choose
**Settings → Device Pairing → Port forwarding → Allow localhost** for the client.
Changing this setting disconnects that client's current session; reconnect to
use the new permission.

## Update a connected runner

1. Install Python 3 and OpenSSL on Linux for maintenance identity checks.
2. In **Remote Hosts**, choose **Update Runner…** beside the connected Linux host.
3. Review its system SSH destination and choose **Check Host**. Older saved
   hosts need an SSH destination entered once. Use an SSH config alias for custom
   SSH ports; Graftty's terminal listener is a separate endpoint.
4. Review Graftty, Codex, and Claude Code. All start selected. Graftty becomes
   unavailable if no published release has both the architecture archive and
   checksum; you can still update agent tools.
5. If the current Graftty build is newer or cannot be compared with the release,
   explicitly select its replacement. Ordinary upgrades need no extra selection.
6. Choose **Update Selected** and review each component's result.

Graftty selects the newest published Linux release allowed by your prerelease
update setting. It verifies the saved host identity before changes and again
inside the installation lock. It also verifies that the installed user service
owns the paired host's state. Foreground hosts and services with an overridden
`ExecStart` require manual Graftty updates. Codex and Claude maintenance remains
available independently.

Maintenance preserves pairing, repositories, terminal sessions, service ports,
other service options, and autostart settings. It restarts the Graftty user
service and waits for reconnection. New terminal processes include
`~/.local/bin` in their tool search path.

Native Claude updates preserve its configured channel. Package-managed or
custom tools require **Replace custom Codex or Claude installations**; this
installs the native tool in `~/.local/bin` and may shadow another command.
Authenticate agents on Linux separately. Mac credentials are never copied.

Cancellation stops subsequent components. An interrupted SSH command can still
finish remotely, so an unknown result requires inspecting the host before
retrying. Successful components remain listed even if another component fails.

### Updating an install from before the rename

Earlier releases named the runner `graftty-host` and its service
`graftty-host.service`. **Update Runner…** converts that service to
`graftty-runner.service`, keeping its options, environment and autostart
setting, and removes the old unit so only one service runs. If the update
fails, the old service is restored as it was. `~/.local/bin/graftty-host`
keeps working as another name for `graftty-runner`.

## Inspect or restart the runner

Run these commands on Linux:

```sh
~/.local/bin/graftty-runner status --json
~/.local/bin/graftty-runner project add /absolute/path/to/repository --json
systemctl --user status graftty-runner.service
systemctl --user restart graftty-runner.service
journalctl --user -u graftty-runner.service -n 100
```

For a foreground host, run:

```sh
~/.local/bin/graftty-runner serve
```

Stop the installed service before starting a foreground instance with the same
state directory. The host rejects concurrent owners of its state.

## Retry an interrupted setup

Run **Add Remote Runner…** again with the same projects and branches. Completed
imports are accepted only while their recorded commit, branch, and clean working
tree still match. If you have changed the Linux checkout, choose another project
root or manage that checkout directly.

If installation succeeds but connection fails, check that the runner has
outbound internet access and CA certificates; `journalctl --user -u
graftty-runner.service` reports when it cannot listen on Tailcat. If the saved
host identity has changed, verify the cause before removing the old saved
connection and enrolling the replacement.

## Run the runner in Docker

Use `graftty-runner` to run the Linux headless host on Linux or Docker Desktop
with the WSL2 backend on Windows. The image includes `graftty-runner`, the
`graftty` CLI, the pinned Graftty-patched zmx, Bash, Git, curl, and an SSH client.
Install project toolchains and agent CLIs separately in a derived image.

Container replacement ends running terminals and agents. A persistent home
volume retains repositories, host identity, pairing, and configuration.

### Start the runner

After the first image release, run this command on the Docker host:

```sh
docker run --detach --name graftty-runner --hostname graftty-runner \
	--restart unless-stopped \
	--mount type=volume,source=graftty-runner-home,target=/home/runner \
	ghcr.io/btucker/graftty-runner:latest
```

No ports are published: the Mac reaches the runner over Tailcat, which needs
only outbound internet access from the container.

For repeatable deployments, replace `latest` with a published version tag or
image digest. Stable releases publish a version tag and `latest`. Prereleases
publish only their full version tag. Build metadata uses `_` in place of `+`,
so release `v1.2.3+build.4` has image tag `1.2.3_build.4`.
Both AMD64 and ARM64 are supported.

Check readiness:

```sh
docker inspect --format '{{.State.Health.Status}}' graftty-runner
docker exec graftty-runner graftty-runner status --json
```

Wait for `healthy`, `"running":true` and `"tailcat":true`.

### Add the runner to your Mac

Print an invite and redeem it on the Mac, as in
[Add a runner with an invite](#add-a-runner-with-an-invite):

```sh
docker exec graftty-runner graftty-runner invite
graftty remote add-runner 'graftty-invite-1:…'
```

On a platform that shows container logs but offers no `exec`, start the
container with `--env GRAFTTY_PRINT_INVITE=1`. The runner then prints one invite
to its log at first start, while no Mac is paired. Logs are often retained, so
use this only where you control who can read them.

A container paired earlier through published ports keeps working after an
image update if you keep publishing port 8801; Macs move to Tailcat the next
time they connect.

### Add repositories and agent tools

Clone and register a repository inside the persistent home volume:

```sh
docker exec -it graftty-runner bash
git clone https://github.com/YOUR_ORG/YOUR_REPO.git /home/runner/projects/app
graftty-runner project add /home/runner/projects/app --json
```

Authenticate Git and agent providers inside the runner. Host credentials are
not copied into the image. The home volume contains those local credentials
after sign-in, so retain it as private application data.

The runner uses UID and GID `10001`. For bind mounts, give that user access to
the mounted files. On WSL2, keep repositories in the Linux filesystem or use
the named home volume to avoid Windows filesystem overhead.

To include a project's compilers and agent executables, build a derived image:

```dockerfile
FROM ghcr.io/btucker/graftty-runner:latest
USER root
RUN apt-get update && apt-get install -y --no-install-recommends build-essential \
	&& rm -rf /var/lib/apt/lists/*
# Install agent executables here using their official Linux installers.
USER runner
```

Install executables under `/usr/local` or another image directory outside
`/home/runner`. An existing home volume hides files installed there by a newer
image. Keep provider authentication out of Docker build layers.

### Update the runner

Finish or save running work before replacing the container. Pull the selected
image tag, stop and remove the container, then repeat the startup command with
the same home volume. Do not remove the volume.

Use image replacement for updates. The Mac's **Update Runner…** flow manages a
systemd installation and cannot update this container.

The runner's Tailcat identity lives in the home volume, so replacing the
container keeps its address and every paired Mac reconnects without a new invite.
Container restart, Docker engine shutdown, WSL termination, and Windows reboot
end live processes. Docker's restart policy starts a new host process afterward.

### Build and validate an image locally

Build an archive on Linux with `scripts/linux/package.sh`, or download the
architecture-matched archive and checksum from a trusted Graftty release.
Verify the checksum before building:

```sh
cd /path/to/downloads
sha256sum -c graftty-linux-VERSION-aarch64.tar.gz.sha256
cd /path/to/graftty
scripts/linux/runner/build.sh /path/to/downloads/graftty-linux-VERSION-aarch64.tar.gz
scripts/linux/runner/smoke-test.sh graftty-runner:local
```

Use `x86_64` in the filename for AMD64. The build script selects the matching
Docker platform and creates a temporary build context containing only the
archive and Dockerfile. The smoke test checks non-root startup, both listeners,
terminal input and output, graceful shutdown, and persistence after replacement.

Release automation publishes `ghcr.io/btucker/graftty-runner` after the Mac
release and Linux archive checks pass. It uses the workflow's `GITHUB_TOKEN`
with `packages: write`; no Docker Hub credential is needed.

To publish an image for an existing release, run **Publish runner from an
existing release** in GitHub Actions on `main`. Enter the published release tag,
such as `v0.8.0`. This workflow downloads and verifies that release's Linux
archives, tests both images, and publishes their manifest without a Mac release.
Publishing a stable version also updates `latest`, so select the newest stable
release when publishing manually.

After the first publication,
[make the GitHub package public](https://docs.github.com/en/packages/learn-github-packages/configuring-a-packages-access-control-and-visibility)
to allow anonymous pulls.
