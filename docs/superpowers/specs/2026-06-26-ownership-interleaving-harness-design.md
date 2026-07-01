# Display-Ownership Interleaving Harness — Design

**Date:** 2026-06-26
**Status:** Approved design; ready for implementation plan.
**Topic:** A randomized, shrinking, discrete-event model checker for the
display-ownership reconciliation boundary (`SessionDisplayOwnershipStore` plus the
Mac / iOS / web-server transport adapters).

## Why

graftty's recurring instability concentrates at one bug *shape*: graftty's cached
model of an external, asynchronous source of truth diverges from reality, with no
bounded, observable path back to consensus. It recurs at four boundaries — the zmx
PTY, git/gh polling, the remote transport, and the OS terminal surface. The
`ongoing-vertical-sizing-problems` branch already collapsed the **terminal-surface**
boundary into one explicit state machine (`SessionDisplayOwnershipStore`) with an
`epoch` fencing token and a single `isOwnerEligible` predicate — a sound design.

But the residual bugs on that branch live at the **seams**, not in the store:
"ignore stale web socket ownership callbacks," "fix visible resize reconcile
ordering," "fix web owner grid publish after delayed init," "harden Mac display
takeover commits." Each is a delayed/reordered snapshot being applied when it
shouldn't be. These are deep, multi-step ordering races that example-based unit
tests and stack traces don't reach, and that today can only be flushed out by manual
on-device validation (the branch's merge-readiness plan ships a 6-item manual
matrix because "unit tests cover the height math, not UIKit's live measurement
timing").

This harness attacks the **class**. It is a discrete-event simulator wrapped around
an oracle: the store + codec are the trusted spec, the real adapters are the code
under test, the scheduler is an adversary picking the worst legal ordering, the
oracle is a set of invariants checked after every step, and the shrinker converts a
failure deep in a 4,000-event run into a minimal numbered trace. That last property
is the direct cure for "the bugs are hard to collect the right context for."

## Decisions (locked during brainstorming)

| Axis | Decision |
| --- | --- |
| **Scope** | Full multi-transport model — store + codec + all three Swift transport adapters. |
| **Fidelity** | Drive the **real** Swift code everywhere reachable (store, `WebControlEnvelope`, Mac `HostManagedZmxBackend`, iOS `SessionClient`, web-server `WebSocketSessionCoordinator`); fake only the network/delivery layer. The TypeScript web-*client* follower (`TerminalPane.tsx`) is **out of scope** here — left to its Vitest suite. |
| **Search** | Randomized property-based with automatic **shrinking** to a minimal failing trace; a committed seed corpus is the deterministic CI gate, a larger random batch runs as a separate longer job. |
| **Engine** | Single-threaded **logical discrete-event scheduler** (no wall-clock). The fault model schedules adapter-internal deferred work as events, so init-ordering races are reachable. A real-thread soak mode is a later complement, not part of v1. |
| **Footprint** | **Purely additive** — a new `Tests/` target, zero production changes (all three adapter seams already exist). |

Reserved for later (explicitly *not* v1): exhaustive bounded model-checking;
real-async controlled-executor scheduling; real-thread soak; packet-loss / corruption
faults.

## Architecture — the loop

A single-threaded discrete-event simulator. Per seed:

1. Generate a list of client operations and a delivery-scheduling policy.
2. Push them as pending events.
3. Repeatedly pop the next event — seed-chosen among *everything currently pending*
   (client ops, in-flight deliveries, deferred adapter work) — and apply it.
4. After **every** event, check the **safety** invariants.
5. When the queue drains, check the **liveness** invariants.
6. On any violation, hand the full `(ops, schedule)` trace to the shrinker.

Determinism is total: identical seed ⇒ identical event order ⇒ reproducible failure,
which is what makes shrinking possible.

## Components

All real code except the network layer.

- **Store** — `SessionDisplayOwnershipStore`, called directly.
- **Codec** — `WebControlEnvelope` `parse` / `encoded`, used for every wire hop so we
  exercise the real serialization round-trip.
- **Web-server adapter** — `WebSocketSessionCoordinator.handleControl(envelope)` with a
  `Recorder` capturing its resizes / writes / sent envelopes (the pattern already used
  by `WebSocketBridgeOwnershipTests`), plus the real `WebDisplayOwnershipBroadcaster`.
- **Mac adapter** — `HostManagedZmxBackend` wired to the store through
  `HostManagedZmxOwnership` closures, with a fake `HostManagedZmxSession` that records
  every PTY resize attempt and reports an adopted size.
- **iOS adapter** — `SessionClient` constructed with an injected synchronous
  `WebSocketClient` fake; the harness feeds it server frames and captures what it
  sends. The async open path is driven through the fake rather than real `Task`
  scheduling; its deferred steps become explicit scheduler events (see F3).
- **FakeNetwork** — the in-flight delivery queue between adapters and the
  store/broadcaster; applies the fault model.
- **Oracle** — evaluates invariants (below).
- **Shrinker** — minimizes a failing trace.
- **Runner** — a Swift Testing entry point sweeping the seed corpus + a random batch.

Each follower adapter exposes its *applied view* `(epoch, grid, owner)` so the oracle
can compare it against the store's authoritative snapshot.

## Fault model

What the scheduler may perturb, per seed:

- **F1 — Cross-transport ordering.** Ops from Mac / iOS / web clients interleave in any
  order.
- **F2 — Delayed / reordered delivery.** A snapshot may be delivered after newer ops
  have occurred. **In-order within a single connection, reorderable across
  connections** — matching TCP/WebSocket reality (reliable, ordered per connection).
- **F3 — Adapter-internal deferred work.** `SessionClient`'s "open task completes
  later" and "publish after init" are modeled as schedulable events, so init-ordering
  races (the "web owner grid publish after delayed init" fix) are reachable.
- **F4 — Duplicate delivery (optional flag).** A snapshot delivered twice, for an
  idempotency check.

**Explicitly not modeled:** packet loss, permanent drop, or corruption — per-connection
delivery is reliable. The runner will `log()` this exclusion so it is never mistaken
for coverage.

## Operation alphabet

Generated per client, seed-driven:

- `attach(kind, role, visible, grid)`
- `detach`
- `claim` / `takeControl(grid)`
- `release`
- `ownerResize(grid)` — carrying the client's *believed* epoch
- `setVisible(bool)` — affects owner eligibility
- `hello` — on (re)connect

The generator deliberately emits **illegal** ops as well (a follower attempting a
resize; a stale-epoch `ownerResize`). Exercising the gates with invalid input is how we
confirm they reject it rather than drift.

## The oracle — invariants

### Safety (checked after every event)

- **S1** — at most one owner per session.
- **S2** — epoch never decreases; it strictly increases on every owner-identity change.
- **S3** — an `ownerResize(epoch = e)` is accepted only if `e == current epoch` and it
  comes from the current owner.
- **S4** — every emitted snapshot satisfies `ownerClientID == nil ⟺ ownerKind == nil`.
- **S5** *(the "stale web socket callback" class)* — a follower never applies a snapshot
  whose epoch is **lower** than the highest epoch it has already applied.
- **S6** *(the TERM-11.x render-desync class)* — the PTY is never resized by a
  non-owner (a per-event property; the matching *convergence* property — PTY size
  equals the owner's grid — is checked at quiescence by L1).
- **S7** — a follower never forwards input bytes to the PTY.

### Liveness (checked at quiescence — queue empty, no new ops)

- **L1** *(the "stale-until-restart" class)* — every connected adapter's
  `(owner, epoch, grid)` converges to the store's authoritative snapshot, **including
  the Mac PTY's last-attempted size equaling the owner's grid**.
- **L2** *(manual-matrix item 6)* — if the owner detaches, the session becomes ownerless
  with a bumped epoch and **no follower is silently promoted**.

## Error handling / shrink reporting

On a violation the engine holds the full `(ops, schedule)`. The shrinker greedily
removes operations and shortens delivery delays while the violation still reproduces,
then emits:

1. A **numbered human-readable transcript**, e.g.
   *"1. mac attaches 80×24 → owner=mac epoch=1; 2. iOS takeControl → owner=ios epoch=2;
   … 5. delayed mac ownerResize(epoch=1) delivered → applied by iOS follower → **S5
   VIOLATED**."*
2. An **auto-generated `@Test`** that replays the minimal trace as a permanent
   regression, added to the seed corpus.

## Testing & CI

A Swift Testing runner sweeps a **committed seed corpus** — deterministic, fast, the CI
gate — plus a larger **random batch** as a separate, longer job. Every newly shrunk
failure is added to the corpus as a regression seed, so the gate strictly grows.

## Location & coordination

Purely additive: a new `OwnershipModelTests` target (or folder) under `Tests/`, with
**no production changes** — all three adapter seams (`HostManagedZmxSession`,
`SessionClient`'s `webSocketFactory`, the web bridge's `handleControl`) already exist.

Build it in the `simplification` worktree against the `ongoing-vertical-sizing-problems`
branch merged in, and message that agent so they know it exists and can adopt it. It
lands via PR to their branch (or `main`) once it earns its keep.

## Success criteria

- **Re-catches at least one already-fixed seam race.** Reconstruct the "stale web socket
  callback" scenario and confirm the harness flags **S5** when that fix is reverted. A
  model checker that has never caught a known bug is unproven.
- The seed-corpus CI gate runs deterministically and fast enough to gate PRs.
- A fresh violation yields a minimal numbered trace **and** an auto-generated regression
  test, with no manual repro required.

## Generalization

The store + codec + adapter + fake-network + oracle + shrinker shape is reusable. Once
proven on the terminal-surface boundary, the same skeleton applies to the other three
recurring boundaries — git/gh polling, the remote transport, and the zmx PTY — making
this the template for hardening graftty's whole class of reconciliation bugs, not a
one-off.
