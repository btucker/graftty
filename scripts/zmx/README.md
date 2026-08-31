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
  not sent twice. Raw snapshot mode receives an initial snapshot even for a
  newly created session, suppresses the human-readable creation diagnostic,
  and keeps forwarding subsequent live bytes;
- track unfinished UTF-8 and VT parser state across the snapshot cut. Snapshot
  export is atomic, and regular clients replay the decoded continuation after
  restoring terminal state so a sequence split across PTY reads remains valid;
- validate the `GHOSTSNP` envelope because the previous Graftty protocol used
  tag 22 for `Capabilities`. Snapshot mode puts stdout into raw mode
  independently from stdin so a PTY output line discipline cannot rewrite
  binary bytes;
- skip the experimental outer-terminal probe and client seed snapshot. The
  probe can consume keystrokes entered immediately after attach, while a
  no-probe seed contains default colors rather than Graftty's actual surface
  state and must not replace the user's theme;
- preserve Graftty's prior 10 MB scrollback retention budget, with a separate
  high line ceiling. Upstream's new 2,000-line setting combines with Ghostty's
  10 KB default byte budget and discards most of a 10,000-line fixture;
- preserve zmx's legacy 4-byte `Resize` message while negotiating a separate
  pixel-size extension. The new protocol also bridges the directional tag
  18/19 shapes used by Graftty 0.6 so N-1 pixel-only resizes keep working;
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
