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
@spec ATTN-1.6: If `graftty notify` is invoked with both a `<text>` argument and the `--clear` flag, then the CLI shall exit non-zero with a usage error rather than silently dropping the text and performing a clear.
""", .disabled("not yet implemented"))
    func attn_1_6() async throws { }

    @Test("""
@spec ATTN-1.7: If `graftty notify` is invoked with text that is empty or contains only whitespace characters (including tabs and newlines), then the CLI shall exit non-zero with a usage error rather than sending a visually-empty attention badge.
""", .disabled("not yet implemented"))
    func attn_1_7() async throws { }

    @Test("""
@spec ATTN-1.8: If `graftty notify` is invoked with `--clear-after` greater than 86400 seconds (24 hours), then the CLI shall exit non-zero with a usage error. Values at or below 86400 are accepted; values at or below zero are handled server-side per `STATE-2.8`.
""", .disabled("not yet implemented"))
    func attn_1_8() async throws { }

    @Test("""
@spec ATTN-1.9: If `graftty notify` is invoked with both `--clear` and `--clear-after`, then the CLI shall exit non-zero with a usage error. `--clear-after` applies only to notify messages; combining it with `--clear` is ambiguous and previously resulted in the `--clear-after` value being silently dropped.
""", .disabled("not yet implemented"))
    func attn_1_9() async throws { }

    @Test("""
@spec ATTN-1.10: If `graftty notify` is invoked with text longer than 200 Character (grapheme cluster) units, then the CLI shall exit non-zero with a usage error. Attention overlays are designed for short status pings rendered in a narrow sidebar capsule; large inputs (e.g. a piped `git log` or `ls -la`) blow up layout and drown the intended signal.
""", .disabled("not yet implemented"))
    func attn_1_10() async throws { }

    @Test("""
@spec ATTN-1.12: If `graftty notify` is invoked with text containing any Unicode Cc (control) scalar — line feed, carriage return, tab, bell, ANSI escape, DEL, null byte, or any other C0/C1 control — then the CLI shall exit non-zero with a usage error reading "Notification text cannot contain control characters (newlines, tabs, ANSI escapes, or other non-printable characters)". The sidebar capsule renders `Text(attentionText)` with `.lineLimit(1)` + `.truncationMode(.tail)`; newlines clip to the first line, tabs render at implementation-defined width, and ANSI escape sequences like `\\e[31m` show up as literal glyphs (the ESC byte is invisible in SwiftUI Text, producing strings like `[31mred[0m`). All of those are data loss or visual garbage from the user's perspective. The server-side `Attention.isValidText` applies the same rejection (silently drops) as a backstop for raw socket clients (`nc -U`, web surface, custom scripts) bypassing the CLI.
""", .disabled("not yet implemented"))
    func attn_1_12() async throws { }

    @Test("""
@spec ATTN-1.13: If `graftty notify` is invoked with text whose scalars are entirely Unicode Format-category (Cf) and/or whitespace — e.g., `"\\u{FEFF}"` (BOM), `"\\u{200B}\\u{200C}\\u{FEFF}"` (mixed zero-width scalars) — then the CLI shall reject the message as `emptyText`. Swift's `whitespacesAndNewlines` trim strips some Cf scalars (ZWSP U+200B) but not others (BOM U+FEFF), producing a would-be zero-width badge; the extra allSatisfy check closes the gap. Mixed content that still carries at least one visible scalar (including ZWJ-joined emoji sequences like `👨‍👩‍👧`) remains valid. `Attention.isValidText` applies the same rejection server-side.
""", .disabled("not yet implemented"))
    func attn_1_13() async throws { }

    @Test("""
@spec ATTN-1.14: If `graftty notify` is invoked with text containing any Unicode bidirectional-override scalar — the embedding family (`U+202A`–`U+202C`), the override family (`U+202D`–`U+202E`), or the isolate family (`U+2066`–`U+2069`) — then the CLI shall reject the message as `bidiControlInText` with the user-visible error "Notification text cannot contain bidirectional-override characters (U+202A-U+202E, U+2066-U+2069) — they visually reverse the text in the sidebar". These scalars are Unicode Format (Cf) so they slip past both `ATTN-1.12`'s Cc-control check and `ATTN-1.13`'s all-Cf-invisible check when mixed with visible content; a notify like `"\\u{202E}evil"` renders RTL-reversed in the sidebar capsule (the "Trojan Source" class of visual deception, CVE-2021-42574). RTL-natural text (Arabic, Hebrew) uses character-intrinsic directionality and does not use these override scalars, so it still validates cleanly. `Attention.isValidText` applies the same rejection server-side for raw socket clients that bypass the CLI.
""", .disabled("not yet implemented"))
    func attn_1_14() async throws { }

    @Test("""
@spec ATTN-2.1: The application shall listen on a Unix domain socket at `~/Library/Application Support/Graftty/graftty.sock`.
""", .disabled("not yet implemented"))
    func attn_2_1() async throws { }

    @Test("""
@spec ATTN-2.2: The CLI shall communicate with the application by sending JSON messages over the Unix domain socket.
""", .disabled("not yet implemented"))
    func attn_2_2() async throws { }

    @Test("""
@spec ATTN-2.3: The application shall support the following message types over the socket:
""", .disabled("not yet implemented"))
    func attn_2_3() async throws { }

    @Test("""
@spec ATTN-2.4: The application shall set the environment variable `GRAFTTY_SOCK` in each terminal surface's environment, pointing to the socket path.
""", .disabled("not yet implemented"))
    func attn_2_4() async throws { }

    @Test("""
@spec ATTN-2.5: The CLI shall read the `GRAFTTY_SOCK` environment variable to locate the socket. If the variable is unset or set to an empty string, the CLI shall fall back to the default path `<Application Support>/Graftty/graftty.sock`. Treating empty as unset prevents a blank `GRAFTTY_SOCK=` line (e.g. from a sourced `.env` file) from redirecting the CLI to a nonexistent socket at the empty path.
""", .disabled("not yet implemented"))
    func attn_2_5() async throws { }

    @Test("""
@spec ATTN-2.6: When the application receives a `notify` message over the socket whose text is empty or contains only whitespace characters, the application shall silently drop the message rather than render an invisible attention overlay. This backs up the CLI's ATTN-1.7 validation for non-CLI socket clients.
""", .disabled("not yet implemented"))
    func attn_2_6() async throws { }

    @Test("""
@spec ATTN-2.8: The application's Unix-domain socket server shall call `listen(2)` with a backlog of 64, not the historical default of 5. A user scripting parallel `graftty notify` invocations (e.g. from a hook that fans out across a monorepo) can easily exceed 5 pending connections, and the extra backlog entries cost negligible kernel resources while preventing spurious `ECONNREFUSED` for the later clients.
""", .disabled("not yet implemented"))
    func attn_2_8() async throws { }

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
@spec ATTN-3.4: If the control socket file exists on disk but `connect()` fails with `ECONNREFUSED`, then the CLI shall print "Graftty is running but not listening on `<path>`. Quit and relaunch Graftty to reset the control socket." and exit with code 1, rather than conflating this stale-listener case with `ATTN-3.1`'s "not running" message. The conditions differ: `ENOENT` (file missing) means the app never created the socket, whereas `ECONNREFUSED` on an existing file means a prior Graftty instance crashed without unlinking, or its `SocketServer.start()` failed after the file was created but before listening began.
""", .disabled("not yet implemented"))
    func attn_3_4() async throws { }

    @Test("""
@spec ATTN-3.5: When a `pane list`, `pane add`, or `pane close` request targets a tracked worktree that is not in the `.running` state (i.e., no terminals currently alive in it), the server shall respond with `.error("worktree not running")`. `list` in particular shall NOT return an empty `.paneList` — that reads as a silent success to callers scripting `pane list | wc -l` or similar, when in fact the worktree needs to be clicked to start its terminals.
""", .disabled("not yet implemented"))
    func attn_3_5() async throws { }

    @Test("""
@spec ATTN-4.1: The application shall provide a menu item (Graftty -> Install CLI Tool...) to create or update a symlink at `/usr/local/bin/graftty` pointing to the CLI binary in the app bundle. CLI installation is opt-in via this menu item; the application shall not auto-prompt for installation on launch.
""", .disabled("not yet implemented"))
    func attn_4_1() async throws { }

    @Test("""
@spec ATTN-4.2: When the application creates a terminal pane surface, the application shall override the spawned shell's `PATH` to a sanitized form that removes any entry equal to the bundle's `Contents/MacOS` directory and prepends the bundle's `Contents/Helpers` directory. Without this, the embedded libghostty's bundle-self-locating logic puts `Graftty.app/Contents/MacOS` on PATH, and on macOS's case-insensitive APFS volume `which graftty` resolves the lowercase lookup to the GUI binary `Graftty` (which silently exits `0` on unknown args, so `graftty --help` prints nothing). The override is exact-path equality — unrelated `Contents/MacOS` directories from other apps in the user's PATH are left alone.
""", .disabled("not yet implemented"))
    func attn_4_2() async throws { }
}
