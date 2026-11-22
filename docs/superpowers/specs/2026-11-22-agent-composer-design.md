# Chat and Terminal views of one agent tab

**Draft for review, 2026-11-22.** A user can switch a running agent tab between a graphical chat (GUI) and the provider's own terminal interface (TUI), in either direction, on Mac, iPhone, and iPad.

Start a review in **Chat**. Switch to **Terminal** while the agent is working, use the provider's keyboard controls to answer an approval, then switch back to **Chat** to read the result. The same tab stays selected throughout. The review runs once, the approval is answered once, and the next message continues the same conversation.

Chat is a native SwiftUI view in `GrafttyCommandUI`, shared by Mac and GrafttyMobile. Graftty owns the tab, the connection to its live session, and the choice of view. A user can open the TUI for the full provider interface, including interactions the GUI cannot yet render.

## Switching views

Put a **Chat / Terminal** switch in the selected agent tab's header, within reach in both views. On compact screens the control stays above the keyboard. **New agent** launches the provider once, with a live terminal. The proposed default is Terminal. An already-running tab can use the same switch as soon as the host can bind its GUI to that live session. Each viewer remembers its own view for the tab. Choosing Chat on a phone leaves another viewer's Mac in its chosen view.

| On selection | What the user sees |
| --- | --- |
| **Chat** | The conversation so far, including turns entered through the TUI. Output from the active turn continues below the history. The composer restores this viewer's GUI draft and puts the cursor in it. |
| **Terminal** | The tab's existing terminal at its current screen, including any provider picker, unfinished input, or approval. Keyboard input returns to the TUI. Graftty keeps its terminal session alive while Chat is visible. |
| **Terminal** from a GUI message such as **Answer in Terminal** | The same outstanding provider request. Switching leaves the decision pending. Once the provider resolves it, Chat removes the action. |

Keep unfinished input in the view that owns it. For example, switching away from a half-written GUI prompt never pastes or submits it into the TUI. A submission made in either view becomes part of the shared conversation. An interrupted or exited agent follows the existing explicit recovery flow. Changing views cannot restart it.

View selection and control are independent. An observing viewer can switch views and prepare a draft. To act, it uses **Take Control**. The host checks the current controller for GUI submissions and approval replies as well as terminal keystrokes. Hiding the terminal leaves the PTY at its last valid size. Returning to Terminal applies the normal size rules for that viewer. [Display ownership](../../../Sources/GrafttyProtocol/DisplayOwnership.swift)

## Typing and choosing a command

- A slash at the start of the prompt opens the picker. Typing filters the active session's list. A slash in a path or later in a sentence is ordinary text.
- Each row shows the advertised name and description. Selecting a row inserts the command into the draft and returns focus to the input. If the agent provides an argument hint, display it beside the draft and keep it out of the submitted text.
- With the picker open, arrow keys move the selection, Return accepts it, and Escape dismisses it. A tap has the same effect as accepting with Return. With the picker closed, hardware Return sends and Shift-Return inserts a newline. On the software keyboard, Return inserts a newline and the Send button submits. Confirming composed text with an input method takes precedence over either action.
- A missing or empty catalog leaves ordinary text input available. A user can still type a slash-prefixed prompt and send it literally. If a selected command disappears before Send, keep the draft and flag the change so the user can edit it or explicitly send it as text.
- While the agent is busy, the user can draft the next prompt or switch views. Enable Send when the session can accept a new turn. Offer a GUI answer only when the host can address that exact pending request and observe its resolution. Otherwise offer **Answer in Terminal**.

Start with multiline text and command completion. For sessions that advertise image input, reuse Graftty's clipboard image preparation, previews, and size limits. File mentions are a later decision: inserting a path and attaching file contents have different effects, especially from a phone connected to a remote worktree. [Shared prompt images](../../../Sources/GrafttyCommandUI/WorktreePromptImages.swift) · [Image limits](../../../Sources/GrafttyProtocol/WorktreeAgentConfiguration.swift)

## One live session behind both views

1. **Identify the running agent.** The worktree host binds the existing Graftty agent and assignment to its pane, terminal session, live provider process, and current provider conversation ID. On a switch, it validates that binding and attaches the requested view. Matching a provider name and worktree path is insufficient: two Codex tabs can share both. Launching an adapter that creates a second agent or resuming a copy of a saved conversation would fork the user's work. If live attachment fails, keep the terminal usable and explain why Chat is unavailable. [Terminal launch path](../../../Sources/GrafttyKit/Teams/WorktreeAgentLaunchCommand.swift)
2. **Catch up from the same conversation.** The host supplies history, current turn state, pending requests, and live output over the authenticated connection. Take a snapshot with an event cursor, or buffer live events while reading history and reconcile them using provider item IDs. Switching views or reconnecting midway through a reply must yield one copy of each message in order. Revalidate on a provider-side thread change such as a TUI resume. Invalidate the old binding, draft destination, commands, and request handles before enabling Send for the new conversation.
3. **Populate the picker.** Use the live session's command catalog when the provider exposes one. Agent Client Protocol (ACP) publishes it through `available_commands_update`. Replace that session's entire list on each update. A native provider transport may expose commands differently. Preserve ordinary text input when discovery is unavailable, and offer Terminal for the provider's full command menu. [ACP slash commands](https://agentclientprotocol.com/protocol/v1/slash-commands)
4. **Edit the draft.** Use a native multiline editor with the existing completion popover (`AgentCompletionPicker`) fed by the session catalog. Selecting a row inserts editable literal text. An earlier draft proposed an assistant-ui React composer in a `WKWebView`. The Mac app has no web view or JavaScript bridge today, GrafttyMobile does not link the web bundle, and a web composer would need its own focus, input-method, and VoiceOver work on each platform. The session catalog and submission contract are the same either way.
5. **Send once.** Submit the binding, a submission ID, and the draft to the host. Verify control, current thread, and turn state before sending through the live provider connection. Deduplicate the submission ID across reconnects. Clear only the submitted draft once the host accepts it. Preserve a rejected draft. If the provider may have received it before a disconnect, show its delivery as uncertain and require an explicit resend. A switch itself never emits input. [ACP prompt turn](https://agentclientprotocol.com/protocol/v1/prompt-turn)

For example, choosing `/review` edits the draft. With an ACP connection to the live agent, Send issues one `session/prompt` containing `{"type":"text","text":"/review"}`. With a native connection, offer that completion only when the host can invoke the equivalent command on the bound thread. Typing `/review` into an arbitrary JSON text field does not establish command support.

## Provider coverage and limits

| Agent | Existing integration | What the prototype must prove |
| --- | --- | --- |
| Codex | Graftty registers the native TUI's [app-server socket](../../../Sources/GrafttyKit/Teams/Resources/codex-wrapper.sh). Chat joins the bound thread on that server as a second client. | **Verified with codex-cli 0.171.0** (see below). The stock [codex-acp adapter](https://github.com/agentclientprotocol/codex-acp) starts its own app server, so it is not used. |
| Claude Code | The [peer session registry](../../../Sources/GrafttyKit/Teams/ClaudePeerSessionRegistry.swift) identifies a running Claude instance for team messages. The [ACP adapter](https://github.com/agentclientprotocol/claude-agent-acp) uses the Claude Agent SDK. | Find a supported way to observe and submit **human** turns to the same interactive session. Peer-message delivery alone does not prove this. Test a worktree slash command and a permission prompt in the original TUI. |
| Antigravity | [Google's `agy acp`](https://antigravity.google/docs/cli/acp/) exposes an ACP server. This checkout's [managed runtime enum](../../../Sources/GrafttyKit/Notification/NotificationMessage.swift) lists Codex and Claude. | Verify that a structured client and the native TUI can share the live conversation before adding the provider to Graftty's launcher. |

Start the integration trial with a running Codex tab. Enable switching for a provider once a round trip preserves the live agent and both views can observe work done through the other. A provider-specific TUI picker can stay in Terminal. If the host cannot detect that the agent needs a decision, or GUI-originated turns never appear in its TUI, record that provider as unsupported until the integration can satisfy the contract.

## Acceptance checks

The [pending requirements AGENT-6.166 through AGENT-6.173](../../../Tests/GrafttyTests/Specs/AgentTodo.swift) cover command selection, submission, and live view switching.

| Scenario | Observable result |
| --- | --- |
| Start a turn in an existing terminal tab, switch to Chat during output, send the next turn in Chat, then return to Terminal. | One tab, terminal session, provider process, assignment, and conversation ID throughout. Both views show both turns once. Switch again and continue. |
| Leave an unsent draft in each view and switch twice. | Each view restores its own input. The agent receives no prompt until the user sends one. |
| Switch during a permission request. Answer in Terminal and return to Chat. | One decision reaches the agent. A stale GUI action cannot answer an already resolved request. |
| Open Chat on iPhone while a Mac controls Terminal. Take control from the phone and send. | Each viewer keeps its chosen view. Only the current controller can act, and both see the accepted turn. |
| Switch views while the TUI changes threads, or after the live session exits. | The host rejects stale input. No new process, session, or turn starts as a side effect of switching. |
| Two sessions of the same provider advertise different commands. Switch tabs while the first sends a catalog update. | Each tab shows its own commands and draft. An empty update removes previous entries. |
| Select a command with a hardware keyboard, add arguments, then Send. Repeat by touch. | Selection sends nothing. The originating agent receives the exact command and arguments once. |
| Type multiline text, a path containing a slash, and text using an input method. Navigate the picker with VoiceOver. | The text survives editing, Return commits composed text, and VoiceOver announces the current choice. |
| Two viewers submit to an idle session at the same time, or one loses its acknowledgment. | The host admits one active turn. Both viewers can see the outcome of their own submission. An uncertain delivery is never automatically replayed. |
| Disconnect the phone during a permission request, then reconnect. | The host retains the pending request or reports its resolution. A reply goes only to the request that is still pending. |

## Codex trial results

Two clients on one app-server, and then Graftty's own session code against a live server, showed the following on codex-cli 0.171.0.

- `thread/resume` with the ID of a running thread joins it. The reply carries the history, and later notifications arrive live. It starts no thread and no process. A thread created as ephemeral cannot be joined.
- Each client receives the other's turns. A user message carries the `clientUserMessageId` given to `turn/start`, so Chat can match a row to its submission.
- An approval request reaches every joined client with the same request ID. After one client answers, the others receive `serverRequest/resolved`. The thread status reports `waitingOnApproval` while it is pending.
- `skills/list` supplies the command catalog and `skills/changed` signals a refresh. Built-in TUI commands such as `/review` and `/compact` are separate requests (`review/start`, `thread/compact/start`), so Chat offers one only when the host maps it to that request.

## Build order

1. **Session core (done).** Wire types and a shared transcript reducer in `GrafttyProtocol`, and `CodexChatSession` in `GrafttyKit`: join the bound thread, fan out ordered updates, admit one turn per submission ID, answer each request once.
2. **Host service (done).** Resolve a tab to its agent, assignment, socket, and thread. Invalidate on a thread change. Check the display controller before a submission or an answer. Expose it to paired viewers as a new SSH subsystem, and to the Mac app directly.
3. **Chat view (done).** Transcript, composer, slash picker, and request actions in `GrafttyCommandUI`. Add the Chat / Terminal switch for local Mac tabs.
4. **Other viewers (done, not yet tried on devices).** Mac remote viewer, iPad, and iPhone. The Mac and iPad keep the per-viewer view choice in each viewer's workspace layout; the iPhone keeps it in its own settings. A host advertises Chat per tab, so a viewer of an older or headless host shows no switch.

The switch appears only for a tab whose provider passed this trial. Claude Code and Antigravity tabs stay Terminal-only until each has a verified way to share its live conversation.
