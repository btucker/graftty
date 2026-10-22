---
name: graftty-team
description: Delegate Graftty work when asked, route necessary peer messages, and manage established agent roles and GRAFTTY.md instructions.
---

# Graftty team

Run commands from your tracked worktree. Use `graftty team` across providers and worktrees; provider-native messaging uses a different roster. Consult subcommand `--help` for version mismatches. Wrappers and hooks own registration.

## Decide whether coordination is needed

Do your assigned work directly. Delegate only when the user asks for delegation, another agent, or parallel agent work. A request to fix a bug or open a PR does not by itself request delegation.

Reuse an agent for a continuation of its active assignment or work covered by its established role. For unrelated new work, launch a fresh agent when delegation is requested. A merged PR ends that task assignment. Do not give its agent a new task merely because it is still reachable or knows the code. An established ongoing role or an explicit user request to reuse that agent can justify reuse after a merge. Pinning or idle availability alone cannot.

Send a peer message only when it is needed to complete the active task, such as resolving a blocker, avoiding overlapping edits, or delivering a requested handoff. Skip routine acknowledgements, status nudges, and unsolicited assignments. After delegation, let the child own implementation, validation, and its PR. Follow up for a concrete dependency, a user scope change, or the final result.

## Choose socket permissions first

In Codex with restricted network access, use `sandbox_permissions: "require_escalated"` before the first control-socket command, including `graftty team list --json`. Keep each request scoped to the authorized command and separate from unrelated shell work. Use only command-specific reusable prefixes, never a blanket `graftty` rule.

Keep this execution mode for subsequent control-socket commands. Do not repeat a known denial, change provider sandbox configuration, or enable general networking. If escalation is unavailable or denied, report the limitation and continue independent work. A readable socket or filesystem write grant does not grant connection access.

Team, pane, worktree, image, open, and other app-control commands use the socket. `graftty attention report --stdin`, help, and local-only commands do not need socket permission. Providers that already permit the socket need no elevation. For EPERM, errno 1, or connection failures, read [socket diagnosis](references/socket-diagnosis.md).

## Find a recipient

Run `graftty team list --json`. In `members[]`, identify `name` and `worktree_path`; in `agents[]`, copy `address` and check `runtime` and `is_reachable`. Worktree `is_running` and pinned status do not establish reachability.

| Address | Destination |
| --- | --- |
| Worktree name or canonical path | Earliest reachable top-level agent there |
| `<canonical-worktree-path>#<runtime>` | Provider, with messages queued between sessions |
| `<canonical-worktree-path>#<runtime>-<12hex>` | Exact agent; fails closed when gone |

Never route by provider display labels, which may be truncated. Native subagents have no independent Graftty address. Reachability tells you where a message can go; it does not authorize reuse for a new task.

For another repository, Mac, legacy message envelope, or native reply socket, read [routing details](references/routing.md).

## Write clear messages

Use STE-inspired controlled English for agent messages and delegation prompts. Follow the practical principles of [ASD-STE100 Simplified Technical English](https://www.asd-ste100.org/STE_faq.html); full dictionary compliance is not required.

- Identify the task or PR and the message purpose: request, blocker, question, or result.
- Write requests as direct commands. Write one instruction per sentence. Keep sentences short.
- Put conditions before the actions they control. Name the target and limit the requested scope.
- Use the same term for the same thing. Preserve exact paths, commands, addresses, and identifiers.
- Write results as facts. Distinguish passed, failed, pending, and not-run checks. Give the tested commit and relevant evidence.
- State uncertainty explicitly. Ask a direct question when a decision is necessary. Omit conversational padding and routine acknowledgements.

Example delegation prompt:

```text
Request. Task T42.
Fix the sidebar spinner alignment.
Change only the sidebar layout.
Run the Codex simulator test.
Run the Claude simulator test.
Open a pull request.
Report the PR, tested commit, and test results.
If a dependency blocks this task, report the dependency.
```

Clear wording does not authorize a new task or expand an existing assignment. Apply the coordination rules above before sending a message.

## Send and receive

Send bodies through stdin, never shell arguments. Generate a fresh quoted heredoc delimiter absent from the body:

```sh
graftty team send --stdin '<address>' <<'GRAFTTY_7F3A91C2'
<context, requested result, and reply address>
GRAFTTY_7F3A91C2
```

`graftty team broadcast --stdin` uses the same pattern with no recipient. Use it only when every other worktree needs the message. Both commands accept `--urgent` for delivery at the next post-tool hook boundary. Success means accepted, not answered. Do not resend after uncertain delivery.

Reply with the inbox ID from the `id` attribute of `<graftty-peer-message>`. Decode XML entities in envelope attributes before using them:

```sh
graftty team reply '<message-id>' --stdin <<'GRAFTTY_REPLY_5D9A7C21'
<reply>
GRAFTTY_REPLY_5D9A7C21
```

The stored sender overrides reply paths in the body. Use `--fallback` only after an explicit exact-agent-unavailable error to queue for that sender's provider on the same Mac.

Replies arrive through hooks; do not poll for completion. For deliberate inspection:

| Command | Effect |
| --- | --- |
| `graftty team inbox --keep-unread --json` | Peek at unread messages |
| `graftty team inbox --history --json` | Read history without changing delivery state |
| `graftty team inbox --json` | Read unread messages and mark them read |

`--all` fetches every matching page. `--history` and `--keep-unread` are incompatible. `--worktree`, `--repo`, or `--member` selects diagnostic scope and peeks unless `--history` is supplied. Empty output does not establish completion. Never edit state files to advance delivery; rerun the inbox command if advancement fails.

## Delegate a task

Each worktree has exactly one implementer, the agent that edits its checkout. Never create worktrees yourself with `git worktree add`, provider worktree tools, worktree-isolated subagents, or other skills. Subagents sharing your current worktree are allowed.

To add a reviewer or pair to an existing worktree, run `graftty pane add <worktree> --agent <codex|claude> --prompt-stdin` with the brief on stdin. An added agent does not edit files unless the implementer hands off. Added agents share the worktree path in `graftty team list --json`. The unsuffixed address reaches the earliest reachable agent, and `<path>#<runtime>` reaches the earliest agent of that runtime. Address an added agent by its exact ID. Use `<path>#<runtime>` only when no other agent of that runtime shares the worktree.

When the user requests delegation, give the child bounded independent work. Avoid tiny or overlapping tasks. Creating a worktree alone does not delegate; launch its agent with the task:

```sh
graftty worktree add <name> --agent <codex|claude> --prompt-stdin <<'GRAFTTY_DELEGATE_7F3A91C2'
Objective: <bounded outcome>
Owned scope: <files or subsystem>
Verify: <checks>
Return: send results, changed paths, validation, and commit hash with graftty team send --stdin.
Parent exact address: <copy from roster>
Parent fallback address: <worktree_path>#<runtime>
Use the exact address while reachable; after restart or /clear, use the fallback.
GRAFTTY_DELEGATE_7F3A91C2
```

Save the operation ID, path, and returned stable reply address. Pause the delegated scope until `graftty team list --json` confirms the child is reachable. Then relinquish that scope until reviewing its result. If launch fails without a reachable child, retain ownership and report the failed handoff. Requested delegation needs no separate confirmation and grants no additional authority.

Read only the reference relevant to the operation:

- [Worktree operations](references/worktrees.md): starting refs, existing branches, wait/timeout behavior, remote creation, launch recovery, pane inspection, removal, and reconnecting paired Macs.
- [Durable roles](references/durable-roles.md): pinning, retention, and hierarchical `.graftty/**/GRAFTTY.md` instruction files. Read before creating or changing a role or instruction file.
