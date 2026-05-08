# Controlling Panes Across Worktrees — Design

**Status:** Draft (2026-05-08)

## Problem

Today, one agent can spawn worktrees and add panes inside its *own* worktree (`graftty pane add` resolves the worktree from PWD), and it can deliver structured messages into a teammate's inbox (`graftty team msg`). What it can't do is take direct, keystroke-level control of another worktree's panes — drop into them, type a command, and read what came back.

The motivating workflow is one agent (e.g., main) coordinating others: "make a worktree per open PR, merge `origin/main` into each, then have each run tests." Inbox messages aren't enough — the receiving agent has to opt in to acting on them. The lead agent needs primitives to (a) inject text into another worktree's pane and (b) read that pane's recent output, much the way a human looks over its shoulder.

## Scope

Two new CLI subcommands:

```
graftty pane show [<addr>] [--lines N]
graftty pane send [<addr>] <text> [--no-enter]
```

Plus, the existing `pane list/add/close` subcommands gain the same address grammar so the lead agent can drive panes in any worktree from one place.

Out of scope:
- A `pane wait --until <regex>` blocking primitive — the agent can poll `pane show` itself.
- A streaming `pane tail -f` mode.
- Special-key syntax (`^C`, `Esc`). `pane send --no-enter $'\x03'` already lets you inject raw bytes; we can add a friendlier `--key` later if it's painful.
- A consent layer between worktrees — anyone who can speak the graftty socket already has full pane control over every worktree the app manages, so adding ACLs here would be theatre. The doc just calls this out.

## Pane addressing — the `<addr>` grammar

`<addr>` is optional and parsed by these rules, in order:

| Form              | Meaning                                                                                  |
| ----------------- | ---------------------------------------------------------------------------------------- |
| (omitted)         | Current worktree (resolved from PWD), the worktree's only pane                           |
| `<id>` (numeric)  | Pane `<id>` in current worktree                                                          |
| `<wt>` (non-num)  | Worktree `<wt>`'s only pane                                                              |
| `<wt>:<id>`       | Pane `<id>` in worktree `<wt>`                                                           |

The "only pane" forms (omitted, bare `<wt>`) auto-target when the worktree has exactly one pane. With multiple panes, those forms are an error: the command emits the same output as `pane list <wt>` to stderr, prints a "specify a pane" hint, and exits non-zero so the caller can disambiguate. With zero panes (worktree closed or empty), it errors with "worktree not running".

`<wt>` is a worktree branch name as printed by `graftty team list` (graftty's existing way of naming worktrees in the CLI). The same lookup the team-messaging path uses resolves it to a worktree path before the request goes out over the socket.

If the CLI runs from outside any tracked worktree and `<addr>` is omitted (or has no `<wt>` part), the command errors with "specify a worktree".

## CLI shape

### `pane show`

- `--lines N` (default 100). N applies to the *tail* of the pane's scrollback as captured by `zmx history`.
- Output is plain text on stdout. No headers, no prefixes — pipe-friendly.
- If the addressed worktree isn't running, errors with "worktree not running".

### `pane send`

- Positional: `<addr>` then `<text>`. `<text>` is one positional that the shell already concatenates with normal quoting.
- `--no-enter` suppresses the trailing Return. Default is to press Return after the text so `graftty pane send drag-files:1 "pnpm test"` runs the command.
- The "press Return" behavior synthesizes a real key event (the same path `SurfaceHandle.pressReturn` uses), so TUI consumers in raw mode (Codex, Claude) treat the input as committed. A bare `\r` byte does not always trigger that.
- If the addressed worktree isn't running, errors with "worktree not running".

### Existing `pane list` / `add` / `close` — extended addressing

The existing subcommands accept an optional positional that uses the same grammar:

```
graftty pane list  [<wt>]
graftty pane add   [<wt>]   [--direction ...] [--command ...]
graftty pane close [<wt>:]<id>     # bare <id> still works
```

`pane add` doesn't take a pane id (it splits the focused pane in `<wt>`), so it accepts only `<wt>` or omits the arg. `pane close` requires an id, and accepts `<wt>:<id>` or just `<id>`.

## Routing — single transport via the existing socket

Both new commands route through the same socket the CLI already uses for `pane add/list/close`. The app does the work in-process:

- **`send`**: maps to the existing `SurfaceHandle.typeText(_:)` followed by `SurfaceHandle.pressReturn()` when `--no-enter` is unset. Same path `pane add --command` already uses for its initial command, so behavior is consistent.
- **`show`**: the app shells out to `zmx history <session>` for the pane's session, captures stdout, tails to `--lines`, and returns the bytes as the response payload. zmx already exposes scrollback as plain VT-stripped text — no new libghostty API is needed.

Going through the socket means the CLI never has to know zmx session names — the app already owns that mapping in `TerminalManager`. It also means we don't introduce a second transport (the CLI shelling out to zmx itself), which would split the addressing/error surface.

The transport requires Graftty.app to be running. This isn't a regression — every `pane *` command already requires it.

### Verb-collision note: `team send` vs `pane send`

Both have the shape `graftty <noun> send <target> <text>`, but they're different mechanisms:

- `graftty team send <recipient> <text>` delivers a structured message into a teammate's `team inbox`. The receiving agent reads it at a hook boundary (`SessionStart` / `Stop` / etc.) and decides whether to act. It's cooperative.
- `graftty pane send <addr> <text>` writes raw bytes straight to a PTY. There's no inbox, no consent gate — the keystrokes land in whatever process is reading that pane's stdin right now. It's mechanical.

The `--help` for `pane send` will spell this out.

## Wire protocol

Two new `NotificationMessage` cases, two new `ResponseMessage` cases:

```swift
case showPane(path: String, index: Int, lines: Int)
case sendPane(path: String, index: Int, text: String, pressEnter: Bool)
```

Codable `type` keys: `"show_pane"`, `"send_pane"` (snake_case, matches the existing convention).

```swift
enum ResponseMessage {
    // existing: ok, error, paneList, teamList, teamHookOutput, teamInbox
    case paneShow(String)        // text payload (already tailed to --lines on the server)
}
```

The server tails to `--lines` (not the client) so we don't have to send a multi-megabyte scrollback over the socket only to have the CLI throw most of it away.

For the cross-worktree extension to `list/add/close`: those messages already carry a `path: String`. The CLI now resolves `<wt>` (or `<wt>:<id>`) to a path before sending, so the wire schema doesn't change for those three. The CLI either has the path (resolved from PWD as today) or looked it up via the same lookup `team msg` already uses.

## In-app execution

In `GrafttyApp.handleNotification`, add two branches:

### `.showPane`

- If worktree not found, respond `.error("not tracked")`.
- If worktree not `.running`, respond `.error("worktree not running")`.
- Validate `1 ≤ index ≤ allLeaves.count`. Out of range → `.error("no pane with id N in this worktree")`.
- Resolve the leaf's `TerminalID` and look up the zmx session name from `TerminalManager`'s session map.
- Run `zmx history <session>` as a subprocess, read stdout, tail to `lines`, respond `.paneShow(text)`.

### `.sendPane`

- Same validation as `.showPane`.
- Look up the leaf's `SurfaceHandle` via `terminalManager.handle(for: terminalID)`. If absent (the rare phantom case `TERM-5.5`/`TERM-5.8` cover), respond `.error("pane has no surface")`.
- Call `handle.typeText(text)`, then `handle.pressReturn()` if `pressEnter` is true.
- Respond `.ok`.

### `pane add --command` symmetry

Existing `pane add --command` already calls `typeText`. It currently appends `\n` and does **not** synthesize a real Return key event, which is why the team-inbox idle-delivery code added `pressReturn` separately. We piggy-back on this work for `send`'s implementation but do **not** retroactively change `pane add --command`'s behavior — it serves a different need (typing into a fresh shell, where `\n` is fine), and changing it is out of scope.

## EARS specs

New IDs under `ATTN-1.x`, where the other CLI pane-subcommand specs already live (`ATTN-1.11` etc.).

- **`ATTN-1.15`**: When `pane show <addr>` is invoked against a running pane, the application shall return the last `--lines` lines (default 100) of that pane's `zmx` scrollback as plain text on the CLI's stdout.
- **`ATTN-1.16`**: When `pane send <addr> <text>` is invoked, the application shall inject `text` into the addressed pane's PTY via `ghostty_surface_text`, and unless `--no-enter` is set, shall additionally synthesize a Return key event via `ghostty_surface_key` (matching `SurfaceHandle.pressReturn`) so TUI consumers in raw mode (Codex, Claude) treat the input as committed.
- **`ATTN-1.15`**: When any `pane` subcommand (`list`/`add`/`close`/`show`/`send`) is invoked with a `<wt>` or `<wt>:<id>` address, the application shall resolve the worktree by branch name (using the same lookup `graftty team msg` uses, against the `team list` registry) and operate on that worktree regardless of the caller's current working directory; an unknown name shall produce a stderr error and a non-zero exit.
- **`ATTN-1.16`**: When `pane show` or `pane send` is invoked against a worktree that is not in the `running` state, the application shall fail with a `worktree not running` error rather than auto-launch the worktree's panes.
- **`ATTN-1.17`**: When `pane show` or `pane send` is invoked against a worktree that has more than one pane and the address omits the `<id>` part, the application shall print the equivalent of `pane list <wt>` to stderr, append a "specify a pane" hint, and exit non-zero. With exactly one pane, the bare-worktree form shall target that pane.
- **`ATTN-1.18`**: When `pane show` is invoked against a pane whose `--lines` argument is non-positive or exceeds the pane's available scrollback, the application shall clamp non-positive values to the pane's full scrollback and clamp excessive values to the available scrollback length.

`ATTN-1.15`–`ATTN-1.17` are real `@Test` entries (red → green). `ATTN-1.20` is a small clamping rule that gets a unit test on a pure helper.

## Agent-friendly help and errors

The CLI already uses Apple's `swift-argument-parser` (Swift's Click equivalent), which gives auto-help, auto-usage, and validation errors for free. It does **not** give us "did you mean?" suggestions or rich examples by default. This feature is the right time to add a small ergonomics pass on top, because the panes CLI is the surface autonomous agents will lean on most heavily — they need to be able to figure it out from `--help` and error text alone.

### Help text — `discussion:` everywhere

Each new subcommand (`pane show`, `pane send`) and the parent `pane` group get a `discussion:` block in their `CommandConfiguration` containing:

- The full `<addr>` grammar (the table from this doc, condensed).
- One worked example per shape, e.g.:

  ```
  Examples:
    graftty pane show                     # this worktree's only pane
    graftty pane show 2                   # this worktree, pane 2
    graftty pane show drag-files          # drag-files' only pane (errors if >1)
    graftty pane show drag-files:1        # drag-files, pane 1
    graftty pane send drag-files:1 "pnpm test"
    graftty pane send drag-files:1 "y" --no-enter   # send 'y' without committing
  ```

We backfill the same treatment to existing `pane list/add/close` while we're in there — the address grammar is shared, so they need it too.

### "Did you mean?" on unknown subcommand

`swift-argument-parser` doesn't fuzzy-match unknown subcommands. We add it ourselves: when `GrafttyCLI.main()` catches the unknown-subcommand error, run a small Levenshtein (≤2) match across the registered subcommand names of the current group and append `Did you mean '<closest>'?` to the error text. Implementation is a ~30-line pure-Swift helper in `GrafttyCLI`; tested in isolation against the static subcommand list.

This applies at every level: `graftty paen list` → "Did you mean 'pane'?"; `graftty pane shwo 1` → "Did you mean 'show'?".

### Errors that read as the next command

When the CLI errors out, the message should where possible name the *exact* invocation the caller should try next.

- Bare `<wt>` with multiple panes (`ATTN-1.17`): print the pane list, then `Use 'graftty pane <verb> <wt>:<id> ...' to target one`. Don't make the agent reason about what id to pick — show the ids, show the syntax.
- Unknown worktree name (`ATTN-1.15`): print `unknown worktree 'foo'. Run 'graftty team list' to see registered worktrees.`
- Missing current worktree (no `<wt>` and PWD not in a tracked worktree): print `not inside a tracked worktree; pass <wt> or cd into one. Run 'graftty team list' to see registered worktrees.`

All errors keep the existing `graftty: ` stderr prefix from `CLIEnv.printError` so output is greppable.

### EARS spec for the ergonomics

- **`ATTN-1.19`**: When the CLI is invoked with an unknown subcommand at any level, the application shall append a `Did you mean '<closest>'?` suggestion to the error message whenever a registered subcommand name is within Levenshtein distance 2 of the input.
- **`ATTN-1.20`**: When `pane show` or `pane send` errors out due to ambiguity (`ATTN-1.17`), unknown worktree (`ATTN-1.15`), or missing-current-worktree, the error text shall include the literal next-step invocation the caller should run (a `graftty …` command line, copy-pasteable as-is).

These are unit-testable on the error-formatter helpers without launching a server.

## Session-start hook injection

Every team agent already gets a session-start nudge produced by `TeamHookRenderer.teamProtocolPrimer()` that lists the inbox commands. Without telling agents about pane control there too, they won't think to look — they'll fall back to the cooperative `team msg` channel by default.

Append a brief block to `teamProtocolPrimer()`, in the same style as the existing inbox bullets:

```
Pane control commands (operate panes in any worktree on this team):
- `graftty pane list [<worktree>]` — list panes in a worktree (default: current).
- `graftty pane show <addr>` — print the last 100 lines of a pane's output. Use this to read what another agent has produced.
- `graftty pane send <addr> "<text>"` — type text into a pane and press Enter (use `--no-enter` to suppress). Bytes go straight to the PTY — there's no inbox or consent layer, so the keystrokes land in whatever process is reading that pane right now.
- `<addr>` is `<worktree>` (the worktree's only pane) or `<worktree>:<id>` (use `pane list` to find ids). Run `graftty pane <verb> --help` for examples.
```

Specifically:
- The "no inbox or consent layer" line is deliberate — it cues the agent that this is keystroke-level remote control, not a request a teammate will choose to act on. The `team msg` path remains the right tool for cooperative coordination; `pane send` is the right tool for "actually do this in that shell now."
- We point at `--help` rather than spelling out the full `<addr>` grammar so the primer doesn't balloon. The richer help text from the previous section is what an exploring agent will land on.

This goes into `teamProtocolPrimer()` (universal, every team agent sees it) rather than `TeamInstructionsRenderer` (role-specific). Both `TeamInstructionsRenderer.renderLead` and `renderCoworker` already point at `team list`, which an agent needs to find target worktree names; that pointer is reused here.

### EARS spec

- **`ATTN-1.21`**: When the team session-start hook renders the team protocol primer, the application shall include a brief block describing the `pane list` / `pane show` / `pane send` commands and the `<worktree>:<id>` address grammar, with a pointer to `graftty pane <verb> --help` for full examples.

## File changes

Modified:

- `Sources/GrafttyKit/Notification/NotificationMessage.swift` — add `showPane`, `sendPane`; add `paneShow` to `ResponseMessage`; codable round-trips.
- `Sources/GrafttyCLI/CLI.swift` — add `PaneShow` and `PaneSend`. Refactor existing `PaneList`/`PaneAdd`/`PaneClose` to share a small `<addr>` parser helper. Add `discussion:` text on `Pane`, `PaneList`, `PaneAdd`, `PaneClose`, `PaneShow`, `PaneSend` (`ATTN-1.21`/`ATTN-1.22` ergonomics).
- `Sources/GrafttyCLI/WorktreeResolver.swift` — extend with a `resolveWorktreeName(_:) -> String` helper that maps a branch name → worktree path, using the same logic the team subcommands already use to address teammates.
- `Sources/Graftty/GrafttyApp.swift` — handle the two new cases in `handleNotification`. The `show` branch shells out to `zmx history` (small Process wrapper); the `send` branch is a 3-line call into existing `SurfaceHandle` methods.
- `Sources/GrafttyKit/Teams/TeamHookRenderer.swift` — append the pane-control bullets to `teamProtocolPrimer()` (`ATTN-1.23`).

New:

- `Sources/GrafttyCLI/SubcommandSuggestions.swift` — Levenshtein-≤2 "did you mean" helper, wired into `GrafttyCLI`'s top-level error handler (`ATTN-1.21`).

New (test-only):

- `Tests/GrafttyTests/Specs/AttnTests.swift` (or extend the existing one if present) — `@Test` entries for `ATTN-1.15` through `ATTN-1.17`.
- `Tests/GrafttyKitTests/PaneAddressParserTests.swift` — pure-Swift parsing of `<addr>` grammar (no socket / no app).

`SPECS.md` is regenerated by `scripts/generate-specs.py` after the new `@spec` entries are in.

## Testing

Unit tests (no live app):

- `NotificationMessage` codable round-trip for the two new cases.
- `ResponseMessage.paneShow` codable round-trip.
- `<addr>` parser: `""`, `"3"`, `"drag-files"`, `"drag-files:2"`, garbage like `"foo:bar"`, `":3"`, `"3:foo"`.
- `lines` clamping helper: 0, -1, huge.

Behavioral tests (Swift Testing, may need a stub server):

- `ATTN-1.15` — given a fake zmx output of 200 lines, `pane show --lines 50` returns the last 50.
- `ATTN-1.16` — `pane send` with default flag calls `typeText` *and* `pressReturn`; with `--no-enter` calls only `typeText`. Asserted via test doubles on `SurfaceHandle`.
- `ATTN-1.15` — unknown worktree name → exits non-zero with stderr error; known name → resolves to the right path before dispatch.
- `ATTN-1.16` — closed worktree → "worktree not running"; running → ok.
- `ATTN-1.17` — multi-pane bare-`<wt>` → emits pane list to stderr, exits non-zero; single-pane bare-`<wt>` → succeeds.

We don't try to drive a real libghostty surface or a real `zmx` subprocess in tests — the existing harness doesn't, and the seams above (mockable `SurfaceHandle`, mockable zmx command runner) keep coverage where it's cheap.

## Open questions

- Should `pane send` accept multiple text args and join them with spaces (so `graftty pane send drag-files:1 pnpm test` works without quoting)? Defaulting to "one positional, quoted" for now — matches `team send`. Easy to add later if it's annoying.
