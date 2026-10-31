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

Agent, team, pane, worktree, image, open, and other app-control commands use the socket. `graftty attention report --stdin`, help, and local-only commands do not need socket permission. Providers that already permit the socket need no elevation. For EPERM, errno 1, or connection failures, read [socket diagnosis](references/socket-diagnosis.md).

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

Each worktree has exactly one implementer, the agent that edits its checkout. Never create worktrees yourself with `git worktree add`, provider worktree tools, worktree-isolated subagents, or other skills. Harness-native subagents sharing your current worktree remain available. Use them for work inside a provider session. Graftty agents are independent terminal sessions with their own assignments and cleanup; they do not replace native subagents.

Use `graftty agent add` for a new agent. Omit `--worktree` to create a new worktree. Pass `--worktree <name-or-path>` to share an existing checkout. An added reviewer or pair does not edit files unless the implementer hands off. `--provider claude` or `--provider codex` overrides the host's Default agent selection; omit it to use that setting.

When the user requests delegation, give the child bounded independent work. Avoid tiny or overlapping tasks:

```sh
graftty agent add <name> --provider codex --prompt-stdin --json <<'GRAFTTY_DELEGATE_7F3A91C2'
Objective: <bounded outcome>
Owned scope: <files or subsystem>
Verify: <checks>
Return: report the result, changed paths, validation, and commit hash with graftty agent finish --result-stdin.
Do not finish merely because a turn ends or you need input.
GRAFTTY_DELEGATE_7F3A91C2
```

For a reviewer in the current worktree, add `--worktree '<worktree-name>'`. Save the returned `agent.id`, `agent.assignmentID`, `operationID`, and `worktree`. The managed ID identifies this assignment's lifecycle. `agent.nativeAgentID`, once populated, identifies the provider session for team messages. Do not substitute the managed ID into a native team address. Confirm readiness and copy the exact native address from `graftty team list --json` before messaging. A starting agent or accepted creation is not a reachable child.

Pause the delegated scope until the child is reachable, then relinquish it until reviewing the result. If launch fails without a reachable child, retain ownership and report the failed handoff. Requested delegation needs no separate confirmation and grants no additional authority.

## Finish and clean up assignments

A child explicitly completes its assignment with a result on stdin:

```sh
graftty agent finish --result-stdin <<'GRAFTTY_RESULT_4B9D2F10'
<result, PR or commit, changed paths, checks run, and any remaining limitations>
GRAFTTY_RESULT_4B9D2F10
```

The launch environment supplies the managed agent and assignment IDs. If those are unavailable, use the exact IDs from the launch context: `graftty agent finish <managed-id> --assignment <assignment-id> --result-stdin`. Keep ordinary Attention recaps separate. Waiting for input, becoming idle, an end-of-turn hook, and process exit do not mean the assignment is complete.

The parent receives a durable completion event naming the child, result, and completion ID. Handle the result, then close that completed assignment:

```sh
graftty agent close <managed-child-id> --completion <completion-id>
```

This ends the child's terminal, removes its live view, and retains the result and worktree. Do not use a pane number or delete the worktree as a substitute. Resolve any still-useful child-owned processes before cleanup. A failed close remains pending and can be retried with the same completion ID. Reading or replying to the completion event does not acknowledge cleanup.

After a parent restart, recover obligations with `graftty agent list --parent <native-parent-id> --status awaiting-cleanup --json`. Session-start context also lists pending cleanup. Repeated finish and close requests are idempotent for the same assignment. If more work is needed before teardown, `graftty agent resume <managed-child-id> --json` creates a new assignment in that still-live session. Give the child the new assignment ID and further instructions through its exact native address. An old completion cannot close the resumed assignment. Closed terminals are not resumed by this command.

Before closing your own assignment, handle outstanding children. An unavailable parent leaves results and cleanup pending for recovery or user action. Do not send routine acknowledgements or repeatedly poll an active child.

Read only the reference relevant to the operation:

- [Worktree operations](references/worktrees.md): starting refs, existing branches, wait/timeout behavior, remote creation, launch recovery, pane inspection, removal, and reconnecting paired Macs.
- [Durable roles](references/durable-roles.md): pinning, retention, and hierarchical `.graftty/**/GRAFTTY.md` instruction files. Read before creating or changing a role or instruction file.
