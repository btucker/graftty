# Agent workspace implementation plan

Graftty should let users create and supervise agents without managing a growing collection of terminal panes. Separate agent identity and assignment lifetime from terminal sessions and their layout. Give ordinary shells a bottom drawer, and make the parent responsible for closing agents it creates after receiving their results.

This plan covers Mac, Graftty Mobile, the host protocol, CLI, settings, and bundled agent instructions. The user has authorized implementation and a PR. The HTML files beside this plan are design references, not production components.

## Product decisions

- Use **agent** throughout. Harness-native subagents remain useful and are not replaced or independently managed by Graftty.
- Show monochrome Claude and Codex marks beside meaningful agent names. Ordinary shells use a terminal symbol.
- New agents open as tabs within a worktree. Users can move tabs into split groups and merge groups back through drag and menu actions.
- Ordinary terminals belong in a bottom drawer. A labeled bottom bar opens it and becomes its header. Hiding the drawer preserves sessions and returns focus to the prior agent.
- Introduce `graftty agent add`. An existing-worktree option places the new agent there; omission creates a worktree.
- Replace automatic arbitrary agent startup commands with a Default agent picker. Explicit provider selection overrides the launch host's default.
- A child explicitly reports assignment completion. The parent receives a durable event identifying the child and the cleanup action, then explicitly closes it after handling the result.
- Closing an agent retains its result/history and does not delete its worktree or branch.

Implementation defaults: open new agents as tabs rather than introducing an unapproved hidden-agent mode. Preserve a recognized legacy provider preference. Without a preference, require a provider selection in the UI or CLI; do not infer one from whichever executable happens to be available. Automatic hiding of newly created agents can be explored later.

## Existing code and constraints

`TeamAgentIdentity` and `TeamAgentDirectory` in `Sources/GrafttyKit/Teams/TeamAgentDirectory.swift` identify top-level provider sessions and explicitly exclude native subagents. `TeamPresence` is liveness data; it must not become the sole durable record of an assignment or cleanup obligation.

`TeamInbox`, `TeamEvents`, the event dispatcher, and provider hooks already deliver durable messages. Extend that path for completion rather than creating a competing messaging system. Exact agent routing must not fall through to another same-provider agent in the worktree.

`Worktree.swift` and `CLI.swift` currently implement worktree creation and pane creation. `PaneAgentLaunch` and `WorktreeAgentLaunchCommand` handle startup and prompt staging. Consolidate agent creation through shared launch services, retaining existing Git setup and remote-placement behavior.

The legacy startup controls are in `Sources/Graftty/Views/SettingsView.swift`, under General in this checkout. They persist `defaultCommand` and `defaultCommandFirstPaneOnly`. `DefaultCommandDecision`, `TerminalManager`, and `PaneCommands` consume them. The new picker belongs in `AgentTeamsSettingsPane`; its per-event prompt remains separate.

`SplitTree` currently has terminal-slot leaves. `WorktreePanes.PaneLayoutNode` publishes a split-only representation consumed by Mac, mobile, and the web client. Introduce tabs without redefining existing wire cases in place. Capability negotiation and old-client behavior are part of the change.

## 1. Separate agent records, sessions, and layout

Create durable agent metadata containing a stable agent identifier, provider, display name, host/worktree identity, requesting parent when present, assignment identifier, and binding to the current provider/terminal session. Preserve existing session addresses through an explicit mapping. A rename or layout move never changes the cleanup target.

Keep three concerns separate:

- Agent and assignment state: running, waiting, finished awaiting cleanup, closing, closed, or failed.
- Process observation: reachable, disconnected, or exited. A quiet process or an end-of-turn hook does not mean the assignment is finished.
- View state: tab-group membership, selection, split geometry, and drawer visibility.

Resume starts a new assignment generation so delayed completion events cannot close resumed work. Retain an exact provider-native conversation resume identifier, provider, owning host, original worktree, and necessary launch configuration independently of the terminal session and Graftty routing identity. Keep a durable tab reference to the managed agent/conversation after its live pane binding is removed; device-local dismissal must not delete its record. Existing sessions migrate without relaunching processes or rearranging the user's saved splits. Unrecognized shell sessions remain shells; detecting an agent inside a shell may add provider identity without moving its view automatically.

Validation: old state decoding, stable identity across layout changes, restart reconciliation, same-provider agents in one worktree, native-subagent exclusion, and stale assignment generations.

## 2. Implement the parent completion and cleanup contract

Creation records the parent and returns the child identity before asynchronous launch finishes. Resolve the caller from its native agent and terminal-session metadata. User-created agents without a parent expose completion to the user.

The proposed command sequence is:

```sh
# New worktree; provider comes from the configured default
graftty agent add review-layout --prompt-stdin

# Existing worktree, explicit provider, bounded assignment
graftty agent add review-layout --worktree reconsider-workspace \
  --provider claude --prompt-stdin

# Child explicitly finishes its current assignment
graftty agent finish --result-stdin

# Parent handles the result and closes that completed assignment
graftty agent close <child-id> --completion <completion-id>

# Recover cleanup obligations after a parent restart
graftty agent list --parent <parent-id> --status awaiting-cleanup --json
```

Treat flag spelling as an implementation contract to verify against existing CLI conventions. Keep `--provider` because `--agent` becomes redundant under `agent add`.

Persist the result and its history/transcript references before accepting completion. Persist a completion event with child ID, parent ID, assignment generation, completion ID, result reference, and cleanup instruction. Use a durable outbox or equivalent reconciliation so a crash between saving completion and appending the inbox event cannot lose the notification. Retries must not duplicate results or events.

Delivery acknowledgement is not cleanup acknowledgement. The child remains awaiting cleanup until a matching close succeeds. The parent's inbox and startup context expose outstanding cleanup even after the original event was read. Do not depend solely on a model remembering an instruction from an old turn.

Closing validates the expected assignment, ends the correct terminal session, confirms teardown, and then removes live views. Repeated closes succeed harmlessly. A failed teardown remains visible and retryable. Never route cleanup through a mutable pane index, provider-only address, or worktree-wide broadcast.

If the parent needs more work, it can resume the child instead. Resume must support both a healthy still-live provider and a cleaned-up provider: reuse the former, or create a new terminal on the owning host in the original worktree and invoke the provider's exact saved conversation resume path for the latter. Serialize cleanup and resume, reserve the new generation before launching, and replace the terminal binding without duplicating the durable agent or its retained tab. Preserve the prior assignment result and provenance. A user-initiated restart is a new user-owned assignment, not a reopened cleanup obligation for an unavailable former parent. Provider resume failure retains the completed record and exposes retry; never silently launch a fresh conversation. If the parent is unavailable, keep the obligation and expose it to the user. A parent with unfinished children must surface those obligations before it closes; do not silently orphan descendants. Do not recursively kill worktrees or unrelated processes. Explicitly handle independently useful child-owned processes such as dev servers.

Validation: duplicate finish and close, crash between state and event writes, unavailable parent, parent restart, stale completion after resume, two same-provider children, teardown failure, and surviving worktree changes.

## 3. Unify creation and update the bundled team skill

Add the `agent` command group and shared host operations for add, list/status, finish, and close. Reuse existing worktree creation, startup receipt, timeout, and prompt validation behavior. Preserve the existing paired-host command during migration. Support structured results with stable agent ID, launch operation ID, host, worktree, and readiness status.

An explicit existing worktree must resolve uniquely or fail. It must never silently fall back to creating one. Distinguish accepted launch from a reachable agent. The host receiving an agent request resolves its own provider default.

Keep existing worktree and pane commands for Git and terminal/layout operations. Preserve old agent-launch forms as compatibility paths during migration, implemented through the shared service rather than maintaining separate semantics. New agents should use the new command in examples and guidance.

Update the repository source at `Sources/GrafttyKit/AgentPlugins/codex/plugins/graftty/skills/graftty-team/SKILL.md` and its worktree/routing references together with the CLI. Trace how the same instructions reach Claude and update the relevant packaging/version checks. Do not patch the installed plugin cache.

The skill must teach the complete parent/child sequence, exact returned identities, completion, cleanup, and recovery. Preserve the one-implementer-per-worktree rule and existing delegation authorization rules. Explicitly allow harness-native subagents for suitable in-session work; independent Graftty sessions are an additional choice.

Validation: parser/help tests, stdin prompt preservation, both placement paths, explicit/default provider precedence, capability mismatches, and bundled instruction consistency for both providers.

## 4. Add provider defaults and shared monochrome assets

Persist a typed optional default provider in shared host settings, not only a Mac view's local storage. Add Claude and Codex choices to Agent teams settings and use the same resolution policy in UI, CLI, mobile, and remote launches.

Migrate recognized legacy Claude/Codex commands conservatively. Preserve the original command and flags for recovery; arbitrary shell scripts cannot be translated by substring matching. Show a migration choice where necessary. Remove the first-pane-only control once launch decisions belong to explicit agent creation. Ordinary terminal creation opens a shell; terminal reattachment must never launch a second agent.

Keep provider plugin installation and per-event prompts intact. Report a missing chosen provider rather than silently switching harnesses. Existing running agents are unaffected by changing the default.

Package monochrome assets once for shared Mac/mobile use. Record asset provenance in the repository and avoid depending on files in installed apps. Use semantic tint, task labels, and accessible provider names in settings, tabs, and pickers. Sidebar agent rows use shared status indicators without provider marks.

Validation: migration fixtures including commands with flags and arbitrary scripts, unset defaults, unavailable providers, explicit overrides, restore without double launch, and accessible light/dark rendering.

## 5. Implement tab groups and the terminal drawer

Add a versioned workspace presentation model: split nodes contain tab groups; each group has ordered session references and a selected tab. The worktree also owns terminal-drawer session references. One session appears in at most one live view position on a given device.

Session ownership must outlive the mounted terminal view. Switching tabs, hiding the drawer, or moving a session between groups preserves the process, scrollback, input routing, and stable identity. Keep rendering/subscription costs bounded for inactive views.

On Mac, retain Back/Forward, a quiet project/worktree breadcrumb, and Context in the window header. Put the full branch and path in breadcrumb hover help. Agent tabs form the primary row above the canvas, with provider marks and an underline on the selected tab. Place New agent immediately after the last tab. Dragging a tab to an edge creates a split; dragging to another group moves the tab. Pane-header menus expose Move to tab group and Merge groups, with keyboard-accessible equivalents. Collapse empty groups predictably and retain focus through moves.

Add a labeled bottom Terminal bar spanning the agent canvas. Display the number of terminal sessions, with no misleading zero badge. Clicking anywhere in the bar outside its controls toggles the drawer. Opening an empty drawer creates its first terminal automatically. Show and hide it immediately without a slide animation. Opening an existing drawer selects the last-used terminal. Hiding preserves processes and restores prior agent focus. Persist height and visibility per worktree and device. Allow a terminal to move into a split when desired.

Keep destructive Close agent or Close terminal separate from Hide view. Existing CLI close semantics must not silently become non-destructive hide operations. The UI must make the target and consequence clear.

Validation: tab/split transitions, drag destinations, menu equivalence, session identity preservation, focus, window resizing, hidden-process survival, drawer empty state, and legacy split migration.

## 6. Update sidebar, Context, and completion presentation

Select whole worktrees in the sidebar. Use compact uppercase worktree headings with PR/MR and Git counts always visible on the same line. Show agent task names underneath with an 18-point indent, no provider icons, and the same status indicators as the tabs. Omit ordinary terminals from sidebar rows and counts. Apply one continuous selection highlight around the heading and all of its agents.

Clicking the heading, an agent line, or the group background selects the worktree and preserves its device-local tab selections, splits, and previous focus. Agent lines are informational children of the worktree, not separate selection or keyboard-navigation targets. Agent selection belongs to the workspace tabs and panes. PR/MR links and explicit action controls retain their own actions. Unassigned reports and reports on hidden shells stay on the worktree heading.

The accepted hierarchy and selection behavior are shown in [sidebar-worktree-selection.html](sidebar-worktree-selection.html). Earlier studies that select individual sidebar agents are superseded. An output-driven activity arc and folding after three agents remain proposals, not accepted implementation requirements.

When a child finishes, keep its tab in the same group and position, gray its label, and show a completion mark. Completion and parent cleanup must not replace the workspace, hide the tab strip, steal focus, or rearrange splits. Cleanup releases the live terminal while retaining the tab as a conversation reference. If the child was selected, its result and saved transcript occupy only that tab's existing pane; otherwise, the current terminal remains untouched. Indented sidebar agent rows use the same completed treatment without introducing agent-level selection.

Selecting a completed tab shows its result/transcript and an explicit Resume session action. Resume restarts the terminal and exact provider conversation when needed, in place in the same tab, then restores live styling after readiness. During launch, keep the record visible with a resuming state and prevent duplicate launches. Before cleanup, reuse a healthy live provider. Show finished-awaiting-cleanup, cleaned-up, and resume-failed states accurately. The experience is illustrated in [finished-agent-tabs.html](finished-agent-tabs.html).

Dismissing a finished tab only removes that device's presentation; retain results and conversation identity in Context, with a route to reopen and resume. A Close finished tabs action is a proposed convenience for accumulated records, not automatic eviction. Retained completed tabs do not count as live processes or pending obligations after acknowledgment.

Keep waiting for input, disconnected, failed, and finished awaiting cleanup distinct. Viewing a result must not acknowledge cleanup. Resume availability must reflect actual provider support and the saved conversation identifier. A transcript alone is insufficient. If the provider conversation or owning worktree is unavailable, retain the completed view and explain the recovery failure without inventing success or selecting another session.

Validation: whole-worktree selection from headings and agent lines without changing tab focus, narrow-width PR/Git visibility, attention on hidden tabs, completion while focused, archived-result retrieval, pending cleanup visibility, failed close, retained completed tabs across app restart, exact conversation resume after terminal cleanup, resume failure and retry, duplicate resume, cleanup racing resume, old completion delivery after relaunch, per-device dismissal/reopen, and reopening a worktree with no active agents.

## 7. Extend remote and mobile presentation

Publish additive agent/session metadata while preserving the complete legacy pane inventory. Negotiate lifecycle control capabilities and keep each viewer's workspace layout local. Share lifecycle state across clients while keeping selection and view layout local to each device. Opening an agent on iPhone must not rearrange the Mac.

On iPhone, use an agent picker and a bottom Terminal control above keyboard accessories and safe areas. Terminals open full-height with Back to agent. On iPad, use tab groups and a lower drawer when space allows. Retain menus for actions that also support drag or pointer gestures.

Older clients need a documented fallback inventory of sessions or an explicit unsupported-feature response; hidden tab sessions must not become unreachable. Audit the web client's exhaustive layout switches and retain its existing functionality even though this redesign primarily targets Mac and mobile. Ensure a legacy remote close cannot accidentally reinterpret a view operation as closing a different agent.

Validation: old/new host-client combinations, reconnect, session enumeration, exact targeting across relayed hosts, mobile keyboard/safe areas, rotation, VoiceOver, and independent Mac/mobile selection.

## Delivery order and checks

Build in this order: durable identity and cleanup; unified CLI and team skill; provider defaults and assets; tab/session ownership and drawer; sidebar/Context; mobile and compatibility. Each stage needs working behavior and its regression tests before the next depends on it. Keep incomplete UI behind a development gate until the end-to-end path works.

For each feature or changed behavior, follow the repository's RED/GREEN process. Find the existing requirement or create an EARS `@spec` in a real failing test before implementation. Promote inventory tests rather than duplicating IDs. Extend existing scoped numbering and keep corresponding type comments aligned.

Run focused tests while iterating, then `scripts/swiftpm test`. Regenerate `SPECS.md` with `scripts/generate-specs.py`; never edit it manually. Run `scripts/generate-specs.py --check` and `scripts/check-linux-test-allowlist.py`. Keep AppKit-only tests under the Apple test tree or guarded; do not expand the Linux pending allowlist. Run the affected mobile simulator suites through the repository's existing build/test setup and exercise both Claude and Codex integration paths.

The end-to-end acceptance scenario is a parent creating agents in both the same worktree and a new worktree, with one waiting for input, one failing, and the others completing. The parent receives exact completion events and closes completed children. Results remain accessible, worktree changes survive, the shell keeps running while hidden, and the final live process inventory contains only ongoing work while finished tabs remain as dimmed records. Select and resume a cleaned-up child in the same tab and exact provider conversation; verify that its prior result remains accessible and stale cleanup cannot stop the resumed assignment. Repeat with a parent restart and a mobile observer.

Before opening the PR, run `/code-review xhigh --fix` as required by AGENTS.md, apply findings, and rerun affected checks. Include the plan, regenerated specs, implementation, migration coverage, screenshots, and validation results in the PR. Record any unrelated failing checks or unverified hardware behavior explicitly.

## Implementation notes

The initial implementation uses one explicit completion policy for managed agents. `finish` records a result; `close --completion` ends that session after the parent handles it. Native end-of-turn hooks only update attention and waiting state. Ordinary closure or provider exit before completion records an interrupted or failed outcome for parent acknowledgment. Failed teardown preserves the live binding and diagnostic for retry. The initial implementation resumes only a still-live provider. The accepted follow-up design above extends resume to restart a terminal and restore the exact provider conversation after cleanup; this extension is not implemented yet.

Local compatibility forms (`pane add --agent` and `worktree add --agent`) now call the same agent lifecycle. The existing `worktree add --remote` command remains available for paired-host creation; the new `agent add` command currently targets its connected host. Remote Mac and mobile viewers receive the agent inventory, results, and device-local presentation. They can create ordinary terminals through existing host controls. New agent creation is available through the Mac menu or CLI.

Context shows bounded current and prior result previews on all clients. Local Mac Context also opens a bounded transcript preview. `agent list` returns paginated lifecycle summaries. `agent show <managed-id> --json` retrieves an immutable snapshot of the full retained record in bounded chunks. Full transcripts live in host-owned archive files and are omitted from routine state saves and remote/mobile snapshots. Stored results and transcripts are not truncated.

Existing saved Mac splits migrate in place. Known manually started providers gain a provider identity when their next session-start hook binds the terminal, without moving that view. Native subagents are excluded. New managed agents join tabs, and new shells enter the terminal drawer.

Review fixes also scope zoom and spatial navigation to the visible device-local layout, retain visited iPad tab renderers while their workspace is active, and keep tab controls available while a terminal attachment loads. Hidden tabs and closed drawers do not become visible when the app or worktree is restored.
