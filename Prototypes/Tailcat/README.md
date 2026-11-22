# Tailcat transport prototype

## Use Tailcat in Graftty

On the Mac, open **Settings → General → Use Tailcat for paired connections (beta)**.
On the iPhone or iPad, open **Hosts → Paired connections → Use Tailcat (beta)**.
Both switches default to off. The Mac setting also controls outbound connections
to paired Macs. An explicit direct SSH endpoint keeps its configured transport.

Pair normally and connect once on a network where the paired Mac is reachable.
A client with worktree-management access learns the route over the encrypted SSH
channel. The next fresh connection tries Tailcat using the saved host pin and
client key. Background and reopen the phone app to initiate a fresh connection.
The Mac stores its listener identity and the client stores the route in Keychain.
Turning off the Mac setting stops its listener and active Tailcat sessions.
Turning off the client setting applies to subsequent connections.

## Transport harness

The separate harness exercises the embedded library with the same SSH transport.

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

`UPSTREAM_COMMIT` pins the Tailcat source. The builder packages arm64 macOS,
iOS Simulator, and iPhone archives in `.deps/Tailcat.xcframework`, together
with the upstream header and license. Generated projects and binaries are ignored.

## Run on iPhone

Select the `TailcatCheck` scheme in the generated project. Choose a signing team
and run on an iPhone, or archive for a generic iOS device and export for Release
Testing with a profile that includes the phone. The app's bundle ID is
`com.quotably.graftty.tailcatcheck`, so it installs alongside Graftty.

Open **Tailcat Check** and tap **Run transport check**. The app starts two
peers on the phone, sends 1 KiB over Tailcat TCP, and verifies the echoed bytes.
It displays the route and echo time. An internet connection is required for
relay bootstrap. The separate check app does not change GrafttyMobile preferences.

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
The shared Mac and simulator suite uses a small NIOSSH fixture with an explicit
paired-key check and an echoing terminal. It substitutes for a Mac PTY, as the
existing simulator SSH tests do.

The additional Mac-only `TailcatHostIntegrationTests` suite passes accepted
Tailcat streams to the production `DirectSSHHostServer`. It exercises the real
paired-key store, host pinning, channel capabilities, and revocation registry,
plus control, team, and terminal channels. Its PTY is still an injected echo
stream. The host package depends on AppKit, so the simulator continues to test
the shared client against the small NIOSSH fixture.

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

The pre-PR review added regressions for descriptor-allocation failure and SSH
closure without explicit peer closure. Both failed before the fixes and passed
afterward in the simulator. The peer-closure test now waits for a parked receive.
The builder also recovers an interrupted initial source checkout.

On 17 November 2026, the production-host suite passed on Mac, including both
untrusted-identity cases and a 1 MiB terminal echo. All ten Mac tests then passed
with DERP forced and the relay route asserted. The seven-test shared client
suite also passed on the iPhone 18 Pro simulator running iOS 27.0. The optional
performance probe remained disabled. These checks do not exercise app pairing
or app connection routing.

## Compare performance

Set `TEST_RUNNER_GRAFTTY_TAILCAT_BENCHMARK=1` on the simulator test command to
enable the matched probe. It alternates transport order across three rounds,
using five warm-up echoes, 100 one-byte echoes, and a 4 MiB bulk echo per round.
Both transports use the same `TerminalSessionClient` and synthetic SSH server.
Unsupported optional subsystem probes reject immediately. The probe prints
numeric JSON lines with the prefix `[tailcat-comparison]` and checks byte integrity.

The 13 November run on an iPhone 18 Pro simulator, iOS 27.0, Xcode 27.2, and
Mac16,8 produced these medians across three rounds. Raw reports and source
hashes are in [performance-simulator.json](performance-simulator.json).

| Metric | Tailcat, direct | WebRTC, local ICE |
| --- | ---: | ---: |
| One-byte echo p50 | 0.372 ms | 0.353 ms |
| One-byte echo p95 | 0.587 ms | 0.663 ms |
| One-byte echo p99 | 0.609 ms | 0.877 ms |
| 4 MiB bulk echo payload rate | 26.14 MiB/s | 0.87 MiB/s |
| Fresh fixture setup | 4.46 s | 0.124 s |

Idle echo latency is similar. Tailcat's bulk echo was faster in this harness,
with rates of 16.8–27.8 MiB/s versus WebRTC's 0.86–1.50 MiB/s. This is payload
size divided by the complete upload-and-echo duration, not one-way goodput.
It does not establish a corresponding speedup in rendered terminal output.

Setup timings are not application connection times. Tailcat starts a new
server and contacts public relay infrastructure in each round. WebRTC uses
in-process SDP exchange. A persistent host, real signaling, and network
conditions can change the comparison.

These debug-build loopback measurements exclude rendering, injected packet
loss or delay, interactive latency during concurrent bulk output, physical
device power use, and cellular transitions. A controlled real-device test
remains necessary before a migration performance claim.

## Where startup time goes

On 22 November 2026 the iPhone 18 Pro simulator reproduced the cold start.
For three rounds, the startup probe timed the listener, a fresh client dial,
pinned SSH authentication, terminal opening, and the first verified byte echo.
It then connected a second fresh client to the same host. Both clients opened
a second terminal channel on the established SSH connection. Set
`TEST_RUNNER_GRAFTTY_TAILCAT_STARTUP=1` on the simulator test command to repeat it.

| Tailcat phase | Median |
| --- | ---: |
| Start listener, automatic relay selection | 340 ms |
| Restart listener with saved identity and relay | 1.2 ms |
| First client dial immediately after listener start, automatic / saved relay | 4,104 / 4,121 ms |
| Fresh client to already-running host, dial through terminal open, automatic / saved relay | 196 / 206 ms |
| Open another terminal on the authenticated SSH connection | 2.0 ms |

A separate simulator probe called `tc_client_ping` before the first TCP dial.
The median registration time across three fresh processes was 4,061 ms when
the client started immediately and 135 ms when the listener had a five-second
head start. The five seconds were an experimental control. An application can
start the listener when host access is enabled and reuse it across connections.

At the pinned revision, the host starts relay endpoint discovery in the
background. The client sends a registration packet through DERP and retries
once a second until the host acknowledges it. Returning from listen does not
guarantee that the relay can deliver to the host yet. Restoring the selected
relay saved selection time but did not remove this registration delay.

In a separate simulator build, selecting the known home DERP immediately
on the server (`mc.ForceSetNearestDERP(derpRegion)` after starting the network
monitor in `locoBackend.Start`) reduced the three immediate registration times
to 135, 330, and 1,061 ms. These are registration measurements, not complete
terminal opens. This upstream experiment is separate from the pinned app build.
Test cold starts across real networks and relay failover before adopting it.

## Paired reconnect release check

With graftty-server unreachable and the relay reachable, restart the full Mac
host process using its persisted pairing store. Verify that the still-paired
phone can open a terminal with its original SSH pin and key. Unpair it locally
while connected and verify the active session closes. Restart again and verify
that the same phone, key, and saved address are denied. An identity rejection
must end the attempt on every transport. Exercise both mixed-version directions
before retiring WebRTC. These checks are pending.

## Limits

Tailcat addresses contain connection secrets. The cached-route integration test
writes a temporary route under a fresh test pin and removes it after the check. C errors expose numeric status
only. Do not commit addresses, keys, or unredacted runtime logs.

The Mac restart test recreates the Tailcat listener and SSH host in one process.
It restores the serialized private and pre-shared keys, takes the relay from the
original address, and sends a control request to that address with the same SSH
keys. The test keeps credentials in memory and seeds the paired-key store for
each host. The beta uses Keychain for its route and listener identity. Full app pairing
and reconnect across a real process exit still need a physical-device check. Production capability checks and live peer revocation
have passed in the Mac host integration suite.
Simulator results cannot establish cellular behavior, physical-device power
use, suspension recovery, or performance across NATs. Those remain migration
gates, together with a relay hosting plan and upstream compatibility handling.
