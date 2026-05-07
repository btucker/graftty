# Team Inbox Hooks Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the first working Team Inbox Hooks vertical slice: durable addressed messages, hook delivery output, revised CLI, wrapper generation, and Stop attention/notification plumbing.

**Architecture:** Add focused `GrafttyKit/Teams` units for inbox storage, hook rendering, hook asset generation, and agent notification payloads. Extend the existing control socket message enum for team send/broadcast/hook requests, then keep the app-side mutations in `GrafttyApp` close to the current team request handling. Reuse `WorktreeEntry.attention` for v1 Stop sidebar attention and add a small app-level notification service for clickable desktop notifications.

**Tech Stack:** Swift 5.10, ArgumentParser, XCTest/Swift Testing, JSONL files, existing Unix-domain socket control protocol, `UNUserNotificationCenter`.

---

### Task 1: Team Inbox Storage

**Files:**
- Create: `Sources/GrafttyKit/Teams/TeamInbox.swift`
- Test: `Tests/GrafttyKitTests/Teams/TeamInboxTests.swift`

- [ ] **Step 1: Write failing tests** for appending point-to-point messages, broadcast batch IDs, reading by recipient/priority since a cursor, and diagnostic reads not mutating cursors.
- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter TeamInboxTests`

- [ ] **Step 3: Implement `TeamInbox`** with `TeamInboxMessage`, `TeamInboxPriority`, `TeamInboxEndpoint`, `TeamInboxCursor`, append/read cursor/watermark helpers, and monotonic ID generation.
- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter TeamInboxTests`

- [ ] **Step 5: Commit**

```bash
git add Sources/GrafttyKit/Teams/TeamInbox.swift Tests/GrafttyKitTests/Teams/TeamInboxTests.swift
git commit -m "feat: add team inbox storage"
```

### Task 2: Hook Output Rendering

**Files:**
- Create: `Sources/GrafttyKit/Teams/TeamHookRenderer.swift`
- Test: `Tests/GrafttyKitTests/Teams/TeamHookRendererTests.swift`

- [ ] **Step 1: Write failing tests** for Codex SessionStart additional context, Codex PostToolUse urgent-only context, Codex Stop normal-message context, and untrusted peer labeling.
- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter TeamHookRendererTests`

- [ ] **Step 3: Implement renderer** as pure functions returning JSON strings for Codex and Claude hook responses.
- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter TeamHookRendererTests`

- [ ] **Step 5: Commit**

```bash
git add Sources/GrafttyKit/Teams/TeamHookRenderer.swift Tests/GrafttyKitTests/Teams/TeamHookRendererTests.swift
git commit -m "feat: render team hook context"
```

### Task 3: CLI And Socket Requests

**Files:**
- Modify: `Sources/GrafttyKit/Notification/NotificationMessage.swift`
- Modify: `Sources/GrafttyCLI/Team.swift`
- Modify: `Sources/GrafttyCLI/CLI.swift`
- Test: `Tests/GrafttyKitTests/Teams/TeamCLITests.swift`
- Test: `Tests/GrafttyKitTests/Notification/NotificationMessageTests.swift`

- [ ] **Step 1: Write failing tests** for new socket payloads: `team_send`, `team_broadcast`, `team_hook`, and `team_inbox`.
- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter TeamCLITests --filter NotificationMessageTests`

- [ ] **Step 3: Implement CLI commands**: `send`, `broadcast`, `members`, `hook`, and `inbox` diagnostics. Keep old `msg`/`list` as compatibility aliases if cheap.
- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter TeamCLITests --filter NotificationMessageTests`

- [ ] **Step 5: Commit**

```bash
git add Sources/GrafttyKit/Notification/NotificationMessage.swift Sources/GrafttyCLI/Team.swift Sources/GrafttyCLI/CLI.swift Tests/GrafttyKitTests/Teams/TeamCLITests.swift Tests/GrafttyKitTests/Notification/NotificationMessageTests.swift
git commit -m "feat: expand team CLI for inbox hooks"
```

### Task 4: App-Side Team Request Handling

**Files:**
- Modify: `Sources/Graftty/GrafttyApp.swift`
- Test: `Tests/GrafttyKitTests/Teams/TeamCLITests.swift`

- [ ] **Step 1: Write failing tests** for pure request helper behavior where possible: recipient resolution, sender exclusion on broadcast, and not-in-team errors.
- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter TeamCLITests`

- [ ] **Step 3: Implement request handling** for inbox-backed send/broadcast/hook/diagnostic requests. Preserve existing channel `team_message` dispatch for live Claude channel subscribers while writing to the inbox.
- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter TeamCLITests`

- [ ] **Step 5: Commit**

```bash
git add Sources/Graftty/GrafttyApp.swift Tests/GrafttyKitTests/Teams/TeamCLITests.swift
git commit -m "feat: route team inbox requests"
```

### Task 5: Hook Wrappers

**Files:**
- Create: `Sources/GrafttyKit/Teams/AgentHookInstaller.swift`
- Test: `Tests/GrafttyKitTests/Teams/AgentHookInstallerTests.swift`

- [ ] **Step 1: Write failing tests** for idempotent wrapper generation, marker repair, wrapper PATH search skipping the generated bin directory, and generated Claude settings containing Graftty hooks.
- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter AgentHookInstallerTests`

- [ ] **Step 3: Implement wrapper generation** under Application Support, plus pure content builders testable without touching real home config.
- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter AgentHookInstallerTests`

- [ ] **Step 5: Commit**

```bash
git add Sources/GrafttyKit/Teams/AgentHookInstaller.swift Tests/GrafttyKitTests/Teams/AgentHookInstallerTests.swift
git commit -m "feat: generate team hook wrappers"
```

### Task 6: Stop Attention And Desktop Notification Payloads

**Files:**
- Create: `Sources/GrafttyKit/Teams/AgentStopNotification.swift`
- Modify: `Sources/GrafttyKit/Notification/NotificationMessage.swift`
- Modify: `Sources/Graftty/GrafttyApp.swift`
- Test: `Tests/GrafttyKitTests/Teams/AgentStopNotificationTests.swift`

- [ ] **Step 1: Write failing tests** for notification title/body/userInfo payload and timestamp-matched acknowledgement.
- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter AgentStopNotificationTests`

- [ ] **Step 3: Implement Stop handling**: hook Stop request sets `WorktreeEntry.attention`, emits a desktop notification payload, and selection of that worktree clears matching attention.
- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter AgentStopNotificationTests`

- [ ] **Step 5: Commit**

```bash
git add Sources/GrafttyKit/Teams/AgentStopNotification.swift Sources/GrafttyKit/Notification/NotificationMessage.swift Sources/Graftty/GrafttyApp.swift Tests/GrafttyKitTests/Teams/AgentStopNotificationTests.swift
git commit -m "feat: notify when agents need input"
```

### Task 7: Full Verification

**Files:**
- Modify: `SPECS.md` if implementation reserves new requirement IDs.

- [ ] **Step 1: Run targeted test suite**

Run: `swift test --filter TeamInboxTests --filter TeamHookRendererTests --filter TeamCLITests --filter AgentHookInstallerTests --filter AgentStopNotificationTests`

- [ ] **Step 2: Run full package tests**

Run: `swift test`

- [ ] **Step 3: Run git diff review**

Run: `git diff --stat HEAD~6..HEAD`

