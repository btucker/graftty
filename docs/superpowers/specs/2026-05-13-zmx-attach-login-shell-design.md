# Recover login-shell behavior for host-managed `zmx attach`

**Status:** Draft for implementation
**Specs introduced:** ZMX-6.6 (zsh / non-bash shells), ZMX-6.7 (bash with agent hooks)

## Problem

Graftty spawns each native pane via `zmx attach <session> <userShell>`. zmx's documented behavior is "spawn a login `$SHELL` with a PTY," but only when called with no positional command — when given a command (which Graftty always passes, currently `userShell`), zmx exec's it as-is, **non-login**.

The result on a typical macOS install:

1. `~/.zprofile` is skipped → `eval "$(/opt/homebrew/bin/brew shellenv)"` doesn't run → `/opt/homebrew/bin` is missing from `PATH`.
2. `~/.zshrc` runs and references `rbenv` (and other Homebrew-installed tools like nvm) → `command not found: rbenv`.
3. Tools like `rbenv init` would normally install zsh hooks and complete-style bindings; their failure cascades into broken prompt colors, missing keybindings (backspace included via oh-my-zsh / similar plugin systems), and assorted shell-init errors.

Graftty has been passing `userShell` positionally because it needs to:
- Substitute the bash launcher script when agent hooks are enabled (the launcher exec's `bash --rcfile <shim>`).
- Historically: pin to a specific shell decided at spawn time.

## Goal

Make every shell Graftty spawns through `zmx attach` behave as a login shell — sourcing `~/.zprofile` / `~/.bash_profile` / `/etc/profile` etc. before the rc file runs — *without* losing the agent-hooks shim that depends on bash's non-login `--rcfile` behavior.

## Design

Two genuinely different paths, one per shell family.

### Zsh (and `sh`, `fish`, anything that isn't bash)

**Drop the positional shell argument.** Pass only `[zmx, attach, sessionName]` to `PtyProcess.spawn`. Set `env["SHELL"]` explicitly so zmx exec's the intended binary. zmx's default behavior takes over and spawns it as a login shell.

The existing zsh integration story (ZMX-6.3, ZMX-6.4) is unchanged: `ZDOTDIR` is in the env, so login zsh reads `$ZDOTDIR/.zshenv` → shim sources `~/.zshenv` → reads `$ZDOTDIR/.zprofile` → shim sources `~/.zprofile` → `brew shellenv` runs → PATH gains `/opt/homebrew/bin` → `~/.zshrc`'s `rbenv init` resolves correctly.

The graftty `.zprofile` shim under `agent-hooks/zsh-init/` already exists (`AgentHookInstaller.installZshInitShim`) — it's been a Chekhov's gun waiting for the shell to actually be login.

### Bash with agent hooks enabled

Bash login mode **ignores `--rcfile`**, which the agent-hooks shim depends on. We can't simultaneously have "bash login" and "shim runs."

**Keep the launcher path** as the positional command (so `--rcfile` still applies), and **augment the shim** to source the profile chain itself, gated by an idempotency env var:

```sh
# bash-init/.bashrc (rewritten)
if [ -z "$__GRAFTTY_BASH_PROFILE_SOURCED" ]; then
    export __GRAFTTY_BASH_PROFILE_SOURCED=1
    [ -r /etc/profile ] && . /etc/profile
    for f in "$HOME/.bash_profile" "$HOME/.bash_login" "$HOME/.profile"; do
        if [ -r "$f" ]; then . "$f"; break; fi
    done
fi
[ -r "$HOME/.bashrc" ] && . "$HOME/.bashrc"
# (existing) re-prepend $GRAFTTY_AGENT_HOOKS_BIN to PATH
```

The `__GRAFTTY_BASH_PROFILE_SOURCED` guard prevents re-sourcing in nested bash invocations (which inherit env). Within a single bash startup, if the user's `.bash_profile` chains into `.bashrc` (canonical pattern), `.bashrc` runs twice; this is the standard cost of bash's split init model and is what login bash itself effectively does. Any `[[ $- != *i* ]] && return` guard at the top of `.bashrc` continues to behave correctly because we're inside an interactive bash both times.

### Bash with agent hooks disabled

Falls into the "drop positional shell" path with the rest. `zmx attach <session>` (no command) spawns `$SHELL=/bin/bash` as login → `.bash_profile` runs naturally. No shim is involved.

## Components affected

| File | Change |
|---|---|
| `Sources/GrafttyKit/Zmx/ZmxLauncher.swift` | `attachArgv` gains `omitPositionalShell: Bool = false`. When true, returns `[zmx, attach, sessionName]` (no shell). |
| `Sources/GrafttyKit/Zmx/ZmxSpawnConfiguration.swift` | Branch on shell basename. Bash with hooks enabled → keep positional (launcher path). All other cases → omit positional, set `env["SHELL"]` to the resolved user shell. |
| `Sources/GrafttyKit/Web/WebSession.swift` | Web pane spawn: same omit-positional treatment as native zsh path. |
| `Sources/GrafttyKit/Teams/AgentHookInstaller.swift` | Update `bashrcShim()` per spec above. Add `__GRAFTTY_BASH_PROFILE_SOURCED` idempotency guard. |
| `Tests/GrafttyKitTests/Zmx/ZmxSpawnConfigurationTests.swift` | Update existing argv assertions to match new shape; add ZMX-6.6 tests for both shells. |
| `Tests/GrafttyKitTests/Teams/AgentHookInstallerTests.swift` | Add ZMX-6.7 test for bash shim profile-chain sourcing + idempotency. |
| `Tests/GrafttyTests/Terminal/HostManagedZmxBackendTests.swift` | Update fake `spawnConfiguration()` literal argv (line 281). |
| `Tests/GrafttyTests/Specs/ZmxTodo.swift` | Remove ZMX-6.6 inventory entry if added there. |
| `SPECS.md` | Regenerated via `scripts/generate-specs.py`. |

## Behavior matrix (after change)

| User shell | Hooks | argv shape | env["SHELL"] | Login behavior |
|---|---|---|---|---|
| zsh | enabled | `[zmx, attach, <id>]` | `/bin/zsh` | zmx default → login zsh; ZDOTDIR shim chain runs |
| zsh | disabled | `[zmx, attach, <id>]` | `/bin/zsh` | zmx default → login zsh; user's home `.z*` chain runs |
| bash | enabled | `[zmx, attach, <id>, <launcher>]` | `/bin/bash` | launcher → `bash --rcfile <shim>`; shim sources profile chain manually |
| bash | disabled | `[zmx, attach, <id>]` | `/bin/bash` | zmx default → login bash; `.bash_profile` runs |
| sh / fish / other | n/a | `[zmx, attach, <id>]` | `/bin/sh` etc. | zmx default → login spawn |

## Spec text

### ZMX-6.6 — login behavior for non-bash shells

> When the resolved user-shell basename is anything other than `bash` (or when bash is selected with agent hooks disabled), the host-managed `zmx attach` argv shall omit the positional shell argument so that zmx applies its documented default behavior of spawning `$SHELL` as a login shell. The spawn `env["SHELL"]` shall be set to the resolved user-shell path so zmx exec's the intended binary. This restores `~/.zprofile` (via the ZMX-6.3 ZDOTDIR shim for zsh) processing — without it, `eval "$(brew shellenv)"` is skipped and `~/.zshrc` references to Homebrew-installed binaries (rbenv, nvm, etc.) resolve to "command not found", cascading into broken keybindings, missing colors, and shell-init errors.

### ZMX-6.7 — bash agent-hooks shim sources profile chain

> When the user's shell basename is `bash` and agent hooks are enabled, the launcher script shall continue to invoke `bash --rcfile <shim>` (non-login, so `--rcfile` is honored), and the shim shall source the system + user profile chain (`/etc/profile`; first existing of `~/.bash_profile`, `~/.bash_login`, `~/.profile`) once per environment via an idempotency guard env variable (`__GRAFTTY_BASH_PROFILE_SOURCED`), before sourcing `~/.bashrc` and re-prepending the agent-hooks bin to PATH. This recovers login-time PATH setup (Homebrew shellenv, etc.) for bash users without losing the agent-hooks injection that depends on `--rcfile`.

## Risks / known limitations

1. **Bash double-source.** If the user's `.bash_profile` ends with `source ~/.bashrc` (canonical pattern), `.bashrc` runs twice during shim init. Most rc files are idempotent enough; the duplicate `export PATH=…:$PATH` is tolerable. The standard `[[ $- != *i* ]] && return` guard at the top of `.bashrc` works correctly because we're inside an interactive bash both times.

2. **Explicit `env["SHELL"]` set.** Today it's inherited from `ProcessInfo`. We're switching to setting it explicitly so zmx's no-command path picks the right binary. Tests that assert on the env shape need updating.

3. **`HostManagedZmxBackendTests` fake.** Has a hardcoded `argv: ["/tmp/zmx", "attach", "graftty-test", "/bin/zsh"]` literal at line 281; needs updating.

4. **Tests calling `attachArgv(sessionName:userShell:)` directly.** Integration tests use the convenience overload to spawn `/bin/sh` or `/bin/zsh` for fast/predictable launches. The overload stays — it's only `ZmxSpawnConfiguration.make` that switches to `omitPositionalShell` for production callers.

## Out of scope

- Changes to libghostty's own command-spawn path (Graftty has fully migrated to host-managed PTY attach as of #145).
- Probing user login env at app startup (Option E from the brainstorm) — would require continuous per-spawn refresh and miss dynamic state like `direnv`/ssh-agent.
- Per-pane shell override (still resolved from `$SHELL` at app launch).

## Implementation hint (for the plan)

TDD ordering per `CLAUDE.md`:
1. Write ZMX-6.6 / ZMX-6.7 tests directly as real `@Test` cases in the relevant `*Tests.swift` file (no `*Todo.swift` inventory step needed since we're implementing now). Run `swift test` and confirm RED.
2. Update `attachArgv` (Sources/GrafttyKit/Zmx/ZmxLauncher.swift), `ZmxSpawnConfiguration.make`, `WebSession.start`, and `bashrcShim` (GREEN).
3. Fix existing argv assertions broken by the shape change (`buildsAttachArgvForWrappedShellAndRequiredEnv`, `bashUsesAgentHookWrappedShellWhenHooksAreEnabled`, `disabledHooksUseRawShellAndDoNotSetHookEnv`, the `HostManagedZmxBackendTests` literal at line 281).
4. Run full `swift test` to catch unrelated regressions.
5. Run `scripts/generate-specs.py` and commit `SPECS.md` alongside the code.
6. `/simplify`, then PR.

Note per memory: `swift test` on macOS misses UIKit-guarded code paths, so iOS CI is the real check. This work doesn't touch UI/iOS, so `swift test` here should be definitive.
