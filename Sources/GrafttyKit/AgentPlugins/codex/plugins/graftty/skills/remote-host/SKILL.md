---
name: remote-host
description: Work in a Graftty-managed remote worktree using its recorded parent, prepared environment, Git publication route, and MCP access. Use for remote agent work and handoff, not for generic SSH administration.
---

# Remote host

Preserve ordinary Git history and native agent sessions while working on a host that may disappear. The parent is the Mac that delegated this worktree. A shared instance can hold worktrees for different parents, so identify the parent for this assignment rather than assuming one parent owns the machine.

## Establish the work context

Use Graftty-provided placement and delegation state to identify the current host, repository, worktree, parent, and prepared environment. Check the installed `graftty --help` and relevant command help before relying on a command or flag. A hostname, branch name, Git author, instance tag, or repository file does not authenticate the parent or authorize a transfer. Missing delegation information is a setup gap to report.

Work inside the prepared Dev Container when this assignment uses one. Keep dependency changes in its version-controlled setup. For additional capacity, use the available host observations and placement planner with the user's saved provider preferences and limits. A running cloud instance is not proof of a ready environment or spare capacity.

The current implementation provides provider inspection, placement, environment preparation, an interruption drain barrier, and an explicitly configured parent MCP connection for stdio servers. Managed container placement can install explicitly selected MCP grants. Parent Git transfer/publication, automatic session replication and recovery, and automatic MCP grant creation remain pending. The following workflow describes their intended use when available. Do not invent commands, configure an ad hoc transfer route, or claim that those features already protect this worktree.

## Preserve work and publish through the available route

Follow the task's existing commit policy. Use ordinary commits, including WIP commits when authorized; a PR or MR is not required. Preserve unrelated edits and staging. Native agent transcripts remain separate from Git commits. A successful local commit alone does not establish a parent backup.

If origin publication is authorized and this host already has independently configured credentials, it may push directly. Do not copy keys, authentication stores, or a user's home from the parent, and do not enable credential forwarding to make a push work. Avoid displaying credential-bearing remote URLs.

If direct publication is unavailable, use the parent transfer route provisioned by Graftty for the current delegation. Wait for the parent's receipt of the exact commit, then request publication of that commit to the allowed destination through Graftty. Parent receipt and origin publication are separate results. If the installed release lacks this route, report that the work remains local instead of silently treating a commit as a backup.

Resolve a non-fast-forward rejection through the repository's normal history workflow. It is not an authentication failure to bypass through the parent. Reconcile a lost publication reply using the same operation identity before requesting another mutation. Do not force-push as a retry strategy. These instructions do not grant origin publication permission or enforce peer, repository, or ref authorization; Graftty must enforce those checks.

## Use MCP through the recorded parent

When supported and configured, use the worktree's scoped MCP bridge and granted server IDs. Upstream credentials, refresh, and renewed consent stay on the Mac. A local MCP server running on that Mac still acts on Mac files and processes. Tools that need the Linux checkout require an appropriate Linux-local server; do not assume paths refer to the same machine.

Keep `graftty remote mcp connect` running on the parent. Managed placement with `--dev-container`, selected `--skill-revision` values and `--mcp-grants <file>` installs native Codex and Claude entries into the new private profile. It mounts a dedicated scoped socket and the bridge runtime read-only. `mcpConfigured` confirms installation, not current tool availability or model login. Use granted tools under their original server names; there is no forwarding tool to call.

The separate `graftty remote mcp stage` command only generates files; those files still need installation. HTTP servers, app connector authentication adapters, existing-profile refresh, and automatic settings/plugin parity are not yet available. Do not mount the host's general control socket into a project container as a substitute for a scoped bridge.

If the parent disconnects, report proxied tools unavailable. A lost reply may follow a successful upstream mutation, so do not automatically repeat the call. Missing support for an app connector or authentication source requires setup on the parent, not extraction of private credential files. MCP access does not authenticate the agent runtime to its own model service.

## Respond to interruption and handoff

When the host reports draining, stop starting builds and new work and cooperate with bounded writer shutdown. The host service owns urgent commits and transfers independently of an agent turn; do not make it wait for tests or PR creation. Do not remove Git locks or resolve conflicts destructively to rush a save.

Report Git and session receipts independently. Only acknowledged copies are confirmed on the parent; list any unconfirmed work. An absent parent or missed warning can leave work unsaved. Resume on a replacement host only after Graftty has prepared the environment, restored compatible native session data, and issued a current assignment and MCP grants. Copying a transcript does not transfer authority or prove a successful resume.
