# zmx-attach login-shell recovery — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make every shell Graftty spawns through `zmx attach` behave as a login shell so `~/.zprofile` (which adds `/opt/homebrew/bin` to PATH via `brew shellenv`) runs before `~/.zshrc` references rbenv/nvm/etc., fixing the cascading "command not found" + broken-color + broken-backspace symptom.

**Architecture:** Two paths. **Non-bash shells (and bash with hooks disabled):** drop the positional shell argument from `zmx attach` argv → zmx applies its documented default of spawning `$SHELL` as a login shell. **Bash with hooks enabled:** keep the launcher path positional (the launcher's `--rcfile` injection only works in non-login bash), and update the launcher shim to source the profile chain itself with an idempotency guard. Spec: `docs/superpowers/specs/2026-05-13-zmx-attach-login-shell-design.md`. Specs: ZMX-6.6, ZMX-6.7.

**Tech Stack:** Swift Package Manager, Swift Testing (`@Test` / `@Suite`), `scripts/generate-specs.py` for SPECS.md regeneration.

---

## File Structure

| File | Responsibility | Change |
|---|---|---|
| `Sources/GrafttyKit/Zmx/ZmxLauncher.swift` | Owns `attachArgv` argv-builder | Add no-shell overload `attachArgv(sessionName:)`; existing `attachArgv(sessionName:userShell:)` becomes no-default-arg |
| `Sources/GrafttyKit/Zmx/ZmxSpawnConfiguration.swift` | Builds full spawn (argv + env + cwd) per pane | Branch on shell basename + hooks-enabled flag; set `env["SHELL"]` explicitly; pick the right `attachArgv` overload |
| `Sources/GrafttyKit/Web/WebSession.swift` | Web-pane spawn | Already calls `attachArgv(sessionName:)` (the new overload signature) — verify behavior; no code change needed beyond confirming |
| `Sources/GrafttyKit/Teams/AgentHookInstaller.swift` | Generates agent-hooks shim files | Update `bashrcShim()` to source profile chain with `__GRAFTTY_BASH_PROFILE_SOURCED` idempotency guard |
| `Tests/GrafttyKitTests/Zmx/ZmxSpawnConfigurationTests.swift` | Spec tests for spawn config | Add ZMX-6.6 tests; update existing argv assertions |
| `Tests/GrafttyKitTests/Teams/AgentHookInstallerTests.swift` | Spec tests for shim text | Add ZMX-6.7 tests for new shim content; update existing `bashrcShimSourcesUserBashrcAndPrependsAgentBin` |
| `Tests/GrafttyKitTests/Zmx/ZmxLauncherTests.swift` | Spec tests for launcher | Add tests for the new `attachArgv(sessionName:)` overload |
| `Tests/GrafttyTests/Terminal/HostManagedZmxBackendTests.swift` | Backend integration test | Update fake `spawnConfiguration()` literal argv (line 281) to drop `/bin/zsh` |
| `SPECS.md` | Auto-generated spec inventory | Regenerate via `scripts/generate-specs.py` |

---

## Task 1: ZmxLauncher.attachArgv — add no-shell overload (RED → GREEN)

**Files:**
- Modify: `Sources/GrafttyKit/Zmx/ZmxLauncher.swift` (around line 109)
- Test: `Tests/GrafttyKitTests/Zmx/ZmxLauncherTests.swift` (add a new `@Test` near the existing `attachCommand…` cluster around line 89)

- [ ] **Step 1: Write the failing tests**

Append to `Tests/GrafttyKitTests/Zmx/ZmxLauncherTests.swift`, immediately after the `attachCommandQuotesSessionNameDefensively` test (around line 114):

```swift
    @Test("""
    @spec ZMX-6.6: When called with no `userShell`, `attachArgv` shall return `[zmx, "attach", sessionName]` with no positional shell so that zmx applies its documented default of spawning `$SHELL` as a login shell.
    """)
    func attachArgvWithoutUserShellOmitsPositionalShell() throws {
        let launcher = ZmxLauncher(executable: URL(fileURLWithPath: "/usr/bin/zmx"))

        let argv = launcher.attachArgv(sessionName: "graftty-deadbeef")

        #expect(argv == ["/usr/bin/zmx", "attach", "graftty-deadbeef"])
    }

    @Test func attachArgvWithExplicitUserShellAppendsPositional() throws {
        let launcher = ZmxLauncher(executable: URL(fileURLWithPath: "/usr/bin/zmx"))

        let argv = launcher.attachArgv(sessionName: "graftty-cafe1234", userShell: "/bin/zsh")

        #expect(argv == ["/usr/bin/zmx", "attach", "graftty-cafe1234", "/bin/zsh"])
    }
```

- [ ] **Step 2: Run tests to verify they fail**

```
swift test --filter ZmxLauncherTests
```

Expected: `attachArgvWithoutUserShellOmitsPositionalShell` should currently PASS (because the existing default `userShell` adds `/bin/bash` or `$SHELL`, making argv length 4). Wait — re-read: the existing impl returns `[zmx, attach, session, userShell]` even when caller passes only `sessionName` (default arg fills userShell). So the new test will see argv with 4 elements, not 3 → FAIL with `argv == ["/usr/bin/zmx", "attach", "graftty-deadbeef"]` not matching.

Confirm the failure shows a 4-element actual.

- [ ] **Step 3: Implement — split into two overloads**

In `Sources/GrafttyKit/Zmx/ZmxLauncher.swift`, replace the existing `attachArgv` method (around line 109-112) with two methods:

```swift
    /// Argv form of the attach invocation when Graftty wants zmx to apply
    /// its documented default behavior of spawning `$SHELL` as a login
    /// shell. The caller is responsible for setting `env["SHELL"]` to the
    /// resolved user shell so zmx exec's the intended binary.
    ///
    /// Use this for every shell EXCEPT bash with agent hooks enabled —
    /// bash login mode ignores `--rcfile` (the mechanism the agent-hooks
    /// shim depends on), so bash-with-hooks must keep an explicit
    /// positional shell pointing at the launcher script. ZMX-6.6, ZMX-6.7.
    public func attachArgv(sessionName: String) -> [String] {
        [executable.path, "attach", sessionName]
    }

    /// Argv form of the attach invocation with an explicit user-shell
    /// positional. Use this only when zmx's default login-shell spawn is
    /// the wrong choice — currently bash with agent hooks enabled (the
    /// launcher must run with `--rcfile`, which login bash ignores).
    /// Tests that need a deterministic shell binary also use this overload.
    ///
    /// Resolves `$SHELL` for callers that want the user's default shell
    /// but still need an explicit positional, because `execve` passes argv
    /// verbatim and zmx doesn't re-expand shell metacharacters in the
    /// command arg.
    public func attachArgv(sessionName: String, userShell: String) -> [String] {
        [executable.path, "attach", sessionName, userShell]
    }
```

Note the second method **no longer has a default argument** for `userShell`. This is intentional — it forces callers to make an explicit choice between the two paths.

- [ ] **Step 4: Run all `swift test` to confirm new tests pass and find compile errors**

```
swift test --filter ZmxLauncherTests
```

Expected: both new tests PASS. (Other ZmxLauncher tests in this file unchanged.)

Then run the wider test for compile errors caused by removing the default arg:

```
swift build 2>&1 | head -40
```

Expected: compile errors in `WebSession.swift:88` should NOT appear (it already calls `attachArgv(sessionName:)` only — that now matches the new no-shell overload). Compile errors at sites that pass both arguments should NOT appear (signature unchanged). 

If compile errors surface elsewhere, list them and stop — they indicate call sites missed during the design.

- [ ] **Step 5: Commit**

```
git add Sources/GrafttyKit/Zmx/ZmxLauncher.swift Tests/GrafttyKitTests/Zmx/ZmxLauncherTests.swift
git commit -m "$(cat <<'EOF'
feat(zmx): split attachArgv into login-default and explicit-shell overloads (ZMX-6.6)

The no-userShell overload returns [zmx, attach, session] so zmx applies
its documented default of spawning $SHELL as a login shell. The explicit
overload keeps the positional path for the bash-with-agent-hooks case
(ZMX-6.7) where login bash would discard --rcfile.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: ZmxSpawnConfiguration.make — branch on shell + set env["SHELL"] (RED → GREEN)

**Files:**
- Modify: `Sources/GrafttyKit/Zmx/ZmxSpawnConfiguration.swift` (lines 11-69)
- Modify: `Tests/GrafttyKitTests/Zmx/ZmxSpawnConfigurationTests.swift` (update existing assertions, add ZMX-6.6 tests)

- [ ] **Step 1: Write the failing spec test**

Add this test to `Tests/GrafttyKitTests/Zmx/ZmxSpawnConfigurationTests.swift`, after the existing `bashUsesAgentHookWrappedShellWhenHooksAreEnabled` test (around line 69):

```swift
    @Test("""
    @spec ZMX-6.6: When the resolved user-shell basename is anything other than `bash` (or when bash is selected with agent hooks disabled), the host-managed `zmx attach` argv shall omit the positional shell argument so that zmx applies its documented default behavior of spawning `$SHELL` as a login shell. The spawn `env["SHELL"]` shall be set to the resolved user-shell path so zmx exec's the intended binary. This restores `~/.zprofile` (via the ZMX-6.3 ZDOTDIR shim for zsh) processing — without it, `eval "$(brew shellenv)"` is skipped and `~/.zshrc` references to Homebrew-installed binaries (rbenv, nvm, etc.) resolve to "command not found", cascading into broken keybindings, missing colors, and shell-init errors.
    """)
    func zshOmitsPositionalShellAndSetsShellEnvForDefaultLoginSpawn() throws {
        let config = makeConfig(processEnv: [
            "SHELL": "/bin/zsh",
            "PATH": "/usr/bin",
        ])

        #expect(config.argv == ["/tmp/zmx", "attach", "graftty-deadbeef"])
        #expect(config.env["SHELL"] == "/bin/zsh")
    }

    @Test("""
    @spec ZMX-6.6: When agent hooks are disabled and the user's shell is bash, the spawn shall also drop the positional shell argument and rely on zmx's default login-`$SHELL` spawn. The launcher script (which would otherwise force non-login bash via `--rcfile`) is bypassed, so login-time setup such as `~/.bash_profile` runs naturally.
    """)
    func bashWithoutHooksOmitsPositionalShellAndSetsShellEnv() throws {
        let config = makeConfig(
            processEnv: [
                "SHELL": "/bin/bash",
                "PATH": "/usr/bin",
            ],
            agentHooksDisabled: true
        )

        #expect(config.argv == ["/tmp/zmx", "attach", "graftty-deadbeef"])
        #expect(config.env["SHELL"] == "/bin/bash")
    }

    @Test("""
    @spec ZMX-6.6: When agent hooks are enabled and the user's shell is bash, the spawn shall keep the positional shell pointing at the bash launcher script (per ZMX-6.7), because login bash discards `--rcfile`.
    """)
    func bashWithHooksKeepsPositionalLauncherShell() throws {
        let config = makeConfig(processEnv: [
            "SHELL": "/opt/homebrew/bin/bash",
            "PATH": "/usr/bin",
        ])

        let expectedLauncher = AgentHookInstaller.wrappedUserShell("/opt/homebrew/bin/bash", rootDirectory: agentHooksRoot)
        #expect(config.argv.count == 4)
        #expect(config.argv.last == expectedLauncher)
        #expect(config.env["SHELL"] == "/opt/homebrew/bin/bash")
    }
```

Then update existing assertions that will break:

In the same file, find `buildsAttachArgvForWrappedShellAndRequiredEnv` (around line 19-34) and change:

```swift
        #expect(config.argv.last == "/bin/zsh")
```

to:

```swift
        // ZMX-6.6: zsh path drops the positional shell so zmx does the
        // login spawn. argv is [zmx, attach, sessionName] only.
        #expect(config.argv.count == 3)
        #expect(config.env["SHELL"] == "/bin/zsh")
```

Find `disabledHooksUseRawShellAndDoNotSetHookEnv` (around line 71-88) and change:

```swift
        #expect(config.argv.last == "/bin/bash")
```

to:

```swift
        // ZMX-6.6: hooks disabled → positional shell dropped (no launcher
        // needed); zmx defaults to login $SHELL.
        #expect(config.argv.count == 3)
        #expect(config.env["SHELL"] == "/bin/bash")
```

(The `bashUsesAgentHookWrappedShellWhenHooksAreEnabled` test at line 62-69 stays as-is — its `argv.last == launcher path` assertion still holds for the bash-with-hooks path.)

- [ ] **Step 2: Run tests to verify they fail**

```
swift test --filter ZmxSpawnConfigurationTests
```

Expected: the three new tests should FAIL because `make()` still appends `userShell` positionally for all shells. The two updated existing tests should also FAIL for the same reason.

- [ ] **Step 3: Implement — branch in `make()`**

In `Sources/GrafttyKit/Zmx/ZmxSpawnConfiguration.swift`, replace the `make` body (lines 11-69 in current file). Show the full updated method:

```swift
    public static func make(
        launcher: ZmxLauncher,
        paneSessionID: PaneSessionID,
        worktreePath: String,
        socketPath: String,
        processEnv: [String: String],
        bundleURL: URL,
        ghosttyResourcesDir: String?,
        agentHooksDisabled: Bool,
        agentHooksRoot: URL
    ) -> ZmxSpawnConfiguration {
        let sessionName = launcher.sessionName(for: paneSessionID)
        let rawUserShell = processEnv["SHELL"] ?? "/bin/sh"
        let hooksEnabled = !agentHooksDisabled
        let shellBasename = (rawUserShell as NSString).lastPathComponent

        var env = launcher.subprocessEnv(from: processEnv)
        env.removeValue(forKey: "GRAFTTY_AGENT_HOOKS_BIN")
        env.removeValue(forKey: "ZDOTDIR")
        env.removeValue(forKey: "GHOSTTY_ZSH_ZDOTDIR")
        env["GRAFTTY_SOCK"] = socketPath
        // ZMX-6.6: zmx's no-command default-login-spawn reads $SHELL from
        // its env to decide what binary to exec. Set it explicitly so the
        // resolved user shell is used regardless of what the parent
        // process inherited.
        env["SHELL"] = rawUserShell
        applyTerminalCapabilities(
            env: &env,
            ghosttyResourcesDir: ghosttyResourcesDir
        )

        let sanitizedPath = BundlePathSanitizer.sanitized(
            currentPath: processEnv["PATH"] ?? "",
            bundleURL: bundleURL
        )
        if hooksEnabled {
            let hookBin = AgentHookInstaller.binDirectory(rootDirectory: agentHooksRoot).path
            env["GRAFTTY_AGENT_HOOKS_BIN"] = hookBin
            env["PATH"] = "\(hookBin):\(sanitizedPath)"
        } else {
            env["PATH"] = sanitizedPath
        }

        if let ghosttyResourcesDir, !ghosttyResourcesDir.isEmpty,
           shellBasename == "zsh" {
            env["ZDOTDIR"] = (ghosttyResourcesDir as NSString)
                .appendingPathComponent("shell-integration/zsh")
            if hooksEnabled {
                env["GHOSTTY_ZSH_ZDOTDIR"] = AgentHookInstaller
                    .zshInitDirectory(rootDirectory: agentHooksRoot)
                    .path
            }
        }

        // ZMX-6.6: For non-bash shells (and bash with hooks disabled),
        // omit the positional shell argument so zmx's documented default
        // applies — it spawns $SHELL as a login shell, which sources the
        // profile chain (~/.zprofile, ~/.bash_profile) before the rc
        // file. ZMX-6.7: bash-with-hooks is the exception: the launcher
        // script must run with --rcfile, which login bash discards, so
        // we keep the positional pointing at the launcher path.
        let useDefaultLoginSpawn = (shellBasename != "bash") || !hooksEnabled
        let argv: [String]
        if useDefaultLoginSpawn {
            argv = launcher.attachArgv(sessionName: sessionName)
        } else {
            let wrappedShell = AgentHookInstaller.wrappedUserShell(rawUserShell, rootDirectory: agentHooksRoot)
            argv = launcher.attachArgv(sessionName: sessionName, userShell: wrappedShell)
        }

        return ZmxSpawnConfiguration(
            sessionName: sessionName,
            argv: argv,
            env: env,
            workingDirectory: URL(fileURLWithPath: worktreePath, isDirectory: true)
        )
    }
```

- [ ] **Step 4: Run tests to verify GREEN**

```
swift test --filter ZmxSpawnConfigurationTests
```

Expected: all `ZmxSpawnConfigurationTests` PASS — both the three new ZMX-6.6 tests and the updated existing assertions.

If the `bashUsesAgentHookWrappedShellWhenHooksAreEnabled` test (line 62) fails after the change, examine its current assertions — they should hold because bash-with-hooks still passes the launcher positionally. If it fails, the `useDefaultLoginSpawn` branch logic is wrong; re-check.

- [ ] **Step 5: Commit**

```
git add Sources/GrafttyKit/Zmx/ZmxSpawnConfiguration.swift Tests/GrafttyKitTests/Zmx/ZmxSpawnConfigurationTests.swift
git commit -m "$(cat <<'EOF'
fix(zmx): drop positional shell for non-bash spawns to recover login behavior (ZMX-6.6)

ZmxSpawnConfiguration.make now branches on shell basename + hooks-enabled.
For everything except bash-with-hooks, the spawn omits the positional
shell argument so zmx's documented default of spawning $SHELL as a login
shell applies. env["SHELL"] is set explicitly so zmx exec's the intended
binary. Recovers ~/.zprofile sourcing (via the ZMX-6.3 ZDOTDIR shim for
zsh), which fixes downstream "rbenv: command not found" + cascading
broken keybindings / missing colors during .zshrc init.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: Update HostManagedZmxBackendTests fake spawnConfiguration

**Files:**
- Modify: `Tests/GrafttyTests/Terminal/HostManagedZmxBackendTests.swift` (line 281)

- [ ] **Step 1: Run the test file to see it fail**

```
swift test --filter HostManagedZmxBackendTests
```

Expected: tests using `spawnConfiguration()` may PASS today because they don't assert on argv shape — but the fake's argv literal is now stale relative to the new ZMX-6.6 shape. Read the test bodies first to determine whether the literal is asserted against. If no assertions touch argv shape → no production-code failure, but updating the fixture keeps it consistent with reality.

- [ ] **Step 2: Update the fake**

In `Tests/GrafttyTests/Terminal/HostManagedZmxBackendTests.swift` line 278-285, change:

```swift
    private static func spawnConfiguration() -> ZmxSpawnConfiguration {
        ZmxSpawnConfiguration(
            sessionName: "graftty-test",
            argv: ["/tmp/zmx", "attach", "graftty-test", "/bin/zsh"],
            env: ["ZMX_DIR": "/tmp/zmx-dir"],
            workingDirectory: URL(fileURLWithPath: "/tmp/worktree", isDirectory: true)
        )
    }
```

to:

```swift
    private static func spawnConfiguration() -> ZmxSpawnConfiguration {
        // ZMX-6.6: argv shape for zsh drops the positional shell —
        // zmx's default-spawn picks up env["SHELL"].
        ZmxSpawnConfiguration(
            sessionName: "graftty-test",
            argv: ["/tmp/zmx", "attach", "graftty-test"],
            env: ["ZMX_DIR": "/tmp/zmx-dir", "SHELL": "/bin/zsh"],
            workingDirectory: URL(fileURLWithPath: "/tmp/worktree", isDirectory: true)
        )
    }
```

- [ ] **Step 3: Run the test**

```
swift test --filter HostManagedZmxBackendTests
```

Expected: PASS.

- [ ] **Step 4: Commit**

```
git add Tests/GrafttyTests/Terminal/HostManagedZmxBackendTests.swift
git commit -m "$(cat <<'EOF'
test(host-managed): update fake spawnConfiguration to ZMX-6.6 argv shape

The fake's argv literal was stale relative to the new no-positional-shell
behavior. Update to match what ZmxSpawnConfiguration.make now produces.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: bashrcShim — source profile chain with idempotency guard (RED → GREEN)

**Files:**
- Modify: `Sources/GrafttyKit/Teams/AgentHookInstaller.swift` (around line 185-210, the `bashrcShim()` function)
- Modify: `Tests/GrafttyKitTests/Teams/AgentHookInstallerTests.swift` (update existing test, add ZMX-6.7 test)

- [ ] **Step 1: Write the failing test**

Append to `Tests/GrafttyKitTests/Teams/AgentHookInstallerTests.swift`, after the existing `bashrcShimSourcesUserBashrcAndPrependsAgentBin` test (around line 39):

```swift
    @Test("""
    @spec ZMX-6.7: When the user's shell is bash and agent hooks are enabled, the launcher script continues to invoke `bash --rcfile <shim>` (non-login, so `--rcfile` is honored), and the shim shall source the system + user profile chain (`/etc/profile`; first existing of `~/.bash_profile`, `~/.bash_login`, `~/.profile`) once per environment via an idempotency guard env variable (`__GRAFTTY_BASH_PROFILE_SOURCED`), before sourcing `~/.bashrc` and re-prepending the agent-hooks bin to PATH. This recovers login-time PATH setup (Homebrew shellenv, etc.) for bash users without losing the agent-hooks injection that depends on `--rcfile`.
    """)
    func bashrcShimSourcesProfileChainWithIdempotencyGuard() {
        let shim = AgentHookInstaller.bashrcShim()

        // Idempotency guard env var
        #expect(shim.contains("__GRAFTTY_BASH_PROFILE_SOURCED"))
        #expect(shim.contains("export __GRAFTTY_BASH_PROFILE_SOURCED=1"))

        // System profile
        #expect(shim.contains("/etc/profile"))

        // User profile-chain candidates, in order
        #expect(shim.contains(#""$HOME/.bash_profile""#))
        #expect(shim.contains(#""$HOME/.bash_login""#))
        #expect(shim.contains(#""$HOME/.profile""#))

        // Profile chain is sourced BEFORE .bashrc
        let profileGuardIdx = shim.range(of: "__GRAFTTY_BASH_PROFILE_SOURCED")!.lowerBound
        let bashrcSourceIdx = shim.range(of: #"source "$HOME/.bashrc""#)!.lowerBound
        #expect(profileGuardIdx < bashrcSourceIdx)
    }
```

- [ ] **Step 2: Run the test to verify it fails**

```
swift test --filter AgentHookInstallerTests
```

Expected: FAIL — the existing `bashrcShim()` does not contain `__GRAFTTY_BASH_PROFILE_SOURCED` or `/etc/profile`.

- [ ] **Step 3: Update bashrcShim() in source**

In `Sources/GrafttyKit/Teams/AgentHookInstaller.swift` around line 185, replace the entire `bashrcShim()` function body. Show the full new method:

```swift
    static func bashrcShim() -> String {
        """
        # Generated by graftty AgentHookInstaller. The launcher script (per
        # ZMX-6.7) invokes bash with `--rcfile <this-file>` so that:
        #   1. The agent-hooks shim runs in non-login mode (login bash
        #      discards --rcfile).
        #   2. We can re-prepend graftty's wrapper bin to PATH after the
        #      user's shell-init has had its say, so `claude` / `codex`
        #      resolve to our wrapper rather than the upstream installs in
        #      `~/.bun/bin` / `~/.local/bin` / etc.
        #
        # But non-login bash skips the profile chain (~/.bash_profile etc.)
        # which on a typical macOS install is where `eval "$(brew shellenv)"`
        # lands. Source it ourselves once per environment, gated by
        # `__GRAFTTY_BASH_PROFILE_SOURCED` so nested non-login bash
        # invocations don't re-source.
        if [ -z "$__GRAFTTY_BASH_PROFILE_SOURCED" ]; then
            export __GRAFTTY_BASH_PROFILE_SOURCED=1
            [ -r /etc/profile ] && . /etc/profile
            for _graftty_profile in "$HOME/.bash_profile" "$HOME/.bash_login" "$HOME/.profile"; do
                if [ -r "$_graftty_profile" ]; then
                    . "$_graftty_profile"
                    break
                fi
            done
            unset _graftty_profile
        fi

        [ -r "$HOME/.bashrc" ] && source "$HOME/.bashrc"

        if [ -n "$GRAFTTY_AGENT_HOOKS_BIN" ]; then
            # Strip any existing occurrences of our bin so nested bash
            # invocations don't accumulate duplicates.
            case ":$PATH:" in
                *":$GRAFTTY_AGENT_HOOKS_BIN:"*)
                    _graftty_path=":$PATH:"
                    _graftty_path="${_graftty_path//:$GRAFTTY_AGENT_HOOKS_BIN:/:}"
                    _graftty_path="${_graftty_path#:}"
                    _graftty_path="${_graftty_path%:}"
                    PATH="$_graftty_path"
                    unset _graftty_path
                    ;;
            esac
            export PATH="$GRAFTTY_AGENT_HOOKS_BIN:$PATH"
        fi
        """
    }
```

- [ ] **Step 4: Run tests to verify GREEN**

```
swift test --filter AgentHookInstallerTests
```

Expected: all AgentHookInstallerTests PASS — the new ZMX-6.7 test plus the existing ones (which assert on `source "$HOME/.bashrc"` and the PATH re-prepend logic, both of which are preserved verbatim in the new shim).

- [ ] **Step 5: Commit**

```
git add Sources/GrafttyKit/Teams/AgentHookInstaller.swift Tests/GrafttyKitTests/Teams/AgentHookInstallerTests.swift
git commit -m "$(cat <<'EOF'
fix(agent-hooks): bash shim sources profile chain so login-time setup runs (ZMX-6.7)

Bash login mode discards --rcfile, but the agent-hooks shim depends on
--rcfile to inject the wrapper-bin PATH prepend. So bash stays non-login
and the shim now manually sources /etc/profile + the first existing of
~/.bash_profile / ~/.bash_login / ~/.profile, gated by
__GRAFTTY_BASH_PROFILE_SOURCED so nested invocations don't re-source.

Recovers Homebrew shellenv (and other login-time PATH setup) for bash
users with agent hooks enabled, complementing ZMX-6.6 which fixes the
zsh and hooks-disabled-bash paths via zmx's default login spawn.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 5: Regenerate SPECS.md and run full test suite

**Files:**
- Modify: `SPECS.md` (auto-generated)

- [ ] **Step 1: Run the spec generator**

```
python3 scripts/generate-specs.py
```

Expected: `SPECS.md` is regenerated with the new ZMX-6.6 and ZMX-6.7 entries. If the script complains about duplicate spec IDs (active test + disabled inventory), check `Tests/GrafttyTests/Specs/ZmxTodo.swift` for stale entries — there should be none for 6.6/6.7.

- [ ] **Step 2: Confirm SPECS.md changed**

```
git diff SPECS.md | head -40
```

Expected: diff shows new ZMX-6.6 and ZMX-6.7 entries added under the ZMX section.

- [ ] **Step 3: Run the full test suite**

```
swift test 2>&1 | tail -30
```

Expected: all tests PASS. If anything outside the files we touched fails, investigate (probably another test we missed that asserts on argv shape).

- [ ] **Step 4: Commit**

```
git add SPECS.md
git commit -m "$(cat <<'EOF'
docs: regenerate SPECS.md for ZMX-6.6 and ZMX-6.7

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Self-Review

**Spec coverage:**
- ZMX-6.6 (drop positional shell + set env["SHELL"]) — covered by Task 1 (launcher API), Task 2 (caller logic + tests), Task 3 (fixture update).
- ZMX-6.7 (bash shim profile chain + idempotency guard) — covered by Task 4.
- SPECS.md regen — Task 5.
- WebSession behavior — Task 1's API change automatically gives WebSession the new behavior since it already calls `attachArgv(sessionName:)` (which now maps to the no-shell overload). No separate task needed; the behavior is verified by Task 5's full `swift test` run.

**Type consistency:** `attachArgv(sessionName:)` and `attachArgv(sessionName:userShell:)` both return `[String]` and are referred to consistently. `bashrcShim()` and `__GRAFTTY_BASH_PROFILE_SOURCED` are referred to consistently across Task 4.

**Placeholder scan:** No TBD/TODO. All steps include exact code or exact commands.

**Open question already noted in plan:** Task 3 (HostManagedZmxBackendTests fixture update) may be a no-op for current test assertions; the change is made for fixture realism rather than fixing a failing test. That's documented in the task.
