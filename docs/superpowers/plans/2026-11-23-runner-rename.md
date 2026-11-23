# Runner Rename Implementation Plan (PR 1 of 3)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rename the Linux headless binary, its systemd unit, its Swift target and its user-facing name from "host" to "runner", migrating existing installs without running two services.

**Architecture:** The archive ships `bin/graftty-runner` plus a `bin/graftty-host` compatibility launcher that runs the same executable. The installer writes `graftty-runner.service` and, when it finds a legacy `graftty-host.service`, converts it inside the existing rollback envelope. Mac-side scripts address the runner through one helper that falls back to the legacy name, so a new Mac can still update an install that has not been renamed.

**Tech Stack:** SwiftPM, Swift Testing, Bash, Python `unittest` (`scripts/linux/test-packaging.py`), Docker.

**Spec:** `docs/superpowers/specs/2026-11-23-remote-runner-setup-design.md` (section "Names" and "Updating and existing runners"). PRs 2 (Tailcat in the runner, invites) and 3 (the new sheet) get their own plans when this one has merged.

## Global Constraints

- Names: binary and launcher `graftty-runner`; unit `graftty-runner.service`; executable target `GrafttyRunner`; test target `GrafttyRunnerTests`.
- `GrafttyHostAgent` keeps its name. **Add Remote Mac…** and the **Remote Hosts** title stay.
- Menu items: **Add Remote Runner…** and **Update Runner…**.
- State directories, identity files and `host.lock` keep their paths.
- A machine never runs both units. A failed update leaves the legacy unit installed, enabled and running as it was.
- Transport, ports and bind addresses do not change in this PR.
- Every changed requirement keeps its spec ID; update the EARS text in the test title, then run `scripts/generate-specs.py`. No literal quotes in `@spec` titles.
- Run Swift through `scripts/swiftpm`. Never pass `--skip-build`.
- No type or file named `LinuxHost*` is renamed here; that churn belongs to PR 3, which rewrites most of them.

## Review Focus

1. Legacy unit present but stopped when an update runs: the update must refuse as today ("Maintenance requires the existing user service to be active") and change nothing.
2. Update fails after the legacy unit was converted: the legacy unit file, its enablement and its running state are restored, and no `graftty-runner.service` remains.
3. A saved AWS enrollment whose executable path ends in `/graftty-host`: the path still runs the runner after an update.
4. A new Mac inspecting an install that still has only `graftty-host`: inspection and update work.
5. A legacy unit with a drop-in or a second `ExecStart`: refused as today, unchanged.

---

### Task 1: Swift target, product and command name

**Files:**
- Move: `Sources/GrafttyHost/` → `Sources/GrafttyRunner/` (`GrafttyHost.swift` → `GrafttyRunner.swift`)
- Move: `Tests/GrafttyHostTests/` → `Tests/GrafttyRunnerTests/`
- Modify: `Package.swift:141,282,332-333`
- Modify: `scripts/check-linux-test-allowlist.py`, `scripts/test_check_linux_test_allowlist.py`

**Interfaces:**
- Produces: product `graftty-runner`; module `GrafttyRunner`; root command `commandName: "graftty-runner"`.

- [ ] **Step 1: Write the failing test** in `Tests/GrafttyRunnerTests/HostServiceTests.swift` (after the move), a Swift Testing test titled `@spec DIST-4.7: The Linux runner executable shall name itself graftty-runner in its usage text.` asserting `GrafttyRunner.helpMessage().contains("graftty-runner")` and that it does not contain `graftty-host`. Use the next free DIST-4 number if 4.7 is taken (`grep -n "DIST-4\." SPECS.md`).
- [ ] **Step 2: Run** `scripts/swiftpm test --filter GrafttyRunnerTests`. Expected: build failure, module `GrafttyRunner` not found.
- [ ] **Step 3: Move the directories with `git mv`**, rename the root command type to `GrafttyRunner`, set `commandName: "graftty-runner"`, and update `Package.swift` and both allowlist scripts.
- [ ] **Step 4: Run** `scripts/swiftpm test --filter GrafttyRunnerTests` and `python3 -B scripts/test_check_linux_test_allowlist.py && python3 -B scripts/check-linux-test-allowlist.py`. Expected: the new test's own "passed" line, and both scripts exit 0.
- [ ] **Step 5: Commit** `Rename the GrafttyHost target and command to GrafttyRunner`.

### Task 2: Archive layout and launchers

**Files:**
- Modify: `scripts/linux/package.sh`, `scripts/linux/launcher.sh`, `scripts/linux/smoke-test.sh`
- Modify: `scripts/linux/runner/Dockerfile`, `scripts/linux/runner/smoke-test.sh`, `scripts/linux/runner/test-runner.py`
- Modify: `scripts/windows/wsl-install.py`, `scripts/windows/test-wsl-install.py`
- Test: `scripts/linux/test-packaging.py`, `Tests/GrafttyKitTests/HostSetup/LinuxHostPackagingTests.swift`, `Tests/GrafttyKitTests/HostSetup/LinuxRunnerPackagingTests.swift`

**Interfaces:**
- Produces: archive entries `bin/graftty-runner`, `bin/graftty-host` (compatibility launcher), `libexec/graftty-runner`. No `libexec/graftty-host`.

- [ ] **Step 1: Write the failing tests.** In `LinuxHostPackagingTests` change the DIST-4.1 expected suffix list to `/bin/graftty-runner`, `/bin/graftty-host`, `/libexec/graftty-runner` and reword its title to say runner. In `test-packaging.py` add `test_legacy_launcher_runs_the_runner`: build the fake archive, run `bin/graftty-host --help`, assert it executes `libexec/graftty-runner`.
- [ ] **Step 2: Run** `python3 scripts/linux/test-packaging.py` and `scripts/swiftpm test --filter LinuxHostPackagingTests`. Expected: both fail on the missing `graftty-runner` entries.
- [ ] **Step 3: Implement.** `package.sh` builds product `graftty-runner`, installs it to `libexec/graftty-runner`, and installs the launcher under `graftty`, `graftty-runner` and `graftty-host`. `launcher.sh` gains the arm `graftty-runner|graftty-host) exec "$bundle/libexec/graftty-runner" "$@" ;;`. Dockerfile health check and entrypoint, both smoke tests and the WSL installer's required-file and binary lists use `graftty-runner`. The Dockerfile description label reads `Graftty remote runner and persistent terminal runtime`.
- [ ] **Step 4: Run** the two commands from Step 2 plus `python3 scripts/windows/test-wsl-install.py` and `python3 scripts/linux/runner/test-runner.py`. Expected: all pass.
- [ ] **Step 5: Commit** `Ship graftty-runner in the Linux archive with a graftty-host launcher`.

### Task 3: Installer unit rename and legacy migration

**Files:**
- Modify: `Sources/GrafttyKit/HostSetup/Resources/linux-install.sh` (`scripts/linux/install.sh` is a symlink to it)
- Test: `scripts/linux/test-packaging.py`

**Interfaces:**
- Consumes: archive layout from Task 2.
- Produces: unit `graftty-runner.service` with `Description=Graftty remote runner`; links `~/.local/bin/{graftty,graftty-runner,graftty-host,zmx}`.

The installer chooses its unit once, near where `service_file` is set today:

```bash
legacy_file="$config_home/systemd/user/graftty-host.service"
service_file="$config_home/systemd/user/graftty-runner.service"
legacy=0
if [[ ! -f $service_file && -f $legacy_file ]]; then legacy=1; fi
active_unit=graftty-runner.service
((legacy)) && active_unit=graftty-host.service
```

Every inspection that runs before the swap (`is-active`, `show`, `cat`, `stop`) uses `$active_unit`; everything after the swap uses `graftty-runner.service`. `had_service` and `service_backup` track whichever file existed.

- [ ] **Step 1: Write the failing tests** in `test-packaging.py`, reusing its fake-`systemctl` log pattern:
  - `test_fresh_install_writes_runner_unit`: the log's last lines are `--user daemon-reload`, `--user enable graftty-runner.service`, `--user restart graftty-runner.service`; no `graftty-host.service` file exists; `ExecStart` names `/bin/graftty-runner`.
  - `test_maintenance_migrates_legacy_unit`: start from a legacy unit carrying `--bind-address 0.0.0.0 --ssh-port 8801`, `Environment=FOO=bar` and `KillMode=process`. After `--maintenance`: `graftty-runner.service` holds the same options and environment with `ExecStart` pointing at the new release's `/bin/graftty-runner`; the legacy file is gone; the log contains, in order, `--user stop graftty-host.service`, `--user disable graftty-host.service`, `--user enable graftty-runner.service`, `--user restart graftty-runner.service`.
  - `test_failed_migration_restores_legacy_unit`: make the new launcher's `status` never report running with `GRAFTTY_INSTALL_READY_TIMEOUT_SECONDS=1`. Afterwards the legacy file's text equals its original, `graftty-runner.service` does not exist, and the log ends with `--user enable graftty-host.service`, `--user start graftty-host.service`.
  - `test_maintenance_refuses_inactive_legacy_unit`: fake `is-active` fails; exit status non-zero, legacy file unchanged, no release directory created.
  - `test_legacy_command_link_is_kept`: after any install `~/.local/bin/graftty-host` resolves into the new release's `bin/graftty-host`.
  - Change every existing assertion in the file from the host unit and binary names to the runner names, except where a test sets up a legacy install on purpose.
- [ ] **Step 2: Run** `python3 scripts/linux/test-packaging.py`. Expected: the five new tests fail; note which existing tests fail only on names.
- [ ] **Step 3: Implement** in `linux-install.sh`:
  - `commands=(graftty graftty-runner graftty-host zmx)` for link creation and rollback.
  - `old_release` resolves from `~/.local/bin/graftty-runner` when that link exists, otherwise from `~/.local/bin/graftty-host`.
  - The embedded Python unit rewrite takes the old and new launcher names as arguments: it requires `old + '/bin/' + old_name` in the `ExecStart` line and writes `new + '/bin/graftty-runner'`.
  - After the release is in place and the new unit file is written: when `legacy`, run `systemctl --user disable graftty-host.service`, remove the legacy file, and run `systemctl --user enable graftty-runner.service` even in maintenance mode.
  - `cleanup` on failure when `legacy`: stop `graftty-runner.service`, remove its file, restore the legacy file from the backup, `daemon-reload`, `enable graftty-host.service`, and start it if it was running.
  - The readiness loop calls `"$release/bin/graftty-runner" status --json`. Messages say "runner" where they said "host".
- [ ] **Step 4: Run** `python3 scripts/linux/test-packaging.py`. Expected: `OK`, with each new test name in the verbose output (`-v`).
- [ ] **Step 5: Commit** `Install graftty-runner.service and migrate a legacy host unit`.

### Task 4: Mac-side scripts address the runner, with a legacy fallback

**Files:**
- Modify: `Sources/GrafttyKit/HostSetup/LinuxHostScripts.swift`, `LinuxHostSetup.swift:103,116`, `LinuxHostMaintenanceScripts.swift`
- Modify: `Sources/GrafttyKit/Host/HostAgentSetup.swift:71`, `Sources/GrafttyKit/Providers/ProviderHostEnrollment.swift:33`, `Sources/GrafttyKit/Providers/AWSHostEnrollment.swift`, `Sources/GrafttyCLI/Provider.swift`, `Sources/GrafttyCLI/ProviderProbe.swift`
- Test: `Tests/GrafttyKitTests/HostSetup/LinuxHostSetupExecutionTests.swift`, `LinuxHostMaintenanceTests.swift`, `LinuxHostSetupTests.swift`

**Interfaces:**
- Produces, in `LinuxHostScripts`:
  - `static let runnerCommand: String` — a POSIX shell fragment that expands to the installed launcher: `"$(if [ -x "$HOME/.local/bin/graftty-runner" ]; then echo "$HOME/.local/bin/graftty-runner"; else echo "$HOME/.local/bin/graftty-host"; fi)"`.
  - The staged-archive executable check iterates `graftty-runner graftty zmx` and falls back to `graftty-host` only when the archive has no `bin/graftty-runner`.
- In `LinuxHostMaintenanceScripts.identityPython`: `host` is `~/.local/bin/graftty-runner` when it exists, else `~/.local/bin/graftty-host`. `serviceOwnershipPython` reads `MainPID` from `graftty-runner.service` when its unit file exists under the user's systemd directory, else from `graftty-host.service`.

- [ ] **Step 1: Write the failing tests.**
  - `LinuxHostSetupExecutionTests`: the recorded `trust-client` and `project add` commands contain `graftty-runner` and the fallback to `graftty-host`; update the REMOTE-21.13 title and its fixture list (`["graftty-runner", "graftty", "zmx"]`), and add a case where the staged archive has only `graftty-host` and the check still passes.
  - `LinuxHostMaintenanceTests`: parameterize the existing inspection test over an install with a `graftty-runner` link and one with only `graftty-host`; both must return the identity.
  - `LinuxHostSetupTests:37`: the incompatible-archive message fixture uses `GRAFTTY_INCOMPATIBLE:graftty-runner`.
- [ ] **Step 2: Run** `scripts/swiftpm test --filter "LinuxHostSetup|LinuxHostMaintenance"`. Expected: the new and changed assertions fail.
- [ ] **Step 3: Implement** the helper and use it at both call sites in `LinuxHostSetup.swift`; update the two Python fragments; change user-facing strings in the listed files from `graftty-host` to `graftty-runner`. `--host-executable` and `--host-state-directory` keep their flag names.
- [ ] **Step 4: Run** the Step 2 command. Expected: each changed test's own "passed" line.
- [ ] **Step 5: Commit** `Address the runner by its new name from the Mac, falling back for legacy installs`.

### Task 5: Menu labels and messages

**Files:**
- Modify: `Sources/Graftty/Views/RemoteMacConnectionsPopover.swift:53,127`, `RemoteMacsSection.swift:393`, `LinuxHostSetupSheet.swift:47,137`, `LinuxHostMaintenanceSheet.swift`, `MainWindow.swift:1313`
- Modify: `Sources/GrafttyCLI/RemoteSetupLinux.swift`
- Test: the tests that assert these strings (`grep -rn "Set Up Linux Host\|Update Host" Tests`)

**Interfaces:**
- Produces: labels `Add Remote Runner…` and `Update Runner…`; sheet titles `Add a Remote Runner` and `Update Runner`; alert title `Could not prepare remote runner setup`; `graftty remote add-runner` as an alias of `setup-linux` (`aliases: ["add-runner"]`).

- [ ] **Step 1: Write the failing tests.** Update each `@spec` title and assertion found by the grep to the new labels, and add to `Tests/GrafttyTests/Specs/` a test that parses `["remote", "add-runner", "user@host", "--version", "1.2.3"]` into the same command type as `setup-linux` (next free REMOTE-21 number).
- [ ] **Step 2: Run** `scripts/swiftpm test --filter "LinuxSetup|LinuxHostMaintenanceEligibility|RemoteMac"`. Expected: the changed assertions fail.
- [ ] **Step 3: Change the strings and add the alias.** Both popover and sidebar labels use the same ellipsis character `…`.
- [ ] **Step 4: Run** the Step 2 command. Expected: pass lines for each changed test.
- [ ] **Step 5: Commit** `Call the Linux host a remote runner in menus and the CLI`.

### Task 6: Docs and SPECS

**Files:**
- Create: `docs/remote-runner.md` from `docs/linux-host.md` followed by `docs/docker-runner.md`'s content as a "Run the runner in Docker" section
- Delete: `docs/linux-host.md`, `docs/docker-runner.md`
- Modify: `README.md:44,122`, `docs/windows-host.md:4,146`, `docs/cli.md`, `SPECS.md` (generated)

- [ ] **Step 1: Merge the two documents**, replacing the binary, unit and menu names. Keep every step that is still true in this PR, including port 8801 reachability and the Docker pairing through **Add Remote Mac…**; those change in PR 2. Add one paragraph on updating an older install: the update converts `graftty-host.service` and keeps `~/.local/bin/graftty-host` working.
- [ ] **Step 2: Fix links** found by `grep -rn "linux-host.md\|docker-runner.md" . --exclude-dir=.git --exclude-dir=docs/superpowers`. Expected afterwards: no matches.
- [ ] **Step 3: Regenerate** with `scripts/generate-specs.py`, then run `scripts/generate-specs.py --check`. Expected: exit 0.
- [ ] **Step 4: Full gate.** `scripts/swiftpm test`, `python3 scripts/linux/test-packaging.py`, and `grep -rIn "graftty-host" . --exclude-dir=.git --exclude-dir=.deps --exclude-dir=node_modules --exclude-dir=docs/superpowers`. Expected: tests pass; the grep shows only the compatibility launcher, legacy-migration code and tests, the fallback helper, the historical test report under `docs/testing/`, and unrelated temp-file names in `Tests/GrafttyMobileKitTests`.
- [ ] **Step 5: Linux check.** In `swift:6.4.2-noble`, build with `scripts/linux/package.sh` and run `scripts/linux/smoke-test.sh` on the archive, then `scripts/linux/runner/build.sh` and `scripts/linux/runner/smoke-test.sh`. Expected: both smoke tests exit 0.
- [ ] **Step 6: Commit** `Merge the Linux host and Docker runner guides into one runner guide`.
