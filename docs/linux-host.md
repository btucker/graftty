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

To keep the user service running after logout, ask the host administrator to
enable lingering for your account with `loginctl enable-linger USER`.

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

## Prepare development tools and agents

Install the project's compilers, dependencies, and agent executables on Linux.
Authenticate Codex or Claude using that provider's Linux CLI. Mac credentials
and installed tools are not copied during setup.

The host prepares the selected provider's Graftty plugin when launching an agent.
To install the available provider plugins explicitly, run:

```sh
~/.local/bin/graftty-host setup --install-agent-plugins --json
```

Use ordinary Graftty worktree, pane, and team commands inside the remote terminal.
The host exports its socket and state paths to each pane.

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
