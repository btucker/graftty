# Remote networking experiments

The adaptive output policy is an experiment. Neither Mac nor mobile enables it by default. Both keep the existing 1 MiB output window.

The receiver estimates how long it takes to process delivered bytes before asking for more. It withholds cumulative acknowledgements to reduce the effective window to about 62.5 ms of consumer work, with a 128 KiB floor capped by the negotiated ceiling. It never acknowledges bytes that have not been delivered, and older hosts need no protocol change. Initial credit cannot be retracted.

## Measured tradeoff

The encrypted in-memory SSH fixture ran both policies sequentially with simulated round-trip delays. The slow consumer had a capacity of 2 MiB/s. Rates below are actual delivery after warm-up, including network waits. These single-run results are not device or Ethernet measurements.

| Simulated RTT | Fixed control delay | Adaptive control delay | Fixed sustained output | Adaptive sustained output |
| --- | ---: | ---: | ---: | ---: |
| 0 ms | 505 ms | 63 ms | 1.98 MiB/s | 1.97 MiB/s |
| 50 ms | 504 ms | 63 ms | 1.99 MiB/s | 1.97 MiB/s |
| 200 ms | 504 ms | 207 ms | 1.98 MiB/s | 0.61 MiB/s |

The fast-consumer phase precedes adaptation. It measured 10.84/10.71/4.95 MiB/s for fixed credit and 10.86/10.60/4.49 MiB/s for adaptive credit at the three RTTs.

A fixed 62.5 ms target helps interactive latency on nearby links but starves longer links. Before enabling it, add a network-delay-aware credit floor and measure both throughput and control delay again. Mobile currently queues parsing before requesting more output, so this readiness signal does not continuously measure parser completion there.

## Run the adaptive comparison

```sh
GRAFTTY_TERMINAL_FLOW_PROBES=1 scripts/swiftpm test --no-parallel \
  --filter 'SSHTerminalBackpressureTests.probeAdaptiveOutputCredit'
```

The JSON lines report configured capacity separately from measured sustained throughput. The regular regression tests cover monotone acknowledgements, negotiated bounds, excluding network waits, and restoring credit while receive is suspended with no new inbound frame.

## Local transport to rendered pixel

The native Mac probe sends a small synthetic OSC 11 background-color change through the production SSH transport, parses its echo, and observes the first matching GPU-rendered IOSurface at a CALayer contents change. It converts pixels from their declared color space into sRGB before matching.

It uses a clean configuration and an offscreen forced refresh/draw. This excludes ordinary app frame scheduling and physical display scanout. Each case records 25 samples after five warm-up samples, with cases run sequentially. These single-run p95 totals do not show a consistent rendered-pixel advantage for direct SSH.

| Load | Direct SSH p95 | WebRTC p95 |
| --- | ---: | ---: |
| Idle | 3.07 ms | 2.44 ms |
| Streaming sibling | 2.61 ms | 2.53 ms |
| Stalled sibling | 3.29 ms | 2.31 ms |

```sh
GRAFTTY_TERMINAL_FLOW_PROBES=1 scripts/swiftpm test --no-parallel \
  --filter 'MacPagedOutputDeadlockTests.nativeTransportLatency' \
  --attachments-path /tmp/graftty-native-latency
```

The child-process guard retains numeric JSON and failure diagnostics. Reports separate transport, native-write completion, and the matching-pixel timestamp. The parser's timestamp is recorded on its writer queue, before the main actor resumes. The isolated measurement has its own 45-second deadline; existing native deadlock tests retain their 15-second deadline.

## Device follow-up

Direct SSH and WebRTC loopback probes use fresh temporary identities and synthetic streams. They do not access paired terminals. Loopback transport timing cannot establish Ethernet or physical presentation latency. Test both actual Macs on the same reachable LAN, then include mobile parsing and rendering before changing routing defaults.
