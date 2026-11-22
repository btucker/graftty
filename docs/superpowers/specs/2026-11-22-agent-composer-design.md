# One prompt composer for coding agents

**Draft for review, 2026-11-22.** Mac, iPhone, and iPad. The proposed first release targets newly launched graphical agent sessions.

In a Codex tab, type `/rev`, choose `/review`, and add any arguments before pressing Send. Switch to Claude in the same worktree and type `/`. The picker now shows the commands Claude offers for *that session*, including project commands when the adapter advertises them. Adding a command upstream should require no Graftty release.

The proposed UI is an embedded assistant-ui composer. Graftty would connect it to the active agent using Agent Client Protocol (ACP). The aim is to reuse editing, completion, and keyboard behavior across providers while letting the provider execute each command. The pending [AGENT-6.166 through AGENT-6.168 requirements](../../../Tests/GrafttyTests/Specs/AgentTodo.swift) cover discovery, selection, and submission.

## Where the composer lives

Offer a **Chat** option when starting a supported agent from **New agent**. Keep the composer at the bottom of that agent's tab, with the agent's text replies and command results above it. The Context panel can describe a whole worktree with several agents. An input field there could send a draft to the wrong conversation.

On a paired Mac, iPhone, or iPad, the selected tab addresses the same agent on the worktree host. Each device keeps its own unsent draft for each session when switching tabs. Attaching a composer to an agent already running in a terminal is a separate design question. Loading a saved conversation does not establish ownership of a live turn or a pending approval.

## Typing and choosing a command

- A slash at the start of the prompt opens the picker. Typing filters the active session's list. A slash in a path or later in a sentence is ordinary text.
- Each row shows the advertised name and description. Selecting a row inserts the command into the draft and returns focus to the input. If the agent provides an argument hint, display it beside the draft and keep it out of the submitted text.
- With the picker open, arrow keys move the selection, Return accepts it, and Escape dismisses it. A tap has the same effect as accepting with Return. With the picker closed, hardware Return sends and Shift-Return inserts a newline. On the software keyboard, Return inserts a newline and the Send button submits. Confirming composed text with an input method takes precedence over either action.
- A missing or empty catalog leaves ordinary text input available. A user can still type a slash-prefixed prompt and send it literally. If a selected command disappears before Send, keep the draft and flag the change so the user can edit it or explicitly send it as text.
- While the agent is busy, the user can draft the next prompt. Enable Send when the session can accept a new turn. A provider question or approval has its own response control bound to the original request.

Start with multiline text and command completion. For sessions that advertise image input, reuse Graftty's clipboard image preparation, previews, and size limits. File mentions are a later decision: inserting a path and attaching file contents have different effects, especially from a phone connected to a remote worktree. [Shared prompt images](../../../Sources/GrafttyCommandUI/WorktreePromptImages.swift) · [Image limits](../../../Sources/GrafttyProtocol/WorktreeAgentConfiguration.swift)

## How the host and composer communicate

1. **Bind the tab.** The worktree host starts the selected ACP agent or adapter in the worktree with its managed environment, instructions, and agent identity. It binds the resulting ACP session ID to the Graftty agent and assignment. A paired client gets this binding through the authenticated host connection. The current launcher creates terminal agents, so graphical launch and registration need explicit host support. [New agent menu](../../../Sources/GrafttyCommandUI/NewAgentMenu.swift) · [Terminal launch path](../../../Sources/GrafttyKit/Teams/WorktreeAgentLaunchCommand.swift)
2. **Populate the picker.** The host listens for `session/update` with `available_commands_update`. It replaces that session's catalog with the supplied names, descriptions, and optional input hints. A newly bound session starts with an empty catalog. On viewer reconnect, the host sends its current snapshot. Late updates from an earlier binding cannot change the active picker. [ACP slash commands](https://agentclientprotocol.com/protocol/v1/slash-commands)
3. **Edit the draft.** Bundle a local assistant-ui React composer in a `WKWebView` on both platforms. Supply the session catalog through its trigger popover. Its standard slash action fires on selection and can insert a directive chip. Wire selection to insert editable literal text instead. The web view needs only composer state and editing actions. Swift owns session routing and the connection to the host. [Composer primitives](https://www.assistant-ui.com/docs/primitives/composer) · [Slash action behavior](https://www.assistant-ui.com/docs/guides/slash-commands)
4. **Send once.** Send the chosen binding, a submission ID, and the draft to the host. The host checks the binding and reserves the idle turn before forwarding a `session/prompt` request. It records the submission ID so a repeated request returns its existing status. The host acknowledges accepting the draft. The agent returns its ACP prompt result when the turn ends. Clear only the submitted draft on host acceptance. Preserve it on rejection. After a lost acknowledgment, query the same submission ID. If delivery is uncertain, show the submitted text and require an explicit resend. [ACP prompt turn](https://agentclientprotocol.com/protocol/v1/prompt-turn)

Use a single host operation for text prompts and advertised slash commands. For example, choosing `/review` makes zero protocol calls. Sending the draft creates one prompt containing `{"type":"text","text":"/review"}`. Provider-specific behavior stays behind that interface.

## Provider coverage and limits

| Agent | Source of commands | What to check with the installed version |
| --- | --- | --- |
| Codex | [codex-acp](https://github.com/agentclientprotocol/codex-acp) exposes commands such as `/review` and `/compact`. | Verify a built-in and a configured skill. Check the exact text each expects. |
| Claude Code | [claude-agent-acp](https://github.com/agentclientprotocol/claude-agent-acp) exposes custom slash commands through the Claude Agent SDK. | Verify a worktree command with arguments and a built-in that returns text. |
| Antigravity | [Google's `agy acp`](https://antigravity.google/docs/cli/acp/) runs as an ACP server. | Record the live catalog for a default and a custom agent. Availability has varied by session and version. [Provider report](https://github.com/google-antigravity/antigravity-cli/issues/1472) |

Only enable Chat for a provider when the host can launch it, show its replies, and handle or explicitly decline permission requests. An agent must never sit waiting for a decision the user cannot see. Graftty's current [managed runtime enum](../../../Sources/GrafttyKit/Notification/NotificationMessage.swift) and New agent menu list Codex and Claude. Antigravity needs launch and lifecycle integration in addition to composer validation. Terminal-only commands that open provider-specific screens remain available in terminal sessions.

## Acceptance checks

| Scenario | Observable result |
| --- | --- |
| Two sessions of the same provider advertise different commands. Switch tabs while the first sends a catalog update. | Each tab shows its own commands and draft. An empty update removes previous entries. |
| Select a command with a hardware keyboard, add arguments, then Send. Repeat by touch. | Selection sends nothing. The originating agent receives the exact command and arguments once. |
| Type multiline text, a path containing a slash, and text using an input method. Navigate the picker with VoiceOver. | The text survives editing, Return commits composed text, and VoiceOver announces the current choice. |
| Two viewers submit to an idle session at the same time, or one loses its acknowledgment. | The host admits one active turn. Both viewers can see the outcome of their own submission. An uncertain delivery is never automatically replayed. |
| Disconnect the phone during a permission request, then reconnect. | The host retains the pending request or reports its resolution. A reply goes only to the request that is still pending. |

Before adopting assistant-ui, try its composer in the actual Mac and iOS web views with the picker open above the software keyboard. Check focus, marked text, VoiceOver, and argument editing. Pin the version used for the trial: the popover primitives are stable, but the slash adapter helper is marked unstable. If the web view fails these checks, the same session catalog and submission contract can drive Graftty's native text editor.
