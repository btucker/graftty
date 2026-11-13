# Tailcat transport prototype

This opt-in harness connects the existing `DirectSSHHostConnection` and
`TerminalSessionClient` through an embedded Tailcat library. It leaves the
application's WebRTC transport unchanged.

The path is Graftty SSH → local socket pair → Tailcat TCP → WireGuard.
The socket pair joins SwiftNIO to Tailcat's C API without a local TCP listener.
Blocking C calls run on dispatch workers. Reads and writes use fixed-size
buffers and socket backpressure.

## Build

Requirements: Apple Silicon Mac, Xcode, XcodeGen, Git, and Go with automatic
toolchain download enabled. Network access is required for dependencies and
the Tailcat relay bootstrap. The pinned upstream Go module selects its Go
toolchain and dependency versions.

From the repository root:

```sh
scripts/deps prepare --platforms macos,ios
scripts/build-tailcat-prototype
```

`UPSTREAM_COMMIT` pins the Tailcat source. The builder produces arm64 macOS
and arm64 iOS Simulator archives, copies the upstream header and license, and
creates `.deps/Tailcat.xcframework`. Generated projects and binaries are ignored.
This prototype does not yet build an iPhone device slice or Intel slices.

## Test in the simulator

Choose a simulator ID with `xcrun simctl list devices available`.

```sh
xcodebuild \
	-project Prototypes/Tailcat/TailcatPrototype.xcodeproj \
	-scheme TailcatSimulator \
	-destination 'platform=iOS Simulator,id=SIMULATOR_ID' \
	-derivedDataPath /tmp/graftty-tailcat-derived \
	-skipPackagePluginValidation test
```

For a Mac test, use `-scheme TailcatMac -destination 'platform=macOS'`.
Run ordinary repository regressions with `scripts/swiftpm test`.

To test forced relay use on Mac, prefix the Mac command with
`TEST_RUNNER_TS_DEBUG_ALWAYS_USE_DERP=true TEST_RUNNER_GRAFTTY_TAILCAT_REQUIRE_RELAY=1`.
The second variable makes a direct path fail the test. Upstream compiles out
the first variable's debug switch on iOS, so it cannot force simulator traffic
onto DERP. A simulator relay-only test needs network isolation or an explicit
upstream test hook.

The integration tests run independent Tailcat server and client peers inside
the test process. They use the public relay bootstrap and may discover a
direct path. They require internet access and transfer synthetic bytes only.
The server is a small NIOSSH fixture with an explicit paired-key check and an
echoing terminal. It substitutes for a Mac PTY, as the existing simulator SSH
tests do. It is not the production host authorization implementation.

Tests cover pinned SSH authentication, terminal echo and a 1 MiB ordered
transfer, host-key mismatch, an unpaired client, accept cancellation, peer
closure, and a fresh connection. Echo timing is diagnostic, with no timing
threshold. It excludes terminal rendering and is not a WebRTC comparison.

## Verified results

On 12 November 2026, the four integration tests covering five cases passed
on an iPhone 18 Pro simulator running iOS 27.0. The same suite passed natively
on Mac, then passed on Mac again with DERP forced and verified by the probe.
The initial unimplemented transport failed all five cases before the bridge
was implemented.

An attempted forced-DERP simulator run correctly failed its route assertion:
upstream's iOS build ignored the debug variable and reported a direct path.
The final ordinary simulator run passed with stricter SSH rejection checks.
The simulator has not demonstrated a relay-only path.

The full `scripts/swiftpm test` run built successfully but reported failures
in `GrafttyTests`, `GrafttyKitTests`, and `GrafttyCommandUITests`. These targets
do not compile the optional prototype. Their failures included UI, process,
and timeout assertions. One stalled `GrafttyTests` helper was terminated after
several minutes without progress. The full regression gate is not green.
The existing SSH pipe-authentication regression passed separately with both
the matching-pin and mismatched-pin cases.

Probe latency varied substantially across runs on this machine. No latency
advantage over WebRTC has been established.

## Limits

Tailcat addresses contain connection secrets. This harness generates them
in memory and does not print or persist them. C errors expose numeric status
only. Do not commit addresses, keys, or unredacted runtime logs.

The prototype does not implement pairing UI, address distribution, persistent
listener identity, production capability checks, or live peer revocation.
Simulator results cannot establish cellular behavior, physical-device power
use, suspension recovery, or performance across NATs. Those remain migration
gates, together with a relay hosting plan and upstream compatibility handling.
