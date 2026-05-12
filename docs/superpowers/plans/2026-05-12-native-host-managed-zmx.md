# Native Host-Managed zmx Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace native pane `initial_input` zmx bootstrapping with a host-managed libghostty surface backed by a Graftty-owned `zmx attach` PTY client.

**Architecture:** When zmx is available, `SurfaceHandle` creates a `GHOSTTY_SURFACE_IO_BACKEND_HOST_MANAGED` surface and owns a native PTY session that spawns `zmx attach <session> <wrapped-user-shell>`. When zmx is unavailable, `SurfaceHandle` keeps the existing direct-shell Ghostty exec fallback. zmx remains the durable session layer; Graftty owns only the short-lived attach client.

**Tech Stack:** Swift 5.10, Swift Testing, AppKit, GhosttyKit C API, Darwin PTY APIs, existing `PtyProcess`, existing `ZmxLauncher`, existing `AgentHookInstaller`.

---

## File Structure

- Create `Sources/GrafttyKit/Zmx/ZmxSpawnConfiguration.swift`
  - Pure GrafttyKit value type and builder for native zmx attach argv/env.
  - Extracts shell wrapping and zsh integration env from the current text bootstrap path.
- Create `Tests/GrafttyKitTests/Zmx/ZmxSpawnConfigurationTests.swift`
  - Unit tests for argv/env construction and inherited env stripping.
- Create `Sources/Graftty/Terminal/NativePtySession.swift`
  - App-target native PTY bridge from `PtyProcess` to libghostty host-managed callbacks.
- Create `Tests/GrafttyTests/Terminal/NativePtySessionTests.swift`
  - PTY tests using injectable output/exit closures.
- Create `Sources/Graftty/Terminal/HostManagedZmxBackend.swift`
  - Owns C callback userdata, `NativePtySession`, and the production callback mapping between Ghostty and the PTY session.
- Create `Tests/GrafttyTests/Terminal/HostManagedZmxBackendTests.swift`
  - Unit tests for callback forwarding and session ownership without a real Ghostty surface.
- Create or modify `Tests/GrafttyTests/Terminal/SurfaceHandleHostManagedTests.swift`
  - Tests a `SurfaceHandle` config-capture seam that proves host-managed backend fields are set and `command`/`initial_input` are nil.
- Create or modify `Tests/GrafttyKitTests/Zmx/ZmxNativeHostManagedIntegrationTests.swift`
  - Scoped `/tmp/zmx-*` integration tests for attach/detach/reattach/kill and inherited env isolation.
- Modify `Sources/Graftty/Terminal/SurfaceHandle.swift`
  - Remove `zmxInitialInput`.
  - Add optional `ZmxSpawnConfiguration`.
  - Configure host-managed backend when configuration is present.
  - Start `NativePtySession` only after `ghostty_surface_new` succeeds.
- Modify `Sources/Graftty/Terminal/TerminalManager.swift`
  - Replace `resolveZmxSpawn` with `resolveZmxSpawnConfiguration`.
  - Pass configuration into `SurfaceHandle`.
  - Keep zmx unavailable fallback.
- Modify `Sources/GrafttyKit/Zmx/ZmxLauncher.swift`
  - Remove `attachInitialInput` and zsh shell-prefix helpers after replacement.
  - Keep `attachArgv`, `attachCommand` only if still used by tests/integration helpers.
- Modify `Tests/GrafttyKitTests/Zmx/ZmxLauncherTests.swift`
  - Delete tests for `attachInitialInput`.
  - Keep session naming, `attachArgv`, env stripping, list parsing, kill.
- Modify `Tests/GrafttyTests/Specs/ZmxTodo.swift`
  - Revise all affected ZMX expectations to host-managed native I/O, including ZMX-4.1, ZMX-4.4, ZMX-6.2, ZMX-6.3, and ZMX-6.4.
- Possibly modify `SPECS.md`
  - Replace native bootstrap wording in §13 with host-managed requirements from the design spec.

## Task 1: Structured zmx Spawn Configuration

**Files:**
- Create: `Sources/GrafttyKit/Zmx/ZmxSpawnConfiguration.swift`
- Create: `Tests/GrafttyKitTests/Zmx/ZmxSpawnConfigurationTests.swift`
- Modify: `Sources/GrafttyKit/Zmx/ZmxLauncher.swift`

- [ ] **Step 1: Write failing tests for argv and required env**

Add tests covering:

```swift
@Test func buildsAttachArgvForWrappedShell() throws {
    let launcher = ZmxLauncher(executable: URL(fileURLWithPath: "/tmp/zmx"),
                               zmxDir: URL(fileURLWithPath: "/tmp/zmx-dir"))
    let config = ZmxSpawnConfiguration.make(
        launcher: launcher,
        paneID: UUID(uuidString: "DEADBEEF-0000-0000-0000-000000000000")!,
        worktreePath: "/repo/wt",
        socketPath: "/tmp/graftty.sock",
        processEnv: ["SHELL": "/bin/zsh", "PATH": "/usr/bin", "ZMX_SESSION": "old"],
        bundleURL: URL(fileURLWithPath: "/Applications/Graftty.app"),
        ghosttyResourcesDir: "/Applications/Ghostty.app/Contents/Resources/ghostty",
        agentHooksDisabled: false,
        agentHooksRoot: URL(fileURLWithPath: "/tmp/hooks")
    )

    #expect(config.sessionName == "graftty-deadbeef")
    #expect(config.argv.first == "/tmp/zmx")
    #expect(config.argv[1...2] == ["attach", "graftty-deadbeef"])
    #expect(config.env["ZMX_DIR"] == "/tmp/zmx-dir")
    #expect(config.env["GRAFTTY_SOCK"] == "/tmp/graftty.sock")
    #expect(config.env["ZMX_SESSION"] == nil)
    #expect(config.workingDirectory.path == "/repo/wt")
}
```

Also add focused tests for:

- zsh env includes `ZDOTDIR=<ghostty resources>/shell-integration/zsh`.
- zsh env includes `GHOSTTY_ZSH_ZDOTDIR=<agent hook zsh init dir>` when hooks are enabled.
- bash uses `AgentHookInstaller.wrappedUserShell(...)`.
- disabled hooks use raw `SHELL`.
- missing Ghostty resources omit `ZDOTDIR`/`GHOSTTY_ZSH_ZDOTDIR`.

- [ ] **Step 2: Run tests and verify RED**

Run:

```bash
swift test --filter ZmxSpawnConfigurationTests
```

Expected: fails because `ZmxSpawnConfiguration` does not exist.

- [ ] **Step 3: Implement minimal `ZmxSpawnConfiguration`**

Create the value type in GrafttyKit. Keep dependencies pure Foundation/GrafttyKit only. Do not import GhosttyKit or AppKit.

Implementation notes:

- `sessionName = launcher.sessionName(for: paneID)`.
- Start env from `launcher.subprocessEnv(from: processEnv)`.
- Add `GRAFTTY_SOCK`.
- Compute sanitized `PATH` with `BundlePathSanitizer.sanitized(...)`.
- When hooks enabled, prepend `AgentHookInstaller.binDirectory(rootDirectory:)`.
- When hooks enabled, set `GRAFTTY_AGENT_HOOKS_BIN`.
- Compute shell:
  - raw shell = `processEnv["SHELL"] ?? "/bin/sh"`.
  - wrapped shell = `AgentHookInstaller.wrappedUserShell(rawShell, rootDirectory:)` unless hooks disabled.
- `argv = launcher.attachArgv(sessionName:userShell:)`.
- `workingDirectory = URL(fileURLWithPath: worktreePath, isDirectory: true)`.

- [ ] **Step 4: Run tests and verify GREEN**

Run:

```bash
swift test --filter ZmxSpawnConfigurationTests
swift test --filter ZmxLauncherUnitTests
```

Expected: all selected tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/GrafttyKit/Zmx/ZmxSpawnConfiguration.swift Tests/GrafttyKitTests/Zmx/ZmxSpawnConfigurationTests.swift Sources/GrafttyKit/Zmx/ZmxLauncher.swift
git commit -m "feat(zmx): add structured native spawn configuration"
```

## Task 2: Native PTY Session Bridge

**Files:**
- Create: `Sources/Graftty/Terminal/NativePtySession.swift`
- Create: `Tests/GrafttyTests/Terminal/NativePtySessionTests.swift`

- [ ] **Step 1: Write failing PTY bridge tests**

Add tests with injectable callbacks, not a real `ghostty_surface_t`:

```swift
@Test func forwardsChildOutputToSurfaceSink() throws {
    var chunks: [Data] = []
    let session = NativePtySession(
        argv: ["/bin/sh", "-c", "echo hello; sleep 0.2"],
        env: [:],
        workingDirectory: nil,
        writeToSurface: { chunks.append($0) },
        processExited: { _, _ in }
    )
    try session.start()
    defer { session.close() }
    try waitUntil { String(data: chunks.reduce(Data(), +), encoding: .utf8)?.contains("hello") == true }
}
```

Also add tests for:

- `write(_:)` reaches child stdin.
- `resize(cols:rows:)` changes `stty size`.
- `close()` is idempotent.
- process exit callback fires exactly once.
- spawn failure calls the failure path once and never leaves a live fd behind.

- [ ] **Step 2: Run tests and verify RED**

Run:

```bash
swift test --filter NativePtySessionTests
```

Expected: fails because `NativePtySession` does not exist.

- [ ] **Step 3: Implement `NativePtySession`**

Implementation notes:

- Use `PtyProcess.spawn(argv:env:currentDirectory:initialSize:)`.
- Protect `spawned`, callbacks, and `isClosed` with `NSLock`.
- Reader thread loops on `read(masterFD)`, emits nonempty chunks, then calls exit once.
- `write(_:)` uses `SocketIO.writeAll`.
- `resize(cols:rows:)` calls `PtyProcess.resize`.
- Expose an injectable spawner closure for tests so spawn failure can be forced without relying on invalid local binaries.
- `close()`:
  - idempotently marks closed
  - nils callbacks under lock
  - sends SIGTERM to the child
  - closes master fd
  - bounded nonblocking `waitpid`
- Provide a production convenience initializer that accepts a `ghostty_surface_t` and maps closures to `ghostty_surface_write_buffer` and `ghostty_surface_process_exit`.

- [ ] **Step 4: Run tests and verify GREEN**

Run:

```bash
swift test --filter NativePtySessionTests
swift test --filter PtyProcessTests
```

Expected: all selected tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/Graftty/Terminal/NativePtySession.swift Tests/GrafttyTests/Terminal/NativePtySessionTests.swift
git commit -m "feat(terminal): add native pty session bridge"
```

## Task 3: Host-Managed zmx Backend Adapter

**Files:**
- Create: `Sources/Graftty/Terminal/HostManagedZmxBackend.swift`
- Create: `Tests/GrafttyTests/Terminal/HostManagedZmxBackendTests.swift`

- [ ] **Step 1: Write failing callback adapter tests**

Add tests that instantiate the backend with a fake session object or closure sink:

```swift
@Test func receiveBufferCallbackForwardsInputBytes() throws {
    var writes: [Data] = []
    let backend = HostManagedZmxBackend.testing(
        write: { writes.append($0) },
        resize: { _, _ in },
        close: {}
    )

    var bytes = Array("abc".utf8)
    bytes.withUnsafeBufferPointer { ptr in
        HostManagedZmxBackend.receiveBufferCallback(
            backend.userdata,
            ptr.baseAddress,
            ptr.count
        )
    }

    #expect(writes == [Data("abc".utf8)])
}
```

Also test:

- resize callback forwards cols/rows.
- callbacks ignore nil userdata/pointers.
- `close()` is idempotent and closes the owned session once.

- [ ] **Step 2: Run tests and verify RED**

Run:

```bash
swift test --filter HostManagedZmxBackendTests
```

Expected: fails because `HostManagedZmxBackend` does not exist.

- [ ] **Step 3: Implement `HostManagedZmxBackend`**

Implementation notes:

- Keep `NativePtySession` process ownership inside this adapter, not in `SurfaceHandle`.
- Expose static C callbacks:
  - `receiveBufferCallback`
  - `receiveResizeCallback`
- Store an `Unmanaged.passRetained` userdata pointer if needed; release exactly once in `deinit`.
- Provide `configure(_ config: inout ghostty_surface_config_s)` that sets:
  - `backend = GHOSTTY_SURFACE_IO_BACKEND_HOST_MANAGED`
  - `receive_userdata`
  - `receive_buffer`
  - `receive_resize`
- Provide `start(surface:) throws`.
- If `start(surface:)` throws, caller handles diagnostic/exit convergence.

- [ ] **Step 4: Run tests and verify GREEN**

Run:

```bash
swift test --filter HostManagedZmxBackendTests
```

Expected: all selected tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/Graftty/Terminal/HostManagedZmxBackend.swift Tests/GrafttyTests/Terminal/HostManagedZmxBackendTests.swift
git commit -m "feat(terminal): add host-managed zmx backend"
```

## Task 4: Host-Managed Surface Cutover

**Files:**
- Modify: `Sources/Graftty/Terminal/SurfaceHandle.swift`
- Modify: `Sources/Graftty/Terminal/TerminalManager.swift`
- Modify: `Tests/GrafttyTests/Specs/ZmxTodo.swift`
- Modify: `Tests/GrafttyKitTests/Zmx/ZmxLauncherTests.swift`
- Create or modify: `Tests/GrafttyTests/Terminal/SurfaceHandleHostManagedTests.swift`

- [ ] **Step 1: Write failing tests for the Ghostty config boundary**

Add a `SurfaceHandle` test seam that can capture the `ghostty_surface_config_s` passed to `ghostty_surface_new` without creating a real surface. The test may use a small injectable factory closure on `SurfaceHandle` or a dedicated `SurfaceFactory` value.

Test required behavior:

```swift
@Test func zmxAvailableUsesHostManagedBackendWithoutCommandOrInitialInput() throws {
    let captured = try SurfaceHandleTestHarness.captureConfig(
        zmxSpawnConfiguration: .fixture()
    )

    #expect(captured.backend == GHOSTTY_SURFACE_IO_BACKEND_HOST_MANAGED)
    #expect(captured.receive_userdata != nil)
    #expect(captured.receive_buffer != nil)
    #expect(captured.receive_resize != nil)
    #expect(captured.command == nil)
    #expect(captured.initial_input == nil)
}
```

Also test direct-shell fallback:

- nil zmx config does not set host-managed backend.
- nil zmx config can still set `extraInitialInput` for editor panes.

Also test zmx-backed editor pane input:

- non-nil zmx config does not set `initial_input`.
- non-nil zmx config queues or writes `extraInitialInput` through `NativePtySession` after backend start.

- [ ] **Step 2: Write failing start-failure convergence test**

Add a test that injects a `HostManagedZmxBackend` whose `start(surface:)` throws after fake surface creation. Assert `SurfaceHandle`:

- writes a short diagnostic to the surface sink if the seam can observe it, or records the diagnostic call through an injected closure.
- reports process exit exactly once with nonzero status.
- does not crash and does not leave a retained backend running.

- [ ] **Step 3: Write failing spec checks for no bootstrap**

Update generated spec inventory and spec tests so affected ZMX entries expect the new model:

- native zmx panes use host-managed backend
- zmx-backed native panes do not set `command`
- zmx-backed native panes do not set `initial_input`
- app quit closes native attach clients and does not run `zmx kill`
- `GRAFTTY_SOCK` is passed in the `zmx attach` environment, not as a libghostty surface-only env var
- zsh integration is env-based (`ZDOTDIR`/`GHOSTTY_ZSH_ZDOTDIR`) and no longer shell-prefix based
- the old empty-`ZDOTDIR` guard in `ZMX-6.4` is either revised for explicit env construction or removed if no longer applicable

Remove or rewrite `attachInitialInput` expectations in `ZmxLauncherTests`.

- [ ] **Step 4: Run tests and verify RED**

Run:

```bash
swift test --filter SurfaceHandleHostManagedTests
swift test --filter ZmxLauncherUnitTests
swift test --filter ZmxTodo
```

Expected: fails because production still uses `initial_input` and does not expose the config-capture/start-failure seam.

- [ ] **Step 5: Modify `SurfaceHandle`**

Change initializer from:

```swift
zmxInitialInput: String? = nil,
extraInitialInput: String? = nil,
zmxDir: String? = nil,
```

to:

```swift
zmxSpawnConfiguration: ZmxSpawnConfiguration? = nil,
extraInitialInput: String? = nil,
```

Rules:

- If `zmxSpawnConfiguration != nil`, configure host-managed backend and do not set `initial_input`.
- If `zmxSpawnConfiguration == nil`, preserve existing direct-shell behavior and allow `extraInitialInput`.
- Store a strong `HostManagedZmxBackend` reference on `SurfaceHandle`.
- Start the backend only after `ghostty_surface_new` succeeds.
- If `extraInitialInput` is present for a zmx-backed pane, write it to the native PTY session after backend start, preserving current open-in-editor pane behavior without using libghostty `initial_input`.
- If backend start throws, report nonzero process exit and emit a diagnostic through the injected/prod surface output path.
- In `deinit`, close the native PTY session before freeing the surface.

- [ ] **Step 6: Modify `TerminalManager`**

Replace `resolveZmxSpawn(for:) -> (initialInput: String?, dir: String?)` with `resolveZmxSpawnConfiguration(for:worktreePath:) -> ZmxSpawnConfiguration?`.

Call sites:

- `createSurfaces(for:worktreePath:)`
- `createSurface(terminalID:worktreePath:extraInitialInput:)`
- restart/recovery paths if they instantiate `SurfaceHandle`

Ensure zmx unavailable still passes nil and falls back to direct shell.

- [ ] **Step 7: Remove obsolete bootstrap code**

Remove from `ZmxLauncher`:

- `attachInitialInput(...)`
- `zshIntegrationPrefix(...)`
- tests that only validate shell bootstrap text

Keep `attachCommand` if still used by zmx survival integration helpers. Do not remove helpers that tests still need.

- [ ] **Step 8: Run tests and verify GREEN**

Run:

```bash
swift test --filter SurfaceHandleHostManagedTests
swift test --filter ZmxLauncherUnitTests
swift test --filter ZmxTodo
swift test --filter NativePtySessionTests
swift test --filter HostManagedZmxBackendTests
```

Expected: all selected tests pass.

- [ ] **Step 9: Commit**

```bash
git add Sources/Graftty/Terminal/SurfaceHandle.swift Sources/Graftty/Terminal/TerminalManager.swift Sources/GrafttyKit/Zmx/ZmxLauncher.swift Tests/GrafttyTests/Specs/ZmxTodo.swift Tests/GrafttyKitTests/Zmx/ZmxLauncherTests.swift Tests/GrafttyTests/Terminal/SurfaceHandleHostManagedTests.swift
git commit -m "feat(zmx): cut native panes over to host-managed io"
```

## Task 5: zmx Host-Managed Integration Coverage

**Files:**
- Create or modify: `Tests/GrafttyKitTests/Zmx/ZmxNativeHostManagedIntegrationTests.swift`
- Modify if needed: shared zmx test helpers in `Tests/GrafttyKitTests/Zmx/ZmxSurvivalIntegrationTests.swift`

- [ ] **Step 1: Write failing scoped zmx integration tests**

Add a helper that creates `/tmp/zmx-<uuid>` and refuses to run if:

```swift
guard zmxDir.path.hasPrefix("/tmp/zmx-") else {
    Issue.record("unsafe ZMX_DIR \(zmxDir.path)")
    return
}
```

Add tests:

- `hostManagedAttachCreatesSession`
- `cleanClientCloseLeavesDaemonListed`
- `reattachRestoresMarker`
- `explicitKillRemovesDaemon`
- `inheritedZMXSessionDoesNotHijackTarget`

Use `PtyProcess.spawn`/`NativePtySession`-equivalent argv/env where possible, but keep this in `GrafttyKitTests` if it can avoid importing the app target. If importing `NativePtySession` is required, move the tests to `GrafttyTests/Terminal`.

- [ ] **Step 2: Run tests and verify RED**

Run:

```bash
swift test --filter ZmxNativeHostManagedIntegrationTests
```

Expected: fails because the integration helper/tests do not exist or because the implementation still uses the old native bootstrap.

- [ ] **Step 3: Implement integration helper adjustments**

Implementation notes:

- Reuse existing `ZmxSurvivalIntegrationTests.vendoredZmx()`.
- Reuse `ZmxLauncher.subprocessEnv` and `attachArgv`.
- Never call zmx without explicit scoped `ZMX_DIR`.
- Kill leaked sessions in `defer`.

- [ ] **Step 4: Run tests and verify GREEN**

Run:

```bash
swift test --filter ZmxNativeHostManagedIntegrationTests
swift test --filter ZmxSurvivalIntegrationTests
```

Expected: all selected tests pass or skip only when the vendored zmx binary is unavailable.

- [ ] **Step 5: Commit**

```bash
git add Tests/GrafttyKitTests/Zmx/ZmxNativeHostManagedIntegrationTests.swift Tests/GrafttyKitTests/Zmx/ZmxSurvivalIntegrationTests.swift
git commit -m "test(zmx): cover host-managed native attach lifecycle"
```

## Task 6: Integration, Specs, and Cleanup

**Files:**
- Modify: `SPECS.md`
- Modify if needed: `docs/superpowers/specs/2026-05-11-native-host-managed-zmx-design.md`
- Modify if needed: affected zmx/web/manual checklist tests

- [ ] **Step 1: Update `SPECS.md`**

Revise §13 so it matches:

- native zmx panes use host-managed I/O
- no native zmx `command`/`initial_input`
- app quit terminates attach clients only
- explicit close/Stop worktree kills zmx daemon
- `GRAFTTY_SOCK` is part of the `zmx attach` env
- zsh integration is env-based

Run the spec generation script if this repo expects `SPECS.md` to be regenerated from `Tests/GrafttyTests/Specs/*Todo.swift`:

```bash
python3 scripts/generate-specs.py
```

Then inspect the resulting diff to ensure the generated §13 text matches the implementation.

- [ ] **Step 2: Run focused build/test verification**

Run:

```bash
swift test --filter Zmx
swift test --filter NativePtySessionTests
swift test --filter PtyProcessTests
swift test --filter HostManagedZmxBackendTests
swift test --filter SurfaceHandleHostManagedTests
swift build
```

Expected: all commands exit 0.

- [ ] **Step 3: Run full test suite if focused verification is clean**

Run:

```bash
swift test
```

Expected: all tests pass, with existing skips only where zmx or platform prerequisites are unavailable.

- [ ] **Step 4: Commit**

```bash
git add SPECS.md docs/superpowers/specs/2026-05-11-native-host-managed-zmx-design.md
git commit -m "docs: update zmx host-managed requirements"
```

## Final Verification

- [ ] Run `git status --short` and confirm only intended files are changed or committed.
- [ ] Run `swift build`.
- [ ] Run `swift test`.
- [ ] Run `$simplify` review workflow on the final diff.
- [ ] Fix simplify findings.
- [ ] Run verification again after simplify fixes.
- [ ] Push branch and open PR with `gh pr create` as requested by the user for this task.
