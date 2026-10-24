---
name: project-setup
description: Prepare or repair a project's Dev Container configuration for Graftty remote worktrees, and verify its build, test, resource, and authentication requirements. Use for project environment setup, not for provisioning cloud machines.
---

# Project setup

Produce version-controlled configuration that lets a new worktree prepare its development environment on demand. Use the existing Dev Container CLI and the project's own setup commands. Keep user-specific AWS profiles, instance pools, and preferred instance types out of the repository.

Inspect the repository's instructions, CI, dependency locks, existing `.devcontainer` configuration, and build scripts. Preserve a working setup. Identify which tasks require macOS and which can run on Linux. Do not represent a Linux container as capable of running Xcode or Apple-only tests.

Use the [Dev Container specification](https://containers.dev/implementors/json_reference/) for configuration and the [Dev Container CLI](https://github.com/devcontainers/cli) for execution. Check the installed CLI's version and command help before relying on flags. Graftty's placement command creates a host worktree by default. `graftty remote placement create --dev-container` explicitly prepares an image or Dockerfile environment and opens its shell; `--dev-container-config` selects a configuration inside the new worktree. Explicit `--skill-revision` selections install staged skills, and `--agent codex` or `--agent claude` launches an installed native runtime with a matching revision. Managed placements retain their private agent profiles on the host when containers are removed. Compose placement, automatic profile refresh, session replication, and automatic recovery remain pending.

Skill installation requires POSIX shell utilities, `base64`, and `diff` in the container. Publishing missing project skill directories also requires GNU `mv` or `gmv` with verified `-T --no-clobber` behavior. Install GNU coreutils in images that need project skill publication. User-only skills and identical existing project skills do not require that mover. Configure the container remote user to match the Linux host user's UID for the private profile mount. Profile retention does not establish a parent backup or authenticate the agent to its model service.

## Configure the project

Create or repair `.devcontainer/devcontainer.json` or the repository's existing supported configuration. Use a Dockerfile, Compose services, or Features only where the project needs them. Follow the project's established dependency versions and lockfiles. Make setup repeatable when a second worktree arrives on an already-used host.

Record required CPU, memory, and storage with standard `hostRequirements` properties where applicable. Document supported CPU architectures and measured resource requirements alongside the configuration. Separate requirements from unmeasured estimates. A suggested instance type is a user preference, not a project requirement.

Give each worktree its own mutable environment. Check for fixed Compose project names, container names, host ports, database directories, and writable volumes that could cause different worktrees or projects to share state accidentally. Share image layers and suitable dependency caches without sharing mutable project data.

Lifecycle commands execute project code, sometimes on the host. Inspect the configuration, Features, Dockerfile, Compose files, and setup scripts before executing them. Preserve the user's authorized scope. Document any required privileged access or host service dependency rather than adding it incidentally.

Do not copy or mount SSH private keys, AWS credential files, Git credential stores, agent authentication stores, or a user's entire home into the environment. Do not enable automatic credential forwarding. Document independent login requirements for private registries, packages, Git remotes, Claude, and Codex. Existing credentials may be used where independently configured; do not print their contents in verification output.

Document required MCP server IDs and whether each tool must operate on the Linux checkout or on the parent Mac. Explicit parent-proxied stdio MCP access is available through `graftty remote mcp connect` on the parent and placement `--mcp-grants <file>` with selected skill revisions. Follow the remote-host skill for that setup and its scoped bridge requirements. Upstream authentication stays on the parent; project configuration must not contain tokens or private credential references. Automatic grant creation, HTTP servers, and app connector authentication adapters remain pending. MCP access and the agent runtime's model-service login are separate prerequisites.

## Verify worktree behavior

Check Git metadata access inside the container. A linked worktree's `.git` file points outside its checkout; merely mounting the checkout can leave `git status` broken. Inspect `git rev-parse --git-common-dir` and the existing worktree layout before choosing mounts.

The upstream CLI supports `--mount-git-worktree-common-dir` for relative Git worktrees. Check the installed command help and verify that the worktree uses the compatible relative layout before using it. Both host and container Git must support the relative-worktree repository extension. Do not silently rewrite existing Git worktree metadata or mount a whole parent home directory as a shortcut. If an existing absolute layout needs another mounting arrangement, document the exact Git metadata directory and verify access without bringing unrelated files into the container.

Use an existing worktree for verification. If a second worktree is needed, follow Graftty's worktree coordination workflow through the graftty-team skill. Do not create an agent workspace with `git worktree add` directly.

Run the CLI against the actual workspace and selected configuration. For a default configuration in an ordinary checkout, the basic sequence is:

```sh
devcontainer read-configuration --workspace-folder "$project_workspace"
devcontainer up --workspace-folder "$project_workspace"
devcontainer exec --workspace-folder "$project_workspace" git status --short
```

Set `project_workspace` to the absolute checkout path. Add supported configuration and Git worktree options consistently to the commands that need them. Wait for successful process exit and completion of required lifecycle commands. A running container or an early success JSON record does not prove that setup or project verification finished.

Run the repository's documented build, test, and development-start commands with `devcontainer exec`. Verify the expected listening port and writable paths. Check two worktrees for port, volume, and Compose-name collisions when that verification is available and authorized. Test each architecture you claim to support; report untested architectures explicitly.

If Docker, the CLI, an architecture, credentials, or another prerequisite is unavailable, finish the reviewable configuration and list the exact verification still needed. Do not call the environment ready based only on a valid JSON document or a successful image build.

## Leave useful project guidance

Update the existing developer documentation or add a short `.devcontainer/README.md` with the supported platform and architecture, setup and verification commands, resource estimates, worktree isolation choices, and independent authentication prerequisites. Include what was actually tested and any remaining incompatibility.

Commit the project configuration and documentation through the repository's normal workflow. This skill does not launch AWS instances, choose a user's account settings, publish images, move credentials, or claim that parent replication and Spot recovery have been configured.
