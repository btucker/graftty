# Blindspots Config

## Product

Espalier — a macOS app that organizes persistent terminal sessions by git worktree, plus a companion CLI tool (`espalier`) for sending attention notifications from inside terminals.

Two surfaces to test:
- **macOS app** (`Espalier`) — SwiftUI + AppKit + libghostty. Sidebar of repositories, each expandable to show worktrees. Click a worktree to get persistent terminal sessions in that directory. Terminals support splits and stay alive across worktree switches.
- **CLI tool** (`espalier`) — small command-line utility that runs inside a worktree's terminal and signals attention needed to the app via a Unix domain socket.

## Setup

```bash
# Build everything
swift build

# Run the macOS app
swift run Espalier

# Run the CLI
swift run espalier --help
swift run espalier notify "Build failed"
swift run espalier notify --clear

# Run tests
swift test --test-product EspalierPackageTests
```

Note: as of this writing, the macOS app UI is not yet implemented (implementation plan tasks 12-15 remain). The CLI and the `EspalierKit` library are functional and testable.

## Start

**For the CLI:** `cd` into a git repository or worktree, then run `espalier notify "<text>"`. The CLI reads `$PWD`, walks up to find the enclosing `.git`, and sends a message to the app's Unix domain socket at `$ESPALIER_SOCK` (or `~/Library/Application Support/Espalier/espalier.sock`).

**For the app:** Launch Espalier, click "Add Repository" in the sidebar, choose a git repo directory. Espalier discovers all the repo's worktrees and lists them. Click any worktree to get a terminal in that directory.

## Computer Use

Full macOS computer-use tools are available (`mcp__computer-use__*`): screenshots, left/right/double/triple click, mouse move/drag, type, key, scroll, open_application, read/write_clipboard, zoom, list_granted_applications. Testing strategies:

- **CLI**: terminal explorer — run `espalier` commands in a shell, observe exit codes and stderr.
- **macOS app**: open Espalier via `open_application`, take screenshots, click sidebar entries, drag to resize, use keyboard shortcuts (Cmd+D for split, Cmd+Opt+Arrow for pane navigation). Computer-use requires accessibility permission — use `list_granted_applications` / `request_access` when needed.

## Specs

- `SPECS.md` — EARS requirements, 59 requirements across 7 sections (LAYOUT, STATE, TERM, GIT, ATTN, PERSIST, TECH)
- `docs/superpowers/specs/2026-04-16-espalier-design.md` — narrative design spec with architecture, data flow, and Ghostty code reuse notes
- `docs/superpowers/plans/2026-04-16-espalier-implementation.md` — implementation plan (16 tasks, TDD throughout)

## Explore

All surfaces:

- **Worktree workflow** — adding a repo via file picker or drag & drop; worktree discovery via `git worktree list`; the smart detection that traces a worktree back to its parent repo; live FSEvents-driven updates when worktrees are added/removed/deleted externally; branch label updates when HEAD changes.
- **Terminal lifecycle** — clicking a closed worktree starts terminals; switching worktrees keeps them alive; explicit Stop tears them down; processes running inside terminals should survive worktree switching without interruption.
- **Attention notifications** — the CLI's `notify`, `--clear`, and `--clear-after` flags; auto-clearing on focus; the red badge in the sidebar.
- **Persistence** — kill the app, relaunch, verify repos/worktrees/split trees/window frame/selection all come back; running worktrees get fresh terminal surfaces in their saved layout; reconciliation detects adds/removes that happened while the app was closed.
- **Split management** — horizontal/vertical splits (Cmd+D / Cmd+Shift+D); draggable dividers; keyboard navigation between panes (Cmd+Opt+Arrow); closing panes (Cmd+W).

## Diagnose

- **Build errors**: `swift build 2>&1 | tail -20`
- **Test failures**: `swift test --test-product EspalierPackageTests 2>&1 | tail -20`
- **Socket communication**: the app logs to stderr; the CLI exits with code 1 and a message on stderr. Check if the socket file exists at `~/Library/Application Support/Espalier/espalier.sock`.
- **Persistence**: inspect `~/Library/Application Support/Espalier/state.json`.

## Test

```bash
swift test --test-product EspalierPackageTests
```

36 tests across 7 suites currently. Unit tests cover the model layer (SplitTree, AppState, WorktreeEntry), git integration (GitRepoDetector, GitWorktreeDiscovery), and notification protocol (NotificationMessage, SocketServer integration test). No tests for FSEvents-based monitoring (tested manually) or the macOS app UI (not yet built).
