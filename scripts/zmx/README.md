# Graftty zmx patch

`UPSTREAM_COMMIT` pins the source revision used by `scripts/bump-zmx.sh`, and
`ZIG_VERSION` pins the compiler that must build it. `graftty.patch` applies to
that exact source revision and carries three downstream changes:

- explicitly unblock `SIGWINCH` before installing the attach client's wake
  handler;
- preserve zmx's legacy 4-byte `Resize` message while negotiating a separate
  pixel-size extension;
- treat a client that has not yet sent `PixelSize` as carrying *unknown*
  pixel dimensions: its Init/Resize winsize writes preserve the session
  PTY's current pixel fields instead of substituting zeros (ZMX-9.4).
  Substituted zeros made every unchanged-size re-attach a real winsize
  change — the kernel raises SIGWINCH on any field change, pixels included
  — so the session shell repainted its prompt over the replayed screen on
  every Graftty LRU rehydration.

The resize extension is deliberately asymmetric for rolling app upgrades.
A new daemon advertises a `Capabilities` bitset after a valid `Init`. A new
client sends `PixelSize` only after that advertisement and immediately before
the legacy `Resize`. Consequently:

- a new client never sends extension tags to an old daemon;
- an old client can ignore a new daemon's capability advertisement;
- both combinations continue to use the unchanged row/column payload.

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
