# zmx Integration — Phase 1 Design Specification

Phase 1 of bringing [zmx](https://zmx.sh) ([source](https://github.com/neurosnap/zmx)) into Espalier. Every Espalier pane's PTY child becomes `zmx attach <session>` instead of `$SHELL`, so terminal sessions survive Espalier quits, crashes, and relaunches. The native UX is otherwise unchanged.

## Multi-Phase Context

This spec covers Phase 1 only. The full integration arc has three phases:

- **Phase 1 (this spec):** zmx as the PTY backing for every Espalier pane. Survival of running shells across app quits. Native UI unchanged.
- **Phase 2 (future spec):** WebSocket server bound on the Tailscale interface, gated by Tailscale `WhoIs` identity. Initial minimal web client to validate the protocol.
- **Phase 3 (future spec):** Full TanStack-based web client (TanStack Router + TanStack DB + xterm.js) mirroring the native sidebar/split layout, with a mobile collapse where the session picker is its own pane and splits flatten to a horizontal pager.

Phases 2 and 3 are out of scope for this spec but are referenced where Phase 1 decisions create or close doors for them.

## Goal

After Phase 1 ships, this user story works:

> I open Espalier, switch to a worktree, and start a long-running build (`cargo build`, `npm run dev`, etc.). I quit Espalier (Cmd-Q). The build keeps running. I relaunch Espalier; my terminal panes restore with the build's full output visible in scrollback, the build still running.

The same survival applies to a crash of Espalier (kill -9, OS forced exit). It does **not** apply to OS reboot — zmx daemons exit on shutdown unless wrapped by `launchd`, which is deferred to a later phase.

## Architecture

One `zmx` daemon per Espalier pane. The pane's libghostty surface owns a PTY whose child is `zmx attach espalier-<short-pane-id>`. zmx in turn spawns `$SHELL` as the daemon's child and proxies PTY bytes between the shell and the attached client (Espalier's surface). Pane lifetime is intentionally decoupled from daemon lifetime — that decoupling is the whole point.

```
Espalier process                         zmx daemon process(es)              shell process(es)
┌───────────────────────────┐            ┌───────────────────────┐          ┌──────────────┐
│ libghostty Surface        │            │ zmx daemon            │          │ $SHELL       │
│   ↕ PTY                   │◄──socket──►│   - libghostty-vt     │◄──PTY───►│              │
│ zmx attach <session>      │            │   - PTY <-> client mux│          │              │
└───────────────────────────┘            └───────────────────────┘          └──────────────┘
       (lives with pane)                  (survives Espalier quit)        (survives Espalier quit)
```

When Espalier quits, the leftmost box dies; the middle and right boxes survive. On relaunch, Espalier creates a fresh leftmost box and `zmx attach` reconnects to the same daemon, which replays the screen state to libghostty's renderer.

### Bundling

The `zmx` binary is bundled inside the app at `Espalier.app/Contents/Helpers/zmx`, mirroring the existing `espalier` CLI placement (per `ATTN-1.1`). MIT license permits bundling. The vendored binary is universal (arm64 + x86_64 via `lipo`) and re-signed with Espalier's developer ID at app-build time.

### Session-name scheme

`espalier-<pane-uuid-short>`, where `<pane-uuid-short>` is the first 8 hex characters of the pane's UUID. Pane UUIDs are already stable across launches (persisted in `state.json` per the `PERSIST` specs), so deriving the session name from the pane id makes reattach automatic — no separate session-name field needs storage. 8 hex chars = 32 bits, ample uniqueness within a single user's `ZMX_DIR` namespace.

### Sandboxing zmx state

Espalier sets `ZMX_DIR=~/Library/Application Support/Espalier/zmx/` in the env it hands to every spawned `zmx attach`. This scopes Espalier's daemons to a private socket directory. A user's personal `zmx list` in Terminal.app uses the default `XDG_RUNTIME_DIR` / `TMPDIR` and won't see Espalier sessions, and vice versa. Clean separation, no accidental collisions.

### What does NOT change

- libghostty remains the renderer. `SurfaceHandle.swift` still owns its `Ghostty.Surface`.
- `TerminalManager.swift` still orchestrates pane lifecycle.
- All keyboard, clipboard, mouse, focus, PWD-routing (section 7), attention (section 5), shell integration (section 9), and persistence (section 6) specs stay valid.
- The only mechanical change is the argv handed to libghostty when asking it to spawn a process for a new surface.

## Components

### Modified — `Sources/Espalier/Terminal/`

- **`TerminalManager.swift`** — gains a `ZmxLauncher` collaborator. Pane-creation paths (`createPane`, restore-from-state) ask `ZmxLauncher` for the argv to hand libghostty. Pane-destruction paths (`closePane`, stop-worktree) call `ZmxLauncher.kill` for the matching session.
- **`GhosttyBridge.swift`** — when libghostty asks for the spawn command for a new surface, route through `ZmxLauncher`. Today this is implicit ("just use the shell"); after, it's explicit.
- **`SurfaceHandle.swift`** — no behavior change. Each handle still owns one libghostty surface. Gains a stored `zmxSessionName: String` for diagnostics and future use.

### New — `Sources/EspalierKit/Zmx/`

- **`ZmxLauncher.swift`** — pure-Swift, no UI deps. Owns:
  - Bundled-binary path resolution (`Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/zmx")`, mirroring the existing `espalier` CLI resolver at `EspalierApp.swift:643`; dev-mode fallback to `PATH`).
  - `sessionName(for paneID: UUID) -> String` — deterministic `"espalier-" + paneID.short()`.
  - `attachArgv(sessionName:env:) -> (argv: [String], env: [String:String])` — returns `[zmxPath, "attach", sessionName, "$SHELL"]` plus env including `ZMX_DIR`, `ESPALIER_SOCK`, `GHOSTTY_RESOURCES_DIR`, and the user's existing env. Working directory is *not* a parameter: libghostty sets the PTY child's cwd via its own spawn API, and `zmx attach` inherits it.
  - `kill(sessionName:)` — runs `zmx kill --force <name>` via `ZmxRunner` on a background queue. The UI does not await completion; the call logs success/failure but returns to the caller immediately.
  - `listSessions() throws -> Set<String>` — runs `zmx list --short` synchronously, parses, returns the set of session names known to zmx. Used at launch reconciliation.
  - `isAvailable: Bool` — was the bundled binary found and exec-able?
- **`ZmxRunner.swift`** — sync subprocess wrapper, three flavors mirroring `GitRunner`'s shape (`run`, `capture`, `captureAll`). Differences: injectable executable URL (not hardcoded) and env-passing support. Used by `ZmxLauncher.kill` and `.listSessions`. Not used for `attach`; that argv is handed to libghostty directly.

A future Phase 2 may motivate promoting `GitRunner` and `ZmxRunner` to a shared `ProcessRunner`. Don't pre-factor; do it when a third consumer arrives.

### Build / packaging

- **`Resources/zmx-binary/`** — committed directory holding `zmx` (universal binary), `VERSION`, and `CHECKSUMS`. Three files only.
- **`Package.swift`** — add a Resource entry to copy `Resources/zmx-binary/zmx` into the Espalier target as an auxiliary executable.
- **`scripts/bump-zmx.sh`** — manual bump script. Logic:
  1. `gh api repos/neurosnap/zmx/releases/latest --jq .tag_name` → discover latest version.
  2. For each arch (`arm64`, `x86_64`): `curl -fL https://zmx.sh/a/zmx-<version>-macos-<arch>.tar.gz`, extract the `zmx` binary.
  3. `lipo -create` into universal `Resources/zmx-binary/zmx`.
  4. Compute and write `Resources/zmx-binary/CHECKSUMS` (SHA256 of each per-arch artifact + the universal). Re-runs verify against the stored checksum and abort if zmx.sh has silently mutated a published artifact.
  5. Write `Resources/zmx-binary/VERSION` with the new version.
  6. Print a diff summary; maintainer reviews and commits.

  No GitHub Actions workflow in Phase 1 — keeping a human in the loop on what binary lands in the repo.
- **App bundle install** — extend the existing post-build step that installs `espalier-cli` as `Contents/Helpers/espalier` to also install `Contents/Helpers/zmx`. Re-codesign as part of the same step.

### SPECS.md addition

A new section **13. zmx Session Backing** is added to `SPECS.md`, immediately after section 12 (Technology Constraints). It captures Phase 1's requirements in EARS form: bundling, session naming, sandbox via `ZMX_DIR`, lifecycle mapping (create / restore / kill / stop / app-quit), fallback when zmx is unavailable, and the explicit "shell integration / OSC sequences pass through unchanged" guarantee.

Existing sections (3.x terminal lifecycle, 6.x persistence, 9.x shell integration) get small clarifying notes that they continue to hold and are now mediated by zmx.

## Data Flow

### Flow 1 — New pane created

1. User triggers split / opens worktree → `TerminalManager.createPane(in: worktree)`.
2. Manager allocates `paneID = UUID()`, creates a `SurfaceHandle`.
3. Manager calls `ZmxLauncher.attachArgv(sessionName: launcher.sessionName(for: paneID), env: defaultEnv)`. The worktree path is passed to libghostty separately, as today, via libghostty's `working_directory` spawn parameter.
4. `ZmxLauncher` returns `[<bundledZmxPath>, "attach", "espalier-<short>", "$SHELL"]` + env including `ZMX_DIR`, `ESPALIER_SOCK`, `GHOSTTY_RESOURCES_DIR`.
5. `GhosttyBridge` hands the argv + env to libghostty's `ghostty_surface_new`.
6. libghostty forks a PTY child running `zmx attach …`. zmx contacts/creates the daemon. The daemon forks `$SHELL`. PTY bytes flow: shell ↔ daemon ↔ `zmx attach` client ↔ libghostty surface ↔ renderer.
7. `state.json` records the pane with `paneID` (existing PERSIST behavior). The session name is *derived* from `paneID`, not separately stored.

### Flow 2 — Espalier launches with existing `state.json`

1. Existing `PERSIST-3.x` flow restores repos, worktrees, and split-tree topology.
2. For each worktree where `wasRunning == true`, `TerminalManager` walks the split tree.
3. For each leaf pane, manager calls `ZmxLauncher.attachArgv(...)` with the pane's existing `paneID` → derives the same session name as before.
4. `zmx attach` either reattaches (daemon survived Espalier's quit → screen state restored from libghostty-vt buffer) or creates fresh (daemon didn't survive, e.g., reboot → blank shell starts).

### Flow 3 — User closes a pane

1. `TerminalManager.closePane(paneID)` triggered by user input (Cmd-W, context menu) OR by libghostty's surface-exit callback (the shell exited on its own).
2. Manager removes the pane from the split tree (existing `TERM-5.x` behavior).
3. Manager calls `ZmxLauncher.kill(sessionName: launcher.sessionName(for: paneID))`.
4. zmx kills the daemon and `$SHELL`. Socket file removed. Session is gone.
5. If the shell exited first, the session may already be gone by the time we run `zmx kill`. The kill returns nonzero; we ignore it (idempotent).

### Flow 4 — User selects "Stop worktree"

1. Existing `TERM-6.1` / `TERM-6.2` confirmation flow.
2. On confirm, manager iterates the worktree's split tree leaves.
3. For each leaf: close the libghostty surface (existing) AND call `ZmxLauncher.kill(sessionName:)` on the corresponding session.
4. Topology preserved on disk per `TERM-6.2`; next launch this worktree starts fresh shells in the same layout.

### App quit

No explicit flow — falls out of OS process tear-down. AppKit termination → libghostty surfaces destruct → PTYs close → `zmx attach` clients see EOF and exit cleanly. Daemons live on. No extra code.

## Error Handling

The principle throughout: **Espalier must remain usable even if zmx is broken.**

### At app launch / first pane creation

- **Bundled `zmx` binary missing or not executable** — `ZmxLauncher.isAvailable == false`. All future `attachArgv` calls return the legacy `$SHELL` argv. Show a one-time, dismissible alert: "zmx unavailable — terminals won't survive quit." Log the cause (file missing? wrong arch? gatekeeper rejection?). Espalier behaves exactly like today's main branch.
- **`ZMX_DIR` not writable** — try to create `~/Library/Application Support/Espalier/zmx/` at first launch. On failure, log and fall back to letting zmx use `TMPDIR`. Espalier's sessions then live alongside any user-private zmx sessions; not ideal but not broken.
- **Codesigning / notarization failure** — bundled zmx must be re-signed with Espalier's developer ID and included in the notarization manifest. The release build script verifies with `codesign -dv` before producing the .app. A CI test asserts the bundled binary is loadable. Without this, macOS Gatekeeper silently kills the spawn and Flow 1 step 6 fails with no obvious cause.

### At pane spawn

- **`zmx attach` fails to exec** (dynamic linker error, etc.) — libghostty surface sees the child exit immediately. A guard: if the spawned PTY child exits within 250ms with a nonzero status, log loudly and surface a one-line attention badge on the affected worktree ("zmx failed: see logs"). Don't auto-fall-back to direct `$SHELL` per-pane — that masks systemic problems and creates a confusing two-tier experience.
- **`zmx attach` hangs** — no timeout in v1. libghostty's surface stays open with no output; the user sees a blank pane. Fix is the same as any unresponsive shell: close the pane. Debug-build assertion flags a session producing no output for 30s, but release builds don't act on it.

### At pane teardown

- **`zmx kill` fails because the session is already gone** — expected when the shell exited first. Treat any nonzero exit from `zmx kill --force` as informational, not an error. Logged at debug level.
- **`zmx kill` fails because the daemon is unresponsive** — rare. Log at warning level; leave the daemon dangling; proceed with pane removal in our model. A periodic reap pass on next launch (`zmx list` minus our model) catches and force-cleans stragglers.

### At launch reconciliation

- **`zmx list` returns malformed output** (zmx version skew) — treat as empty list. Each `zmx attach` is idempotent — it creates the session if missing — so the worst case is we lose the "session restored" UI hint, not the survival guarantee.

### Out of scope for Phase 1

- Reattach across reboots — needs a launchd helper to keep zmx daemons alive across shutdown. Phase 2-ish concern.
- Two Espalier instances sharing one `ZMX_DIR` — works correctly (it's actually the multi-client win) but in dev causes confusion. Document; don't fix.
- Architecture mismatch — the universal binary handles arm64+x86_64. CI verifies via `lipo -info`.

## Testing

### Unit tests — `ZmxLauncherTests` (`Tests/EspalierKitTests/`)

Pure logic, no zmx subprocess required.

- `attachArgv` produces the expected `[path, "attach", session, "$SHELL"]` and env shape.
- Session-name derivation from a `UUID` is deterministic and stable. **Regression test that the session-naming function never changes its output for a given UUID** — a change orphans every existing user session.
- `parseListOutput` handles empty lists, single sessions, many sessions, the leading `session_name=` / `pid=` prefixes from `zmx list`'s tab-separated format, malformed lines (graceful skip).
- `kill(sessionName:)` argv composition.
- `isAvailable` returns `false` when the bundled-binary URL resolves to a missing path.

### Integration tests — `ZmxLauncherIntegrationTests`

Run only when `zmx` is on `PATH` (`try XCTSkipUnless(...)` otherwise — preserves "tests pass without zmx installed" for new contributors). Each test isolates state with a `setUp`-allocated `ZMX_DIR` under `NSTemporaryDirectory()`; `tearDown` force-kills any remaining sessions.

- Spawn `attach` against a fresh session, send `echo hello\n` over the PTY, read until "hello" appears, `kill`, verify gone via `list`.
- Spawn, kill, spawn-again-with-same-name, verify reattach restores a marker (write `MARKER` then reattach reads `MARKER` from history). **This is the survival contract.**
- Spawn, simulate a clean PTY close (detach), verify session persists in `list`. Reattach reads back the marker.
- Concurrent `kill` calls on the same session don't both error.

### End-to-end — `TerminalManagerSurvivalTests`

Exercises the macOS app's spawn pathway, no UI.

- Build a `TerminalManager` with a fake `Worktree`. Create a pane. Send `echo MARKER`. Tear down `TerminalManager` (simulating app quit) without `zmx kill`. Build a *new* `TerminalManager` for the same pane id. The reattached surface contains `MARKER` in its replayed scrollback. **This is the spec acceptance test.**

### Test infrastructure

- `withScopedZmxDir(_ body: …)` — creates a temp `ZMX_DIR`, runs the body, force-kills any leaked sessions on exit. Used by every integration test.
- `#requireZmx()` — a small precondition macro that skips when zmx is unavailable.

### Manual smoke tests

Codified as a checklist in this spec; the maintainer runs them before each release:

1. Open Espalier; create a worktree; type `echo hello`; quit Espalier; relaunch — `hello` is still visible in the scrollback.
2. With Espalier closed, `ZMX_DIR=~/Library/Application\ Support/Espalier/zmx/ zmx list` shows your panes.
3. Delete the bundled `zmx` from a debug build; relaunch; new panes work via direct `$SHELL` (with the warning banner). No crashes.
4. Stop a worktree; `zmx list` shows the relevant sessions are gone.

### What we deliberately don't test

- libghostty's behavior under zmx — bytes are bytes; if VT bytes flow we trust libghostty.
- zmx's correctness — out of scope; we don't own that code.
- Reboot survival — Phase 2-ish concern.

## Architectural Notes

### zmx and Espalier both use libghostty

zmx 0.5.0 statically links the `ghostty-vt` Zig module from the Ghostty repo (pinned in `build.zig.zon`). Espalier links the full libghostty (renderer included) via the `libghostty-spm` Swift package. So the integration is two libghostty builds in our process tree doing complementary jobs: Espalier renders the live stream; zmx replays the buffered state to a new client on reattach. This is the intended use of the `ghostty-vt` factoring — Mitchell explicitly split it out so projects like zmx could embed it.

The "double state-keeping" cost is real but not redundant: each side parses VT into the buffer it needs (a NSView-backed surface vs. a replay-friendly snapshot). We accept the duplication because it's the price of a clean CLI integration without IPC across the libghostty boundary.

### Version drift

Espalier's `libghostty-spm` and zmx's pinned `ghostty-vt` are different versions in practice. Both parse the same VT spec, so divergence is bounded. If zmx adds support for a new shell-integration OSC ahead of `libghostty-spm` (or vice versa), the lagging side may not handle it. We accept the risk; we'd notice in real workflows. Worth tracking the two version numbers in the About panel for diagnostics.

### Why no library handoff

zmx exposes only its CLI: `attach`, `run`, `kill`, `list`, `history`, `tail`, `wait`, `write`. There is no public C/Swift API and the per-session socket protocol is internal. The PTY between libghostty and `zmx attach` is therefore the only seam available. Sharing the screen buffer across the process boundary isn't reachable; an in-process integration would require maintaining a Swift binding to `ghostty-vt` ourselves, which is a substantially larger effort and isn't justified by Phase 1's goal.

### What this enables for Phases 2 and 3

Once every pane is zmx-backed, Phase 2's WebSocket server can offer terminal streams to a web client by speaking to the same daemons (via `zmx attach` from a child process, or by reading raw daemon sockets if we ever decide to). Phase 3's TanStack web client gets multi-client sessions for free — two Espalier-shaped clients (native + browser) can attach to the same daemon simultaneously, which is exactly the "open the same shell from my couch" experience.

## Acceptance Criteria

Phase 1 ships when all of the following hold:

1. The `ZmxSurvivalIntegrationTests.sessionSurvivesClientDetachAndReattachRestoresMarker` integration test passes (replaces the spec's original `TerminalManagerSurvivalTests` name; landed in `Tests/EspalierKitTests/Zmx/` because the Espalier app target has no test target). The end-to-end claim — quit Espalier, relaunch, scrollback marker is restored — is verified by manual smoke test #1 instead.
2. The four manual smoke tests above pass.
3. `Resources/zmx-binary/zmx` is committed; `bump-zmx.sh` runs cleanly.
4. The bundled `zmx` is re-signed and notarized as part of the release build.
5. `SPECS.md` section 13 is added. The pass-through guarantees in §13.6 explicitly reference `PWD-x.x`, `NOTIF-x.x`, and `KEY-x.x` and assert those requirements remain in force; no inline notes were added to §3, §6, or §9.
6. `swift test` passes including the new unit tests.
7. With the bundled `zmx` removed (debug build), Espalier launches, creates panes via direct `$SHELL`, surfaces the warning banner, and remains fully usable.
