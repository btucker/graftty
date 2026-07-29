# Graftty zmx patch

`UPSTREAM_COMMIT` pins the source revision used by `scripts/bump-zmx.sh`, and
`ZIG_VERSION` pins the compiler that must build it. `graftty.patch` applies to
that exact source revision and carries two downstream changes:

- explicitly unblock `SIGWINCH` before installing the attach client's wake
  handler;
- preserve zmx's legacy 4-byte `Resize` message while negotiating a separate
  pixel-size extension.

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
