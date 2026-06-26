# Ownership-Model Harness

A single-threaded discrete-event model checker for Graftty's display-ownership
protocol. It drives the real production objects — `SessionDisplayOwnershipStore`,
`WebControlEnvelope` codec, Mac `HostManagedZmxBackend`, iOS `SessionClient` —
against a fake network, interleaving operations and deliveries randomly, then
checks a set of oracle invariants to detect correctness violations.

## Running

### CI gate (seeds 1–1000)

```
swift test --filter OwnershipModel
```

Runs approximately 1 000 randomized scenarios, each with 60 web-control
operations, on every push and PR.  If any seed produces a violation and the
violation is real (not a harness bug), stop there and shrink it (see below)
rather than narrowing the corpus or weakening assertions.

### Wide random batch (manual / nightly)

Generate seeds above 1 000 and replay them via `runScenario`:

```swift
// In a scratch test or REPL:
for seed: UInt64 in 1001...10000 {
    let result = runScenario(seed: seed, opCount: 60)
    if !result.violations.isEmpty {
        print("FAIL seed=\(seed): \(result.violations)")
    }
}
```

A wider opCount (e.g. 200) stresses longer ownership chains at the cost of
slower execution.

## Reading a shrunk failure and generating a regression test

When a seed fails, `shrink(seed:opCount:)` delta-debugs it to a minimal
reproducing trace:

```swift
if let f = shrink(seed: 42, opCount: 60) {
    print(f.transcript.joined(separator: "\n"))  // minimal event log
    print(f.asRegressionTest())                  // paste into HistoricalRegressionTests.swift
}
```

`asRegressionTest()` emits a standalone `@Test` snippet (with the necessary
`import` declarations) that replays the minimal op list.  The emitted test is
self-contained and compiles against the `OwnershipModelTests` target without
modification.

When a violation is interleaving-dependent (it survives `runScenario` but
disappears under `replayWebOps`'s sequential delivery), `asRegressionTest()`
emits a `.disabled` test with the op trace in a comment so the trace is
preserved without emitting a green no-op.

### Transcript format

Each transcript line from `runScenario` reads:

```
#N op=<opLabel> → owner=<id|none> epoch=<e> emit=<s>
  deliver[conn=C] connSeq=K emit=S epoch=E
```

`#N` is the zero-based op index.  `emit` is the monotonic emission sequence
(`emissionSeqCounter`) that tags this snapshot for ESN ordering.  Quiescence
lines (`L1 divergence`) appear after the final op when a follower did not
converge.

## Invariants

| ID | Name | Definition |
|----|------|-----------|
| S1 | Single owner | At most one owner client at any instant. |
| S2 | Epoch monotonic | The store epoch never decreases within a session; resets legitimately to 0 only after full teardown. |
| S3 | Stale resize rejected | An accepted `ownerResize` result always carries an epoch that matches the store's current epoch. |
| S4 | Owner-field consistency | `ownerClientID == nil` if and only if `ownerKind == nil`. |
| S5 | No superseded snapshot applied | A display follower never updates its ownership or grid state from a snapshot whose emission sequence (ESN) or epoch is lower than one already applied. |
| S6 | Non-owner never resizes PTY | A Mac backend in follower state never issues a PTY resize to its underlying zmx session. |
| S7 | Non-owner never writes input | A Mac backend in follower state never writes input bytes to its underlying zmx session. |
| L1 | Follower convergence | At quiescence every follower's applied epoch, applied emission sequence, and grid match the store's authoritative values. |
| L2 | Owner detach leaves ownerless | When the current owner detaches, the store transitions to ownerless without silently promoting another client. |

**Why ESN?** The store's `ownerResize` updates the grid without bumping the
ownership epoch, so epoch alone cannot version grids within a single ownership
tenure.  The harness stamps a monotonic emission sequence (`emissionSeqCounter`
in `MultiTransportWorld`) so S5 and L1 can detect same-epoch grid reordering
that an epoch-only guard would miss.

## Fault model

The harness exercises these failure classes:

- **F1 — cross-transport interleaving**: web-control ops, Mac backend lifecycle
  events, and iOS frame deliveries may interleave in any order within a
  scenario.
- **F2 — cross-connection reordering**: deliveries to different WebSocket
  connections (two in the default corpus sweep) may arrive in any order;
  `EventQueue.popNext` selects randomly.
- **F3 — intra-connection FIFO preserved**: within one connection `FakeNetwork`
  is strictly FIFO, mirroring TCP reality.
- **F4 — adapter-internal deferred work**: `MacResizeCoalescer` collapses all
  scheduled delays to zero and fires them synchronously in `quiesce()`, so
  coalesced resizes are always exercised rather than silently dropped.

**Explicit exclusions (out of scope):**

- Packet loss and corruption: per-connection delivery is reliable; the harness
  does not drop or corrupt payloads.
- Clock skew and wall-clock races: `ManualClock` removes all real-time
  dependencies from the iOS path; no `Task.sleep` or `Date` comparisons.
- Persistent storage failures: the model checker tests in-memory invariants
  only; `PERSIST-*` coverage lives in `GrafttyTests`.

## Extending to other reconciliation boundaries

The harness is organized around three reusable layers:

- **World** (`StoreWorld`, `MultiTransportWorld`): drives real production
  objects; adapters plug in by implementing a `fake*` collaborator.
- **Oracle** (`Oracle`, `Violation`): accumulates violations; `checkAfterEvent`
  checks S1–S4 after every store mutation; transport-specific checks (S5–S7)
  run inline in the world's delivery helpers.
- **Shrinker** (`shrink`, `shrinkWithPredicate`): delta-debugs a failing seed
  to a minimal reproducing trace.

To add a new boundary, follow this pattern:

### Git/gh polling boundary

Create a `FakeGitRunner` that records calls and can inject latency (delayed
results, hung processes) as `Event.deferred` tokens in `EventQueue`.  Add
an oracle check that verifies the sidebar state machine transitions are
monotonic (no state regressions under concurrent poll results).  Wire the fake
runner into `StoreWorld` or a new `SidebarWorld`.  The existing `shrink`
skeleton accepts any `([Op]) -> Bool` predicate so no shrinker changes are
needed.

### Remote transport boundary

Create a `FakeRemoteTransport` analogous to `FakeNetwork`: per-tunnel ordered
queues with cross-tunnel interleaving.  Register it in `MultiTransportWorld`
alongside the existing web WebSocket fake.  Add S5-equivalent invariants for
the remote ownership path (epoch and ESN guards on the `REMOTE-7.x` pane
control channel).  The existing `runScenario` loop pattern extends naturally
by adding a `.advanceRemoteTunnel` event kind to `Event`.

### zmx PTY boundary

The Mac seam is already covered (`MacSeamTests`, S6/S7 via `FakeZmxSession`).
To extend coverage to multi-pane PTY ownership (multiple panes sharing one
zmx session), introduce a `FakePaneRegistry` that maps pane IDs to ownership
states and add S6/S7 assertions per-pane rather than per-backend.  The
`MacResizeCoalescer` fake already collapses delays, so the coalescing boundary
is covered; new work would add the per-pane multiplexing invariant.

## Gate-honesty

A green macOS `OwnershipModel` run exercises REAL production code for S1–S4
(`SessionDisplayOwnershipStore` + `WebSocketBridgeCoordinator`), S5/L1
(`WebFollowerView` guard via genuine multi-path cross-channel reordering — see
`multiPathGuardIsNonVacuous` in `WebModelCheckTests.swift`), L2 (owner release
leaves store ownerless — see `l2PathIsNonVacuous`), and S6/S7 (Mac
`HostManagedZmxBackend` via `MacSeamTests`).

**The modeled follower** (`WebFollowerView`) stands in for the TypeScript web
client.  It is correct by construction — the guard is the production invariant
encoded in Swift.

**The real iOS follower** (`SessionClient`) is `#if canImport(UIKit)` and
compiles only on the iOS SDK.  It runs under the `ios-build-and-test` job in
`ci.yml`.  A green macOS run does **not** by itself certify the real iOS
follower; iOS CI is the authoritative check for that seam.

**Not yet exercised:** the `claimOwnerIfOwnerlessOrCurrent` rejection path
(the binary-frame implicit-claim guard in `WebSocketBridgeCoordinator`) is not
driven by any generated op in the current corpus.  Adding a `.binaryFrame` op
kind to `nextWebOp` would cover it.

## Real findings

The harness has already produced two actionable findings:

1. **iOS epoch guard absent** (`IOSSeamTests.iosFollowerIgnoresSupersededOwnershipFrame`,
   `.disabled`): `SessionClient.handleTextFrame` applies `.ownership(snapshot)`
   unconditionally — no monotonic epoch guard.  A stale frame rolls the iOS
   client's view back to an older epoch; the iOS owner then emits `ownerResize`
   with that stale epoch, which the store rejects, so the iOS owner silently
   loses resize capability.  The one-line fix lives in `Sources/` and was
   escalated to a separate reviewed change.

2. **Epoch does not version grids**: `ownerResize` updates the grid without
   bumping the epoch, so an epoch-only guard on followers does not prevent
   same-epoch grid reordering.  The ESN strengthening (S5 by `emissionSeq`)
   was added to the harness to catch this class; the production fix lives in
   `WebFollowerView`'s two-part monotonic guard.
