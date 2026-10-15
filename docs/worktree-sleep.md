# Worktree sleep infrastructure (draft)

This draft adds automatic suspension for verified idle local system zsh worktrees. It does not yet complete automatic sleep for Claude or Codex panes. Both provider adapters report known busy work and otherwise keep activity unknown. The [provider evidence](worktree-sleep-provider-evidence.md) records the installed-version limits and the observer integration needed next.

Automatic sleep is off by default. In Settings, enable **Automatically sleep idle system zsh worktrees** and choose an inactivity duration (15 minutes by default). Right-click a worktree and choose **Keep Awake** to exclude it. A moon indicates a sleeping worktree. Opening it resumes its existing processes and terminal sessions.

Eligibility requires newly spawned macOS `/bin/zsh` sessions with Graftty shell hooks and a verified primary input prompt. Existing sessions without the new marker, other shells, hook-disabled zsh, and shells with unsupported plugins, completion callbacks, traps, timers, or scheduling stay awake. The owned hooks invalidate evidence before command execution; a quiet builtin `read` or nested `vared` input cannot qualify. Input must return to a fresh primary prompt before the pane can qualify again. This also keeps partially typed input awake until a new prompt acknowledges it. After the GUI restarts, an existing session must reach a new primary prompt before it can qualify.

The hooks use zsh's [line-init and line-finish boundaries](https://zsh.sourceforge.io/Doc/Release/Zsh-Line-Editor.html). Process identity, prompt timestamp, and a boundary newer than the last Graftty input prevent stale prompt evidence from authorizing sleep after failed marker writes. These boundaries are necessary because foreground terminal ownership and low CPU alone do not prove a shell is waiting for a command.

Every pane must have no viewer, active job, unknown provider evidence, or registered background dependency. Graftty checks exact process identities and sustained low CPU and disk activity. A quiet monitor, watcher, server, build, or agent remains awake through its process tree, busy prompt boundary, or unsupported callback registration. Previously observed children remain associated with their worktree after reparenting until their exact identity exits. An unobserved detached process outside the suspension set is left running; command history alone does not permanently disqualify its former shell.

For a known task that will detach, register its lifetime while it is still a verified pane descendant:

```sh
graftty worktree keep-awake --pid <task-pid>
```

Registration expires when that exact task exits or its PID is reused. Missing identity data keeps the worktree awake. Use the worktree's **Keep Awake** override for dependencies whose lifetime cannot be registered.

Only verified pane shell processes receive SIGSTOP. Graftty, zmx daemons, provider daemons, and unrelated processes are excluded. Suspension preserves process and terminal state and mainly reduces CPU use; it does not reclaim application memory. Renderer eviction uses the existing terminal surface budget mechanism and preserves zmx sessions.

Wake admission precedes input, selection, terminal attachment, CLI pane control, and native team-message delivery. Remote viewers request wake from the host; they do not signal processes on another Mac. A failed resume defers the interaction. Suspension ownership is journaled before signaling, and an independent bundled helper resumes those identities after the GUI exits or crashes. A later GUI recovers orphan journals after their owner and helper have exited.

An externally stopped or hung recovery helper retains its journal ownership to prevent two recoverers from resuming the same process. New suspension is blocked when its heartbeat is stale. Recovery in that exceptional case requires the helper to resume or exit; this draft does not implement a coordinated takeover protocol. Development runs without the bundled helper cannot automatically suspend worktrees.

Validation covers injected process identities and signals, wake races, partial failures, unknown activity, task lifetime, remote admission, renderer eviction, and isolated real SIGSTOP/SIGCONT and helper recovery. Tests do not suspend live agents. An end-to-end interactive macOS sleep/wake trial and useful automatic provider sleep remain pending before this feature can be considered complete.
