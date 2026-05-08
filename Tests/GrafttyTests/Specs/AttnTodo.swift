// Auto-generated inventory of unimplemented specs in this section.
// Promote a @Test(.disabled(...)) entry to a real @Test in a *Tests.swift
// file before implementing the behavior, then delete the entry from this
// inventory file. SPECS.md is regenerated from these markers by
// scripts/generate-specs.py.

import Testing

@Suite("ATTN — pending specs")
struct AttnTodo {
    @Test("""
@spec ATTN-1.1: The application shall include a CLI binary (`graftty`) in the app bundle at `Graftty.app/Contents/Helpers/graftty`. The CLI is placed in `Contents/Helpers/` (not `Contents/MacOS/`) because on macOS's default case-insensitive APFS, the binary name `graftty` collides with the app's main executable `Graftty` if both are in the same directory. The Swift Package Manager product that builds this binary is named `graftty-cli` for the same reason; it is renamed to `graftty` when installed into the app bundle. When the user invokes "Install CLI Tool…" and the bundled CLI is missing at this path (typical for a raw `swift run`-built Graftty that hasn't been put through `scripts/bundle.sh`), the application shall surface an actionable "CLI Binary Not Found" alert rather than create a dangling symlink at `/usr/local/bin/graftty`. `CLIInstaller.plan` returns `.sourceMissing(source:)` in this case.
""", .disabled("not yet implemented"))
    func attn_1_1() async throws { }

    @Test("""
@spec ATTN-1.2: The CLI shall support the command `graftty notify "<text>"` to set attention on the worktree containing the current working directory.
""", .disabled("not yet implemented"))
    func attn_1_2() async throws { }

    @Test("""
@spec ATTN-1.3: The CLI shall support the flag `--clear-after <seconds>` to auto-clear the attention after a specified duration.
""", .disabled("not yet implemented"))
    func attn_1_3() async throws { }

    @Test("""
@spec ATTN-1.4: The CLI shall support the command `graftty notify --clear` to clear attention on the current worktree.
""", .disabled("not yet implemented"))
    func attn_1_4() async throws { }

    @Test("""
@spec ATTN-1.5: The CLI shall resolve the current worktree by walking up from `$PWD` looking for a `.git` file (linked worktree) or `.git` directory (main working tree). When normalizing `$PWD` before the walk, the CLI shall use POSIX `realpath(3)` semantics (physical path, `/tmp` → `/private/tmp`) rather than Foundation's `URL.resolvingSymlinksInPath` (logical path, which collapses the other direction). This must match the path form that `git worktree list --porcelain` emits — the same form the app's `state.json` stores — so the tracked-worktree lookup matches when the user's `$PWD` traverses a private-root symlink. Without this, `graftty notify` fails `"Not inside a tracked worktree"` from any `/tmp/*` or `/var/*` worktree even when the worktree is tracked.
""", .disabled("not yet implemented"))
    func attn_1_5() async throws { }

    @Test("""
@spec ATTN-2.1: The application shall listen on a Unix domain socket at `~/Library/Application Support/Graftty/graftty.sock`.
""", .disabled("not yet implemented"))
    func attn_2_1() async throws { }

    @Test("""
@spec ATTN-2.2: The CLI shall communicate with the application by sending JSON messages over the Unix domain socket.
""", .disabled("not yet implemented"))
    func attn_2_2() async throws { }

    @Test("""
@spec ATTN-2.4: The application shall set the environment variable `GRAFTTY_SOCK` in each terminal surface's environment, pointing to the socket path.
""", .disabled("not yet implemented"))
    func attn_2_4() async throws { }

    @Test("""
@spec ATTN-2.6: When the application receives a `notify` message over the socket whose text is empty or contains only whitespace characters, the application shall silently drop the message rather than render an invisible attention overlay. This backs up the CLI's ATTN-1.7 validation for non-CLI socket clients.
""", .disabled("not yet implemented"))
    func attn_2_6() async throws { }

    @Test("""
@spec ATTN-3.1: If the application is not running, then the CLI shall print "Graftty is not running" and exit with code 1.
""", .disabled("not yet implemented"))
    func attn_3_1() async throws { }

    @Test("""
@spec ATTN-3.2: If the current working directory is not inside a tracked worktree, then the CLI shall print "Not inside a tracked worktree" and exit with code 1.
""", .disabled("not yet implemented"))
    func attn_3_2() async throws { }

    @Test("""
@spec ATTN-3.3: If the socket is unresponsive, then the CLI shall time out after 2 seconds, print an error, and exit with code 1.
""", .disabled("not yet implemented"))
    func attn_3_3() async throws { }

    @Test("""
@spec ATTN-3.5: When a `pane list`, `pane add`, or `pane close` request targets a tracked worktree that is not in the `.running` state (i.e., no terminals currently alive in it), the server shall respond with `.error("worktree not running")`. `list` in particular shall NOT return an empty `.paneList` — that reads as a silent success to callers scripting `pane list | wc -l` or similar, when in fact the worktree needs to be clicked to start its terminals.
""", .disabled("not yet implemented"))
    func attn_3_5() async throws { }

    @Test("""
@spec ATTN-4.1: The application shall provide a menu item (Graftty -> Install CLI Tool...) to create or update a symlink at `/usr/local/bin/graftty` pointing to the CLI binary in the app bundle. CLI installation is opt-in via this menu item; the application shall not auto-prompt for installation on launch.
""", .disabled("not yet implemented"))
    func attn_4_1() async throws { }

    @Test("""
@spec ATTN-1.16: When `pane send <addr> <text>` is invoked, the application shall inject `text` into the addressed pane's PTY via `ghostty_surface_text`, and unless `--no-enter` is set, shall additionally synthesize a Return key event via `ghostty_surface_key` (matching `SurfaceHandle.pressReturn`) so TUI consumers in raw mode (Codex, Claude) treat the input as committed.
""", .disabled("not yet implemented"))
    func attn_1_16() async throws { }

    @Test("""
@spec ATTN-1.17: When any `pane` subcommand (`list`/`add`/`close`/`show`/`send`) is invoked with a `<wt>` or `<wt>:<id>` address, the application shall resolve the worktree by branch name (using the same lookup `graftty team msg` uses, against the `team list` registry) and operate on that worktree regardless of the caller's current working directory; an unknown name shall produce a stderr error and a non-zero exit.
""", .disabled("not yet implemented"))
    func attn_1_17() async throws { }

    @Test("""
@spec ATTN-1.18: When `pane show` or `pane send` is invoked against a worktree that is not in the `running` state, the application shall fail with a `worktree not running` error rather than auto-launch the worktree's panes.
""", .disabled("not yet implemented"))
    func attn_1_18() async throws { }

    @Test("""
@spec ATTN-1.19: When `pane show` or `pane send` is invoked against a worktree that has more than one pane and the address omits the `<id>` part, the application shall print the equivalent of `pane list <wt>` to stderr, append a "specify a pane" hint, and exit non-zero. With exactly one pane, the bare-worktree form shall target that pane.
""", .disabled("not yet implemented"))
    func attn_1_19() async throws { }

    @Test("""
@spec ATTN-1.22: When `pane show` or `pane send` errors out due to ambiguity (`ATTN-1.19`), unknown worktree (`ATTN-1.17`), or missing-current-worktree, the error text shall include the literal next-step invocation the caller should run (a `graftty …` command line, copy-pasteable as-is).
""", .disabled("not yet implemented"))
    func attn_1_22() async throws { }

    @Test("""
@spec ATTN-1.23: When the team session-start hook renders the team protocol primer, the application shall include a brief block describing the `pane list` / `pane show` / `pane send` commands and the `<worktree>:<id>` address grammar, with a pointer to `graftty pane <verb> --help` for full examples.
""", .disabled("not yet implemented"))
    func attn_1_23() async throws { }

}
