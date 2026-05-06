# Recognize Server Processes — Design

**Status:** Approved (2026-05-06)

## Problem

When a user runs a dev server in a Graftty pane (`npm run dev`, `flask`, `cargo run`, etc.), they have no in-Graftty signal that something is listening, what port it's on, or how to reach it. They Cmd-Tab to a browser, type `localhost:3000`, and hope. We want the sidebar to passively recognize "this pane is serving on `:3000`" and surface that as an actionable affordance.

## Scope

A pane-scoped UI affordance — the **port chip** — rendered next to the pane title in the sidebar's `PaneTitleRow`, driven by a periodic scan of TCP listening sockets attributed to each pane's process subtree.

In scope:
- Detect TCP listeners owned by descendants of a pane's shell PID.
- Render one chip per `(port, scope)` pair on the responsible pane's row.
- Click chip → `NSWorkspace.shared.open` of `http://<host>:<port>/`.
- Visual distinction between loopback-only and LAN-exposed listeners.
- Multi-port, wrap-with-indent layout.
- Clean teardown on pane close, server crash, or worktree close.

Out of scope:
- UDP listeners (not browsable).
- HTTPS scheme inference (default to `http://`; rare TLS-on-dev cases the user can fix in the browser).
- Right-click menus on the chip (no Copy URL / Copy curl / etc.) — left-click only.
- Aggregate "ports running in this worktree" rollup on `WorktreeRow` — pane-only surface.
- Tracking ports across pane drag-moves with explicit migration logic (the existing stable `PaneID` makes this automatic).
- Surfacing ports on collapsed (closed/non-running) worktrees — they have no pane rows to render against.
- Notifying the user when a port appears/disappears — passive surface only.

## Components

### `PortScanner` (actor, `GrafttyKit`)

The system boundary. Owns the polling loop, exec of `lsof`, parsing, dedupe, and the per-pane snapshot diff.

```swift
public actor PortScanner {
    public func registerPane(_ id: PaneID, shellPID: pid_t)
    public func unregisterPane(_ id: PaneID)
    public func bindings(for id: PaneID) -> [PortBinding]   // current snapshot
    // Publishes via @MainActor proxy `PortBindingsModel` (see below).
}

public struct PortBinding: Hashable, Sendable {
    public let port: UInt16
    public let scope: BindScope          // .loopback | .lan
    public let processName: String       // for tooltip / a11y
    public let pid: pid_t                // lowest pid for the (port, scope) when forked
}

public enum BindScope: Sendable { case loopback, lan }
```

### `PortBindingsModel` (`@MainActor`, observable)

A thin SwiftUI-facing proxy. Holds `[PaneID: [PortBinding]]` and republishes on change. SwiftUI views read this; the actor pushes diffs.

### `PortChip` (view, `Graftty/Views`)

```swift
struct PortChip: View {
    let binding: PortBinding
    var body: some View { /* personalhotspot/globe + ":<port>" pill */ }
}
```

- Leading SF Symbol: `personalhotspot` for `.loopback`, `globe` for `.lan`.
- Text: `:<port>`.
- Tooltip via `.help(...)`: `"Open http://localhost:<port>/"` — always `localhost`, since the same-machine browser reaches both loopback- and `0.0.0.0`-bound listeners through it. The icon (not the URL) is what communicates LAN exposure.
- Click: `NSWorkspace.shared.open(URL(string: "http://localhost:<port>/")!)`.
- Accessibility label: `"Open <process-name> on port <port> (LAN-reachable | localhost-only)"` — the parenthetical disambiguates scope for users who can't see the icon.

### `PaneTitleRow` integration (modify, `Graftty/Views/WorktreeRow.swift`)

Existing layout becomes:

```
[↳ fixed-width column] [flex-wrap container: title + 0..N PortChips]
```

The wrap container holds `Text(title)` followed by chips. When chips overflow, they wrap *inside* this container, which is itself indented from the row's left edge by the `↳` column — so wrapped chips align under the title text, not flush left.

`PaneTitleRow.attentionText` (the existing `AttentionCapsule` path) takes precedence — when a pane is showing a red attention capsule, port chips are hidden until the capsule clears. (Two simultaneous decorations would compete for the same horizontal space.)

### Pane registration plumbing

`TerminalManager` (or whichever owner of pane lifecycle) calls `scanner.registerPane(id:shellPID:)` when a pane is added and `unregisterPane(id:)` when it's closed. No magic — explicit registration so the scanner is testable with synthetic PIDs.

## Data flow

```
                        every 2s tick (PollingTicker)
                                  │
                                  ▼
              for each registered pane:
                if foreground process is the pane's shell → skip
                else:
                  walk descendant PIDs of shellPID
                  ┌─────────────────────────────────┐
                  │  exec: lsof -nP -iTCP -sTCP:LISTEN
                  │        -p <pids,joined>          │
                  └─────────────────────────────────┘
                  parse → [(pid, port, addr, name)]
                  collapse: dedupe (pid, port) IPv4/IPv6 dual-bind
                  collapse: scope = .lan if any non-loopback bind exists
                                    else .loopback
                  diff vs previous snapshot for this pane
                  if changed: PortBindingsModel.update(paneID, bindings)
```

Properties:

- **Idle-pane gating.** A pane sitting at a `$ ` prompt — `foregroundIsShell == true`, the same signal that drives existing title rendering — is skipped entirely. No exec, no work.
- **Shared timer.** One `PollingTicker`-driven loop scans all eligible panes per tick, joining their PID sets into a single `lsof` invocation. Avoids per-pane Task lifetime bookkeeping.
- **Single-flight invariant.** If a previous tick is still in-flight when the next tick fires (rare; happens if `lsof` is slow under load), the new tick is dropped. No queueing.
- **Diff-before-publish.** The model is only re-assigned when the binding set for a pane actually changes, preventing SwiftUI invalidation churn on the sidebar (which has been hand-tuned for exactly this; see commits `81dd67f` "reduce sidebar title invalidation CPU" and `ccfaa5c` "batch worktree label computation").
- **Process-tree scoping = automatic noise filter.** Because we only consider descendants of pane shells, system services (`sshd`, `mDNSResponder`, `rapportd`, `cupsd`, AirPlay) are inherently excluded. No port allowlist/blocklist needed.

## Visual treatment

```
┌──────────────────────────────────┐
│ ⌥ api-server  feat/auth   +12 ↑3 │   ← worktree row (unchanged)
│   ↳ vim                          │   ← idle pane: no chip
│   ↳ npm run dev  (📡):3000       │   ← localhost-only: personalhotspot icon
│   ↳ flask         (🌐):5000      │   ← LAN-exposed: globe icon
│   ↳ next dev   (📡):3000  (📡):9229│ ← multi-port wraps inside the title
│                  (📡):24678       │   container, indented under title text
│ ⌂ root                           │
└──────────────────────────────────┘
```

- Chip is a 10.5pt pill: `personalhotspot` or `globe` SF Symbol + `:<port>` text, tabular numerics for vertical alignment when stacked.
- Pill background: theme.foreground at low opacity, neutral border. No green/amber color coding — the icon carries the loopback-vs-LAN distinction.
- Chips never get truncated; long titles ellipsize first.

## Edge cases & failure modes

**Process / port lifecycle**
- *Server crash* — next tick finds no listener; chip vanishes immediately. (No "linger and fade.")
- *Server restart on same port* — may briefly disappear and reappear across one tick; the ~2s flicker is honest about what happened.
- *PID rolls over* (e.g. `nodemon`) — different PID still rooted under the pane shell; scope filter picks it up.
- *Forked workers* (Node `cluster`, gunicorn) — multiple PIDs bind the same port. Dedupe by `(port, scope)`; show one chip; tooltip names the lowest PID's process.

**Bind-address quirks**
- *Dual-stack IPv6+IPv4 on the same port* (Node default: `0.0.0.0` + `::`) — one chip; scope `.lan`.
- *Loopback dual-stack* (`127.0.0.1` + `::1`) — one chip; scope `.loopback`.
- *Mixed bind* — broader scope wins: any non-loopback binding for `(pid, port)` ⇒ chip is `.lan`.

**Pane lifecycle**
- *Pane created* — `registerPane`; bindings empty until first non-empty scan.
- *Pane closed* — `unregisterPane`; cached snapshot dropped; chips disappear cleanly.
- *Pane dragged between worktrees* (PWD-1.4) — `PaneID` is stable; registration follows the pane automatically.
- *Pane has an active `AttentionCapsule`* — chips hidden until the capsule clears.

**System / scanner failures**
- *`lsof` not on `PATH` or non-zero exit* — log once, skip tick, snapshot stays empty. No retry loop, no user-visible error. (Same posture as existing `Process`-based loops in `WebServerController`.)
- *Permission denied for a PID* — `lsof` silently omits; that process's port simply doesn't render.
- *Slow scan (>2s)* — single-flight invariant drops the next tick; we don't queue.
- *Pane has thousands of descendant PIDs* — `lsof -p` accepts arbitrarily many comma-separated PIDs on macOS; if `ARG_MAX` becomes a real concern we'll batch, but we don't pre-optimize for it.

**Bind-port edge cases**
- *Port 0 / ephemeral* — `lsof` always reports the resolved port; we never see 0.
- *Privileged ports (<1024)* — rendered identically; no special UX.
- *UDP listeners* — explicitly excluded (`-iTCP` flag).

## Specifications (`PORTS-` prefix)

`PORTS-1` (scanner discipline)
- `PORTS-1.1`: When a pane's foreground process is non-shell, the application shall scan that process subtree's TCP listening sockets every 2 seconds.
- `PORTS-1.2`: While a pane's foreground process is the shell, the application shall not invoke `lsof` for that pane.
- `PORTS-1.3`: When the previous scan tick has not completed, the application shall drop the next scheduled tick rather than queue it.
- `PORTS-1.4`: When `lsof` exits non-zero or is not found on `PATH`, the application shall log once and treat the snapshot as empty for that tick.

`PORTS-2` (binding model)
- `PORTS-2.1`: When a single PID binds the same port on both an IPv4 and IPv6 address, the application shall represent the result as a single `PortBinding`.
- `PORTS-2.2`: If any binding for a `(pid, port)` pair is on a non-loopback address, then the application shall classify that binding's scope as `.lan`.
- `PORTS-2.3`: When multiple PIDs bind the same `(port, scope)` (forked workers), the application shall represent the result as a single `PortBinding` whose `pid` is the lowest matching PID.

`PORTS-3` (UI)
- `PORTS-3.1`: While a pane has at least one `PortBinding`, the application shall render one `PortChip` per binding inline with the pane title.
- `PORTS-3.2`: When `PortChip` icons render, the application shall use SF Symbol `personalhotspot` for `.loopback` scope and `globe` for `.lan` scope.
- `PORTS-3.3`: When chips would overflow the available width, the application shall wrap chips to the next line aligned under the pane title text rather than flush with the row's leading edge.
- `PORTS-3.4`: When a pane has an active `AttentionCapsule`, the application shall hide port chips for that pane until the capsule clears.
- `PORTS-3.5`: When the user clicks a `PortChip`, the application shall open `http://localhost:<port>/` via `NSWorkspace.shared.open`. (The chip's icon, not the URL scheme, communicates whether the listener is also reachable from the LAN.)
- `PORTS-3.6`: When a `PortChip` is hovered, the application shall display a tooltip reading `Open http://localhost:<port>/`.

`PORTS-4` (lifecycle)
- `PORTS-4.1`: When a pane is registered, the application shall include it in subsequent scan ticks until it is unregistered.
- `PORTS-4.2`: When a pane is unregistered, the application shall drop its cached binding snapshot.
- `PORTS-4.3`: When a pane is dragged to another worktree, the application shall preserve its registration and binding snapshot (`PaneID` is stable).
- `PORTS-4.4`: When a scan returns no listeners for a pane that previously had bindings, the application shall clear that pane's bindings on the same tick.

## Testing strategy

- **Scanner unit tests** (`Tests/GrafttyKitTests/PortScannerTests.swift`) — inject a stub `lsof` runner returning canned text fixtures; assert binding model state across canonical scenarios (single port, dual-stack, forked workers, scan error, pane unregister mid-scan).
- **Parser unit tests** — `lsof -nP -iTCP -sTCP:LISTEN -p ...` output is deterministic; fixture-driven.
- **Polling cadence test** — inject a `Scheduler` (same pattern used by the divergence-stats follow-up test fixed in `72c8cd4`) so cadence assertions don't depend on real time.
- **`PortChip` view test** — Swift Testing: render chip in each scope, assert tooltip text and accessibility label.
- **Lifecycle test** — register, scan, unregister, scan; assert snapshot dropped.
- **No `lsof` exec in tests** — the runner is a protocol; only one integration smoke test (gated behind a CI flag) actually invokes the binary, asserting the parser handles real-world output.

Tests live under existing target conventions (`*Tests.swift` for active, `Specs/PortsTodo.swift` inventory file for not-yet-implemented). `scripts/generate-specs.py` regenerates `SPECS.md`; CI (`verify-specs`) fails if stale.

## Open questions

None remaining at design time. The implementation may surface questions about exact `PaneID`/`PaneState` accessor names — those are mechanical and resolved by reading the existing code during the plan phase, not design-time decisions.
