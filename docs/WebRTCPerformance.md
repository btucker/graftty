# Measure WebRTC terminal latency

Use the existing iOS loopback probe to compare echo latency with idle and busy
transports. The probe uses real WebRTC and SSH with a synthetic terminal server.
It measures transport echo, excluding native terminal parsing and rendering.

Build and run the probe from the repository root. Replace `SIMULATOR_ID` with an
available device ID from `xcrun simctl list devices available`.

```sh
TEST_RUNNER_GRAFTTY_WEBRTC_LATENCY_SAMPLES=100 xcodebuild \
  -project Apps/GrafttyMobile/GrafttyMobile.xcodeproj \
  -scheme GrafttyMobile \
  -sdk iphonesimulator \
  -skipPackagePluginValidation \
  -derivedDataPath /tmp/graftty-webrtc-performance \
  -destination 'platform=iOS Simulator,id=SIMULATOR_ID' \
  '-only-testing:GrafttyRemoteClientTests/SSHTerminalLoopbackTests/interactiveLatencyWithSiblingTraffic(scenario:)' \
  test > /tmp/graftty-webrtc-performance.log 2>&1

scripts/summarize-terminal-latency.py \
  /tmp/graftty-webrtc-performance.log \
  --output /tmp/graftty-webrtc-performance.json
```

The ordinary test run uses 20 samples. The override accepts 1–100 samples and
clamps values outside that range. Check `echo.sampleCount` in the report to
confirm the override reached the test runner. Each scenario has five warm-up
echoes before measurement. The deadline is at least 150 seconds and scales to
five seconds per sample in larger runs, up to 500 seconds. The test limit is
ten minutes per scenario, leaving time for teardown.

The four scenarios are:

| Scenario | Bulk traffic |
| --- | --- |
| `idle` | None |
| `sharedConnection` | A sibling terminal on the same SSH connection and data channel |
| `separateDataChannel` | A second SSH connection and data channel on the same peer connection |
| `separateConnection` | A second SSH connection on an independent peer connection |

Each non-idle sample transfers 4 MiB of sibling output and verifies its byte
count. The probe waits for actual bulk submission before sending the echo.
`probesDuringBulk` counts samples whose bulk receiver had not finished draining
when the echo started. If that count is low, the run provides little evidence
about responsiveness under concurrent load.

The report includes nearest-rank p50, p95, p99, and maximum latency. With only
20 samples, p99 equals the maximum. Repeat measurements on the same hardware
and simulator runtime before comparing changes. Loopback has no injected RTT
or packet loss and does not measure Wi-Fi/cellular handoff behavior.

`SSHNIOTransport.sendDiagnostics()` provides numeric snapshots for each sender.
The report records both primary senders and the sibling sender when it has a
separate transport. Counters include SSH setup traffic. Admission delay is the
time from enqueue until the complete write enters WebRTC's local send buffer.
It excludes network delivery and receiver consumption. Pending bytes and
WebRTC-buffered bytes describe different queues.

`PagedTerminalCoordinator.lastRestoreDiagnostic` retains the latest checkpoint
installation duration and outcome for the current attachment. It excludes
checkpoint transfer time and does not establish when the first frame appeared
on screen. On iOS, `SessionClient.lastRestoreDiagnostic` preserves the timeout
measurement when recovery replaces the paging coordinator. Both diagnostic
types retain numeric data rather than terminal contents, keys, or peer identities.

Archive the source revision, working-tree status, host model, Xcode version,
and simulator runtime alongside each report. The JSON distinguishes simulator
and device loopback, but does not collect that machine metadata automatically.

## Slow-consumer flow control

Terminal output is paced from the receiver back to the host in three steps:

1. On iOS, `SessionClient` stops taking output while the parser is more than
   3 MiB behind, resuming at 512 KiB. `InMemoryTerminalSession.receive` never
   blocks, so this backlog would otherwise be invisible to the transport. Dense
   title updates are the slowest measured input, because they pass through a
   mailbox that only the main thread drains. Measure with the main thread free:
   blocking in `waitForPendingOutput` drains that mailbox only every 10 ms, which
   measures the wait rather than the parser.
2. A client's negotiated output window, 1 MiB by default, limits how many
   unconsumed terminal bytes the host sends. The client opts in with the
   `GRAFTTY_TERMINAL_OUTPUT_WINDOW` environment request and acknowledges a
   cumulative byte count as it takes output. Control frames do not count, so
   they reach the client behind at most one window.
3. If the host ignores that request, `TerminalSessionClient` stops reading above
   4 MiB, which closes the standard SSH window. Nothing disconnects, but control
   frames share that fixed 16 MiB window and wait behind whatever it holds.

The relay on a Mac stops taking upstream output while its bounded queue is full,
so these limits apply across a one-hop attachment.

Measure the comparison with these opt-in probes. Native WebRTC runs in the last
one on macOS, and `TEST_RUNNER_GRAFTTY_TERMINAL_FLOW_PROBES=1` enables the parser
probe in `xcodebuild`:

```sh
GRAFTTY_TERMINAL_FLOW_PROBES=1 scripts/swiftpm test \
  --filter 'SSHTerminalBackpressureTests/probe|TerminalFlowWebRTCProbeTests'
```

Each probe prints one `[terminal-flow]` JSON line holding numbers only.
`probeDelayedLink` adds delay inside its test harness, and that harness's pump
limits it to about 3 MB/s, so use it for lag and not for throughput. These probes
do not measure a physical iPhone, cellular loss or network handoffs.

After a measurement change, run the shared tests and regenerate the specs:

```sh
scripts/swiftpm test --filter 'SSHNIOTransportUnitTests|PagedTerminalCoordinatorTests|TransportLatencySummaryTests|SSHTerminalBackpressureTests|TerminalOutputCredit'
scripts/generate-specs.py
```
