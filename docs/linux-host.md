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

1. In Graftty's **Remote Hosts** menu, choose **Set Up Linux Host…**.
2. Enter the SSH destination and Linux project root.
3. Select a release version that includes Linux archives. For a local build,
   choose **Choose Development Archive…** and select the archive for the host's CPU.
4. Review **Install Codex if missing** and **Install Claude Code if missing**. Both are selected by default. Existing installations are preserved.
5. Select the local repositories to import and choose a branch for each.
6. Choose **Set Up and Connect**.

The setup flow verifies release archive checksums and checks that the host, CLI, and terminal binaries can execute before modifying an existing installation. Incompatible runtime libraries or architectures produce an error. It then installs a service for your Linux
account, and exchanges public identity keys through your existing SSH connection.
The host then appears among your saved remote connections.

Only committed branch and tag history is imported, including unpushed commits.
Working edits, untracked files, ignored files, stashes, and local Git configuration
are excluded. Set up repository credentials on Linux separately if you need to
fetch or push using the restored origin.

## Prepare development tools and agents

Install the project's compilers and dependencies on Linux. The Mac setup wizard
can install missing Codex and Claude executables using their official native
installers. Installing an archive manually with `install.sh` does not install
agent tools; install them separately or use **Update Host…** after connecting.
Authenticate Codex or Claude using that provider's Linux CLI. Mac credentials
and installed tools are not copied during setup.

The host prepares the selected provider's Graftty plugin when launching an agent.
To install the available provider plugins explicitly, run:

```sh
~/.local/bin/graftty-host setup --install-agent-plugins --json
```

Use ordinary Graftty worktree, pane, and team commands inside the remote terminal.
The host exports its socket and state paths to each pane.

## Update a connected Linux host

1. Install Python 3 and OpenSSL on Linux for maintenance identity checks.
2. In **Remote Hosts**, choose **Update Host…** beside the connected Linux host.
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
