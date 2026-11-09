# Graftty zmx patch

`UPSTREAM_COMMIT` pins the source revision used by `scripts/bump-zmx.sh`, and
`ZIG_VERSION` pins the compiler that must build it. `graftty.patch` applies to
that exact source revision and carries these downstream changes:

- explicitly unblock `SIGWINCH` before installing the attach client's wake
  handler;
- negotiate the experimental Ghostty snapshot transport without breaking
  running daemons from older Graftty releases. Snapshot-capable clients
  advertise support before the frozen 4-byte `Init`; a new daemon sends a
  binary `Snapshot` only to those clients and serializes VT output for older
  clients. An attach client does not receive live PTY broadcasts until its
  initial replay is queued, so bytes already represented by the snapshot are
  not sent twice. The daemon advertises snapshot support as soon as it accepts
  a socket, so a delayed attach can ignore output emitted while it temporarily
  resembles a legacy Tail client. Output for a Tail client is buffered during
  classification and replayed once the client subscribes; the buffer is
  capped at 1 MiB and released after classification. Raw snapshot mode
  receives an initial snapshot even for a newly created session, suppresses
  the human-readable creation diagnostic, and keeps forwarding subsequent
  live bytes. A failed raw snapshot export rejects only that client and leaves
  the durable session running;
- track unfinished UTF-8 and VT parser state across the snapshot cut. Snapshot
  export is atomic, and regular clients replay the decoded continuation after
  restoring terminal state so a sequence split across PTY reads remains valid;
- validate the `GHOSTSNP` envelope carried by upstream's tag 22 `Snapshot`
  frame. Snapshot mode puts stdout into raw mode independently from stdin so
  a PTY output line discipline cannot rewrite binary bytes;
- skip the experimental outer-terminal probe and client seed snapshot. The
  probe can consume keystrokes entered immediately after attach, while a
  no-probe seed contains default colors rather than Graftty's actual surface
  state and must not replace the user's theme;
- retain libghostty 1.4's default 50 MB scrollback page budget, with a
  separate high line ceiling. Ghostty counts page allocations rather than
  text, so the earlier 10 MB budget kept only about 7,000 rows of a
  156-column session and reattached panes stopped there. Upstream's new
  2,000-line setting combines with Ghostty's 10 KB default byte budget and
  discards most of a 10,000-line fixture. The 50 MB budget ships in
  `graftty8`; existing daemons keep 10 MB until their sessions restart;
- preserve zmx's legacy 4-byte `Resize` message while negotiating a separate
  pixel-size extension. The new protocol also bridges the directional tag
  18/19 shapes used by Graftty 0.6 so N-1 pixel-only resizes keep working, and
  continues to accept the pinned upstream snapshot client's 8-byte resize;
- treat a client that has not yet sent `PixelSize` as carrying *unknown*
  pixel dimensions: its Init/Resize winsize writes preserve the session PTY's
  current pixel fields instead of substituting zeros (ZMX-9.4). Substituted
  zeros made every unchanged-size reattach a real winsize change—the kernel
  raises `SIGWINCH` on any field change, pixels included—so the session shell
  repainted its prompt over the replayed screen on every Graftty LRU
  rehydration;
- skip upstream's forced `SIGWINCH` after an unchanged-size reattach. A real
  size change still raises `SIGWINCH` through `TIOCSWINSZ`, while a same-size
  attach remains a kernel no-op and cannot repaint a duplicate prompt over the
  replayed screen (ZMX-9.4).

The extensions are deliberately asymmetric for rolling app upgrades. A new
client advertises snapshot support before its legacy `Init`, while a new daemon
advertises pixel-size support after a valid `Init`. A new client sends
`PixelSize` only after the daemon advertisement and immediately before the
legacy `Resize`. Consequently:

- old daemons ignore the new capability advertisement, then process the
  unchanged `Init` payload;
- old clients receive the existing VT replay instead of a binary snapshot;
- the committed N-1 client and daemon negotiate pixel sizes through their
  former tag values, disambiguated by message direction and payload shape;
- every combination continues to use the unchanged row/column payload.

`zmx attach --snapshot` exposes the raw `GHOSTSNP` stream for hosts that can
import it directly. Regular attaches decode the snapshot in the zmx client,
consume all history pages, serialize the result to VT, and send that VT through
Graftty's current libghostty surface API. This PR adopts and hardens the
transport, but demand-loaded scrollback still requires a libghostty surface
snapshot-import bridge.

Paged attachments keep each encoded PAGE record, including its codec header
and checksum, within 256 KiB. Dense wide-character rows can make one native
page exceed that transport budget. The daemon sends its newest whole rows
first and keeps the unsent prefix for subsequent ordinals. Retries return
identical bytes and completion metadata. A row that cannot fit by itself
returns a host page-size refusal without advancing the cursor. Client memory
limits remain separate and unchanged.

This behavior ships in `graftty7`. Existing daemon processes keep their old
export behavior until their sessions are deliberately restarted. A new client
labels an old daemon's oversized-page refusal as a transfer limit, rather than
client memory exhaustion. Upgrading the app does not restart active sessions.

Starting with `graftty9`, height-only resizes within the current screen's backing
pages preserve pending history checkpoints, including resizes caused by a new
client attaching. These changes preserve row widths, so older pages remain
compatible. A height increase that exposes older backing pages still expires
checkpoints because live screen edits could change unsent rows. Width changes
also expire checkpoints, even if the terminal later returns to its original
width. History clearing, screen replacement, and pruning still reject discarded
pages. Existing daemon processes keep their previous resize behavior until their
sessions restart.

`zmx attach --replay-grid` is the host's legacy VT bridge mode. It prefixes
stdout with `GFTGRID1`, then two little-endian u16 fields for columns and rows,
before any clear-screen or replay bytes. The dimensions come from the decoded
snapshot, so a new client works with an already-running snapshot-capable
daemon. The host strips this one-time header and reports the source grid before
delivering bytes. Subsequent application output is never scanned for headers.
Stdout is raw even when stdin uses a separate PTY. This mode cannot be combined
with `--snapshot`, and a session-switch request ends the named attachment.

Pre-snapshot daemons send VT without dimensions. The client marks their grid
as `0,0`, and the host retains its previous outer-PTY polling fallback for
compatibility. That fallback cannot establish the replay's source grid.
Snapshot-capable attachments never replace the replay grid with the outer PTY
size. Ongoing owner resize events come from Graftty's ownership protocol;
legacy zmx daemons do not broadcast those dimensions to regular followers.

`UPSTREAM_COMMIT` is not on upstream's release line. It is the unmerged
experimental snapshot commit `ccf8e9f` on top of `e586f62`. Upstream v1.0
dropped that transport, so `snapshot.zig` no longer exists there and tag 22
now means `Capture`. `upstream-fixes.patch` applies after `paging.patch` and
backports these upstream 0.8–1.0.1 fixes, which do not change the wire
protocol:

- terminal query replies (kitty keyboard flags, DA1/DA2, DECRPM, color
  scheme) no longer make a passive client the leader (`54b212d`, `1501f2a`);
- the daemon reads a hung-up client's remaining input before closing it
  (`0a18bee`);
- `mkdirAll` fails on a dangling symlink instead of looping (`ad8be3f`,
  `b8af7ac`);
- `zmx write` bypasses the 256 KiB PTY input cap, so large files arrive whole
  (`1a6ce3c`);
- the attach client closes its signal pipe on exit. On SIGHUP, SIGTERM or
  SIGINT it unwinds, restoring termios and writing the terminal reset, then
  re-raises that signal, so callers still see a signal exit (`2626f17`,
  `14a9e7d`). Graftty also restores the default handlers when the client
  loop exits, so a signal sent while a restore write blocks still kills the
  client. Graftty sends SIGTERM to attach clients (WEB-4.5), and they now
  detach through the same path as a clean exit (ZMX-9.9);
- attach resets SGR before clearing the screen. This includes the
  `--replay-grid` preamble, which is Graftty's attach clear (`7f0ffdb`);
- the reattach replay restores the cursor style (DECSCUSR). The snapshot
  carries cursor style, so regular, replay-grid and legacy replays all
  restore it (`770eb5f`, ZMX-9.10).

Upstream `213390b` (a double free in `printEnv`) does not apply. The pinned
`envGet` frees its payload with a single `defer`.

These are client- or daemon-local fixes. A new client therefore gains the
client fixes against a running old daemon, and an old daemon keeps its
behavior until its session restarts. The fixes ship in `graftty10`.

`LEGACY_GRAFTTY_COMMIT` and `LEGACY_ZMX_SHA256` identify the immutable 0.5
binary that remains the rolling-upgrade compatibility floor. The bump script
tests that fixture on every run and also tests the committed N-1 binary when it
is distinct. It never derives its only legacy input from the mutable output
path.

Run `scripts/bump-zmx.sh` after changing the pin or patch. It formats and tests
the patched Zig source, builds both macOS architectures in `ReleaseSafe`, makes
a universal binary, checks the reported version, and exercises old/new
client-daemon compatibility. It stages and verifies the replacement files
before renaming them into `Resources/zmx-binary`.

For a quick check of the compatibility harness's process-lifecycle helpers
without rebuilding zmx, run `python3 scripts/test_zmx_compatibility.py`.
