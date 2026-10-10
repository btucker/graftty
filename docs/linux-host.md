# Set up a Linux host from your Mac

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

6. Allow your Mac to reach the Linux host's TCP port 8801 over your LAN or VPN.
   An SSH config alias with `ProxyJump` can provision the host, but Graftty's
   terminal connection still needs a direct network route to port 8801.

Setup checks and enables lingering for your account so the user service keeps
running after SSH disconnects. It does not request interactive authorization.
If the host denies this change, setup stops before installing and asks the host
administrator to run `sudo loginctl enable-linger USER`, then retry.

## Install and connect

1. In Graftty's remote connections menu, choose **Set Up Linux Host…**.
2. Enter the SSH destination and Linux project root.
3. Select a release version that includes Linux archives. For a local build,
   choose **Choose Development Archive…** and select the archive for the host's CPU.
4. Select the local repositories to import and choose a branch for each.
5. Choose **Set Up and Connect**.

The setup flow verifies release archive checksums and checks that the host, CLI, and terminal binaries can execute before modifying an existing installation. Incompatible runtime libraries or architectures produce an error. It then installs a service for your Linux
account, and exchanges public identity keys through your existing SSH connection.
The host then appears among your saved remote connections.

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
`graftty-host` for service administration. Mac GUI operations, enrollment from
Linux, and managing onward host connections are not supported by the headless
runtime.

## Prepare development tools and agents

Auto-setup checks the Linux user's login shell PATH for `claude` and `codex`.
It preserves working installations and installs missing commands with the
[Claude Code installer](https://claude.ai/install.sh) and
[Codex installer](https://chatgpt.com/codex/install.sh), under `~/.local/bin`.
The installers need outbound HTTPS access. A failed download or installation
reports the provider and can be retried without reinstalling working commands.

Install the project's compilers and dependencies separately. Authenticate
Codex and Claude using their Linux CLIs after setup; Mac credentials are not
copied.

The host prepares the selected provider's Graftty plugin when launching an agent.
To install the available provider plugins explicitly, run:

```sh
~/.local/bin/graftty-host setup --install-agent-plugins --json
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

## Inspect or restart the host

Run these commands on Linux:

```sh
~/.local/bin/graftty-host status --json
~/.local/bin/graftty-host project add /absolute/path/to/repository --json
systemctl --user status graftty-host.service
systemctl --user restart graftty-host.service
journalctl --user -u graftty-host.service -n 100
```

For a foreground host, run:

```sh
~/.local/bin/graftty-host serve --bind-address 0.0.0.0 --ssh-port 8801
```

Stop the installed service before starting a foreground instance with the same
state directory. The host rejects concurrent owners of its state.

## Retry an interrupted setup

Run **Set Up Linux Host…** again with the same projects and branches. Completed
imports are accepted only while their recorded commit, branch, and clean working
tree still match. If you have changed the Linux checkout, choose another project
root or manage that checkout directly.

If installation succeeds but connection fails, check port 8801 and the direct
network route. If the saved host identity has changed, verify the cause before
removing the old saved connection and enrolling the replacement.
