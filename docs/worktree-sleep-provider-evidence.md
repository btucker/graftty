# Provider evidence for worktree sleep

Research date: 2026-10-05. Provider implementation: `29bd6eda6e7c7e23be6bb8e3354a62d44f8c0160`.

The current adapters establish known busy work and otherwise return `unknown`. Neither adapter certifies full idle. Safe suspension remains unresolved for ordinary wrapped Claude and Codex sessions. This evidence does not establish that a future integration is impossible.

## Installed versions and provenance

The investigation used Claude Code 2.1.289 and Codex CLI 0.160.0 on macOS. It inspected local executables and generated protocol types, and browsed official documentation. No existing provider session received a query, prompt, suspension, or other process signal. The runtime probe started and closed its own isolated Codex server without sending a model turn.

| Executable | SHA-256 |
| --- | --- |
| `~/.local/share/claude/versions/2.1.289` | `03d66745e3bb69ec727d66023696f3820bc0a00a8a5ba725eb6706d0c67cbe69` |
| `~/.bun/install/global/node_modules/@openai/codex-darwin-arm64/vendor/aarch64-apple-darwin/bin/codex` | `112fae7a5a1223e673c8a1791d32338f37df8b527ff1159bb8adac6c4dbf1b4b` |

Claude findings below come from readable JavaScript embedded in the installed Bun executable. They are version-specific implementation observations, not a published compatibility promise. To reproduce the extraction, split the executable bytes on NUL, retain chunks containing `// Version: 2.1.289`, decode as UTF-8, and join with newlines. Search within the corresponding module: minified names can repeat across modules. The extraction contains proprietary source and is not committed here.

Codex protocol types came from the installed native executable:

```sh
codex_native="$HOME/.bun/install/global/node_modules/@openai/codex-darwin-arm64/vendor/aarch64-apple-darwin/bin/codex"
"$codex_native" app-server generate-ts --experimental --out /tmp/graftty-sleep-codex-protocol
```

Relevant files are `ClientRequest.ts`, `ServerNotification.ts`, and `v2/Thread.ts`, `ThreadListParams.ts`, `ThreadSourceKind.ts`, `ThreadStatus.ts`, `ThreadGoalStatus.ts`, and `ServerDiagnosticsResponse.ts`.

## Claude's later notification has incomplete coverage

The official [Notification hook reference](https://code.claude.com/docs/en/hooks#notification) describes `idle_prompt` after a completed response and a delay without typing. Background agents and usage-limit waits suppress that notification. The [Stop input reference](https://code.claude.com/docs/en/hooks#stop-input) describes optional `background_tasks` and `session_crons` registries. Cron entries include `CronCreate`, `ScheduleWakeup`, and `/loop`. `stop_hook_active` identifies Stop-hook continuation. Those documented fields support conservative busy reporting.

Installed 2.1.289 narrows the actual notification gate:

- Class `Jj` observes turn loading, submit count, completion time, user interaction, dialogs, pending loop wakeups, and quota auto-resume.
- Its `backgroundAgents` snapshot calls `HGr`. That function considers `local_agent`, `remote_agent`, `in_process_teammate`, and `local_workflow`, with further exclusions for completed, paused, idle, or certain remote tasks.
- `local_bash`, `monitor_mcp`, `monitor_ws`, `mcp_task`, `dream`, `auto_mode_scan`, and `local_memory_import` are outside that task-type set.
- `hasPendingLoopWakeup` calls `bhe`, whose predicate is `tb().some(e => e.kind === "loop")`. This predicate does not cover arbitrary session cron entries.
- Stop generator `are` builds `background_tasks` through `T2t` and `session_crons` through `E2t` before yielding hook execution. `T2t` filters the registry for pending or running background tasks. `E2t` maps the session cron registry.

Consequently, an empty Stop snapshot followed by `idle_prompt` does not provide a fresh complete registry snapshot. Hook continuation, post-turn reactions, or internal work can invalidate the older snapshot. The installed post-turn path calls the auto-dream runner `Mho` without awaiting it. That runner can register a running `dream` task through `te`; `HGr` does not consider that task type. This is a concrete callback-coverage gap. The investigation did not execute auto-dream or demonstrate a particular notification race at runtime.

An assistant transcript message also lacks a complete post-hook registry boundary. `TeammateIdle` occurs before the teammate becomes idle and can be blocked. Neither supplies the missing confirmation.

### An owned Claude stream is a feasible next investigation

The installed SDK schema includes `system/background_tasks_changed` with replace semantics for the full live background task set. Its schema describes membership-change notifications and a snapshot after repeated initialization of an already-running process. The implementation emits changes from the task registry. This is stronger than reconstructing tasks from start and completion edges, but it is an installed protocol observation. The official [SDK streaming documentation](https://code.claude.com/docs/en/agent-sdk/streaming-output) provides the broader stream and final-result model; it does not promise this complete scheduling contract.

A future adapter can own the SDK process and continuously observe that level signal, turn results, tool events, and Stop registries. It still needs complete cron change coverage, reconnect semantics, and proof that all autonomous task categories invalidate idle before starting. Existing TUI peer messaging has no verified documented read-only full task and cron snapshot. Attaching to that endpoint does not provide an equivalent owned stream. The SDK control request named `background_tasks` backgrounds foreground work; it is not a read query and was not sent.

## Codex has descendant discovery, including a separate memory view

The official [app-server reference](https://learn.chatgpt.com/docs/app-server) documents stored thread pagination, ancestor filters, loaded IDs, read queries, and ephemeral threads. The installed types provide more exact constraints:

- `ancestorThreadId` returns spawned descendants at any depth, excluding the root. `parentThreadId` selects direct children. The filters are mutually exclusive and require experimental API access.
- `archived: true` selects archived threads. False or null selects nonarchived threads, so both passes are necessary.
- Omitted or empty `sourceKinds` defaults to interactive sources. A discovery adapter must explicitly include all supported source kinds, including subagents.
- `Thread` includes `id`, `parentThreadId`, `sessionId`, `ephemeral`, runtime `status`, and `cwd`. Exact identity comes from these fields, not cwd matching or historical collaboration items.
- `thread/loaded/list` exposes in-memory IDs. Stored ancestor listings alone cannot establish complete ephemeral visibility.

The earlier implementation comment that Codex lacks a complete subagent read API is too broad. These APIs support a concrete traversal candidate. What remains unproved is a complete, fresh observation of the tree and every kind of work across that tree.

### Isolated ephemeral probe

The probe used a fresh temporary `CODEX_HOME`, removed `OPENAI_API_KEY` and `CODEX_API_KEY`, and ran the native executable with `app-server --listen stdio://`. It initialized with `capabilities.experimentalApi = true` and sent `initialized`. It then sent `thread/start` with a temporary cwd, `approvalPolicy: "never"`, `sandbox: "read-only"`, and `ephemeral: true`. No `turn/start` was sent.

The server launch can be reproduced with the native path above and a new temporary directory:

```sh
probe_root=$(mktemp -d /tmp/graftty-codex-idle.XXXXXX)
mkdir "$probe_root/home"
env -u OPENAI_API_KEY -u CODEX_API_KEY CODEX_HOME="$probe_root/home" \
	"$codex_native" app-server --listen stdio://
```

For returned thread ID `T`, these RPCs produced the following results:

| RPC and parameters | Observed 0.160.0 result |
| --- | --- |
| `thread/start` as above | Exact thread `T`, `ephemeral: true`, `status.type: "idle"`, root `sessionId: T`, null parent, null persisted path |
| `thread/read {threadId:T, includeTurns:false}` | Exact thread `T`, idle runtime status, null parent, session ID `T`, empty turns |
| `thread/read {threadId:T, includeTurns:true}` | Error `-32600`: ephemeral threads do not support includeTurns |
| `thread/loaded/list {}` | `data: [T]`, null next cursor |
| `thread/list` with all ten installed `sourceKinds`, no ancestor filter | Empty data, null next cursor |
| `thread/list {ancestorThreadId:T, sourceKinds:["subAgent","subAgentReview","subAgentCompact","subAgentThreadSpawn","subAgentOther"]}` | Empty data, null next cursor |
| `thread/backgroundTerminals/list {threadId:T}` | Empty data, null next cursor |
| `thread/goal/get {threadId:T}` | Error `-32600`: ephemeral thread does not support goals |
| `thread/queue/list {threadId:T}` | Error `-32600`: ephemeral thread does not support queued submissions |

The unfiltered stored listing omitted the ephemeral root while the loaded listing included it. The ancestor listing intentionally excludes the root, so its empty result alone does not demonstrate that omission. No descendant was spawned; complete traversal and pagination races were not runtime-tested.

To repeat the RPC sequence, write one JSON object per line to the isolated stdio server. Requests have `id`, `method`, and `params`. Match responses by `id` while retaining asynchronous notifications. Substitute the returned `T` and temporary cwd. Closing stdin exits the owned test server. Use `sandbox: "read-only"`, not `"readOnly"`; the latter was rejected in the initial probe.

### Remaining Codex observation gaps

A traversal candidate must page both stored ancestor listings and all loaded IDs, read exact parent relationships, and join parent chains to the root. It must include archived and ephemeral descendants, detect cycles and missing links, and handle list changes during the query. Each related thread needs fresh runtime status, terminal visibility, goals, queued submissions, and active task or turn visibility. Unsupported ephemeral history, goal, and queue methods require explicit version-scoped capability handling, never an empty-array fallback.

The current query does not implement that complete traversal. It reads the exact root, terminals, goal, queue, and last-known collaboration states. An empty terminal list cannot certify idle. The query writes no provider metadata, so its immutable return value must be discarded by the caller if identity or hook generation changed while it ran.

The installed request schema has no read-only `thread/subscribe` method or atomic snapshot generation spanning these registries. `thread/read` does not itself establish continuous observation. The [Scheduled tasks documentation](https://learn.chatgpt.com/docs/automations) says the CLI lacks the schedule-management interface. That UI limit is not proof that a daemon or connected host cannot arrange later work. The investigation did not verify complete notifications for scheduling, remote inputs, MCP event streams, or internal background work.

## Process identities and the next owned broker

`TeamPresenceRecord` stores one PID and process start time, provider session identity, pane, and optional transport. Those fields identify a registered process; they do not certify every descendant. Claude's session binder also uses the exact peer endpoint and process identity to reject stale logical sessions after `/clear`.

`CodexAppServerSessionRecord` separately stores the daemon PID and start time, owner PID and start time, socket, native binary, pane, and bound thread. The installed Graftty wrapper registers its shell `$$` as owner and the daemon's `$!` as app-server PID. It starts the TUI through a separate launcher but does not store a separate TUI PID. Executable-name or command-line pattern guesses cannot supply that missing ownership evidence. This change does not expand PID ownership.

A future broker can launch and own the daemon and clients, mediate all input, and retain a persistent event stream from process start. It can assign a monotonic generation to task, tree, goal, queue, scheduling, input, and connection changes. Each candidate idle result needs the exact session and process identities, generation, covered capabilities, and query interval. The coordinator must reject the result after any newer event, identity change, gap, timeout, or unsupported category.

That design also needs a fence around the final suspension decision: sequential read queries alone cannot prevent work starting after the last read. An owned input broker can wake before forwarding input, but internal timers and provider-created work still need authoritative observation or an explicit provider quiescence protocol. Capability exclusions must be enforced and verified for the owned runtime. A documentation omission cannot establish an exclusion.

The present change records these limits and leaves idle disabled. A later broker or SDK integration needs isolated tests of descendant creation and closure, reconnect snapshots, task membership, goal continuation, queue dispatch, scheduled continuation, and generation invalidation before practical agent eligibility can be claimed.
