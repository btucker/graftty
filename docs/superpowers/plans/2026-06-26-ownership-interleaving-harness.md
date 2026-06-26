# Display-Ownership Interleaving Harness Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a randomized, shrinking, single-threaded discrete-event model checker that drives the **real** `SessionDisplayOwnershipStore` + `WebControlEnvelope` codec + Mac/iOS/web-server adapters against a fake network, and flags any violation of the display-ownership safety/liveness invariants with a minimal numbered trace.

**Architecture:** A new additive Swift Testing target. A seeded PRNG generates client-operation sequences plus a delivery schedule; a discrete-event scheduler applies them to the real store and real adapters with PTY/socket/clock faked; an oracle checks invariants S1–S7 after every event and L1–L2 at quiescence; a shrinker minimizes any failing trace. Built incrementally: store → web-server adapter → Mac adapter → iOS adapter → shrinker → CI corpus.

**Tech Stack:** Swift 5.10, Swift Testing, the existing `Graftty` / `GrafttyKit` / `GrafttyMobileKit` / `GrafttyProtocol` targets, SwiftPM.

Design spec: `docs/superpowers/specs/2026-06-26-ownership-interleaving-harness-design.md`.

## Global Constraints

- **Determinism is mandatory.** All randomness comes from the harness's own seeded PRNG (`DeterministicRNG`, SplitMix64). Never use `SystemRandomNumberGenerator`, `Int.random()`, `Date()`, `UUID()`, `Task.sleep`, or wall-clock time anywhere in the harness. Identical seed ⇒ identical run.
- **No production changes.** The harness is test-only code. The three adapter seams already exist (`HostManagedZmxSession`, `SessionClient.webSocketFactory`, `WebSocketSessionCoordinator.handleControl`). If a task appears to need a production change, STOP and report — do not edit `Sources/`.
- **Drive real code.** Use the real `SessionDisplayOwnershipStore`, real `WebControlEnvelope.parse`/`encoded`, and the real adapter types. Fakes are allowed only for the network, the PTY (`HostManagedZmxSession`), the socket (`WebSocketClient`), and the clock (`Clock`).
- **TDD + frequent commits.** Every task is RED → GREEN → commit. Run `swift test --filter OwnershipModel` after each task.
- **Real types (verbatim from the codebase), reused across tasks:**
  - `DisplayClientID(_ rawValue: String)`; `enum DisplayClientKind: String { case mac, web, ios, preview }` (confirm exact cases by reading `Sources/GrafttyProtocol/DisplayOwnership.swift`); `enum DisplayClientRole: String` (incl. `.interactive`, `.preview`); `struct DisplayGrid { let cols: UInt16; let rows: UInt16; init(cols:rows:) throws }`.
  - `DisplayOwnershipSnapshot { sessionName; ownerClientID: DisplayClientID?; ownerKind: DisplayClientKind?; grid: DisplayGrid; epoch: UInt64 }` — self-validates `ownerClientID == nil ⟺ ownerKind == nil`.
  - Store mutators: `attachClient(sessionName:clientID:kind:role:visible:grid:) -> DisplayOwnershipSnapshot`, `claimOwner(...) -> SessionDisplayOwnershipClaimResult`, `claimOwnerIfOwnerlessOrCurrent(...)`, `ownerResize(sessionName:clientID:epoch:grid:) -> SessionDisplayOwnershipResizeResult`, `detachClient(...)`, `releaseOwner(...)`, `restoreOwnerAfterFailedClaim(...)`, `snapshot(sessionName:fallbackGrid:)`, `addObserver(_:) -> ObserverToken`. (`SessionDisplayOwnership{Claim,Resize}Result` each carry `.accepted: Bool` + `.snapshot`.)
  - `WebControlEnvelope` cases: `.resize`, `.grid`, `.hello(clientID:kind:role:visible:cols:rows:)`, `.takeControl(clientID:kind:cols:rows:)`, `.ownerResize(clientID:epoch:cols:rows:)`, `.ownership(DisplayOwnershipSnapshot)`; `static parse(Data) throws -> WebControlEnvelope`; `func encoded() -> String`.

---

## Task 0: Establish branch base and test target

**Files:**
- Modify: `Package.swift` (add the `OwnershipModelTests` test target)
- Create: `Tests/OwnershipModelTests/SmokeTests.swift`

**Interfaces:**
- Produces: a compiling, runnable `OwnershipModelTests` target that links `Graftty`, `GrafttyKit`, `GrafttyMobileKit`, `GrafttyProtocol`.

- [ ] **Step 1: Establish the branch base.** The harness compiles only against the ownership adapters, which live on `ongoing-vertical-sizing-problems`. Merge that branch into `simplification`:

```bash
cd /Users/btucker/projects/graftty/.worktrees/simplification
git fetch origin
git merge --no-edit ongoing-vertical-sizing-problems
swift build 2>&1 | tail -5   # confirm the base compiles before adding anything
```
Expected: clean merge (the harness adds only test files) and a successful build. If the merge conflicts, STOP and report — do not force it.

- [ ] **Step 2: Add the test target to `Package.swift`.** Locate the `targets:` array and add a `.testTarget`:

```swift
.testTarget(
    name: "OwnershipModelTests",
    dependencies: ["Graftty", "GrafttyKit", "GrafttyMobileKit", "GrafttyProtocol"],
    path: "Tests/OwnershipModelTests"
),
```

- [ ] **Step 3: Write a smoke test** in `Tests/OwnershipModelTests/SmokeTests.swift`:

```swift
import Testing
@testable import GrafttyKit
import GrafttyProtocol

@Suite("Ownership model harness smoke")
struct SmokeTests {
    @Test func storeIsReachableFromHarnessTarget() throws {
        let store = SessionDisplayOwnershipStore()
        let snap = store.snapshot(sessionName: "s")
        #expect(snap.isOwnerless)
    }
}
```

- [ ] **Step 4: Run it.** `swift test --filter OwnershipModel` → Expected: PASS.
- [ ] **Step 5: Commit.**

```bash
git add Package.swift Tests/OwnershipModelTests/SmokeTests.swift
git commit -m "test(ownership-model): scaffold interleaving harness target"
```

---

## Task 1: Deterministic seeded PRNG

**Files:**
- Create: `Tests/OwnershipModelTests/DeterministicRNG.swift`
- Test: `Tests/OwnershipModelTests/DeterministicRNGTests.swift`

**Interfaces:**
- Produces: `struct DeterministicRNG: RandomNumberGenerator { init(seed: UInt64); mutating func next() -> UInt64 }` plus helpers `mutating func int(in range: Range<Int>) -> Int` and `mutating func pick<T>(_ xs: [T]) -> T`. Every later task that needs randomness consumes this and nothing else.

- [ ] **Step 1: Write the failing test:**

```swift
import Testing
@testable import GrafttyKit  // target membership; type lives in this test target

@Suite("DeterministicRNG")
struct DeterministicRNGTests {
    @Test func sameSeedSameSequence() {
        var a = DeterministicRNG(seed: 0xABCD)
        var b = DeterministicRNG(seed: 0xABCD)
        let xs = (0..<8).map { _ in a.next() }
        let ys = (0..<8).map { _ in b.next() }
        #expect(xs == ys)
    }
    @Test func differentSeedDiffers() {
        var a = DeterministicRNG(seed: 1)
        var b = DeterministicRNG(seed: 2)
        #expect(a.next() != b.next())
    }
    @Test func pickIsInBounds() {
        var r = DeterministicRNG(seed: 7)
        for _ in 0..<100 { #expect((0..<3).contains(r.int(in: 0..<3))) }
    }
}
```

- [ ] **Step 2: Run → FAIL** ("cannot find DeterministicRNG"). `swift test --filter DeterministicRNG`.
- [ ] **Step 3: Implement** SplitMix64 in `DeterministicRNG.swift`:

```swift
struct DeterministicRNG: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state = state &+ 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
    mutating func int(in range: Range<Int>) -> Int {
        precondition(!range.isEmpty)
        return range.lowerBound + Int(next() % UInt64(range.count))
    }
    mutating func pick<T>(_ xs: [T]) -> T { xs[int(in: 0..<xs.count)] }
}
```

- [ ] **Step 4: Run → PASS.**
- [ ] **Step 5: Commit.** `git commit -am "test(ownership-model): deterministic SplitMix64 RNG"`

---

## Task 2: World model — clients, operation alphabet, and the event queue

**Files:**
- Create: `Tests/OwnershipModelTests/ModelTypes.swift` (`ModelClient`, `Op`, `Event`)
- Create: `Tests/OwnershipModelTests/EventQueue.swift`
- Test: `Tests/OwnershipModelTests/EventQueueTests.swift`

**Interfaces:**
- Produces:
  - `struct ModelClient { let id: DisplayClientID; let kind: DisplayClientKind; let role: DisplayClientRole }`
  - `enum Op { case attach(ModelClient, visible: Bool, grid: DisplayGrid); case detach(DisplayClientID); case takeControl(DisplayClientID, grid: DisplayGrid); case release(DisplayClientID); case ownerResize(DisplayClientID, believedEpoch: UInt64, grid: DisplayGrid); case setVisible(DisplayClientID, Bool); case hello(DisplayClientID) }`
  - `enum Event { case op(Op); case deliver(Delivery); case deferred(DeferredWork) }` where `Delivery` carries `(target: DisplayClientID, snapshot: DisplayOwnershipSnapshot, connectionSeq: Int)` and `DeferredWork` is an opaque `() -> Void` token with a stable id for transcripts.
  - `struct EventQueue { mutating func push(_ e: Event); mutating func popNext(using rng: inout DeterministicRNG) -> Event?; var isEmpty: Bool }` — `popNext` picks a uniformly random pending event (this is the adversary).

- [ ] **Step 1: Write the failing test** for the queue's defining property — it drains every pushed event, and order is a deterministic function of the seed:

```swift
import Testing
import GrafttyProtocol

@Suite("EventQueue")
struct EventQueueTests {
    private func grid(_ c: UInt16, _ r: UInt16) -> DisplayGrid { try! DisplayGrid(cols: c, rows: r) }

    @Test func drainsAllPushedEvents() {
        var q = EventQueue()
        let ops: [Op] = (0..<5).map { .release(DisplayClientID("c\($0)")) }
        ops.forEach { q.push(.op($0)) }
        var rng = DeterministicRNG(seed: 99)
        var drained = 0
        while q.popNext(using: &rng) != nil { drained += 1 }
        #expect(drained == 5)
        #expect(q.isEmpty)
    }

    @Test func orderIsSeedDeterministic() {
        func run(_ seed: UInt64) -> [String] {
            var q = EventQueue()
            (0..<6).forEach { q.push(.op(.release(DisplayClientID("c\($0)")))) }
            var rng = DeterministicRNG(seed: seed)
            var out: [String] = []
            while let e = q.popNext(using: &rng), case let .op(.release(id)) = e { out.append(id.description) }
            return out
        }
        #expect(run(5) == run(5))
        #expect(run(5) != run(6))  // overwhelmingly likely; if it ever flakes, the RNG is broken
    }
}
```

- [ ] **Step 2: Run → FAIL.**
- [ ] **Step 3: Implement** `ModelTypes.swift` (the enums above) and `EventQueue.swift`. The queue holds `[Event]`; `popNext` does `let i = rng.int(in: 0..<events.count); return events.remove(at: i)` (guard empty → nil). Keep `Delivery`/`DeferredWork` minimal — just enough for the test to compile; richer fields arrive with their consuming tasks.
- [ ] **Step 4: Run → PASS.**
- [ ] **Step 5: Commit.** `git commit -am "test(ownership-model): world types + adversary event queue"`

---

## Task 3: Oracle — store-level invariants S1–S4

**Files:**
- Create: `Tests/OwnershipModelTests/Oracle.swift`
- Create: `Tests/OwnershipModelTests/StoreWorld.swift` (drives ONLY the real store; adapters arrive later)
- Test: `Tests/OwnershipModelTests/StoreInvariantTests.swift`

**Interfaces:**
- Produces:
  - `enum Violation: Equatable { case s1MultipleOwners; case s2EpochRegressed(from: UInt64, to: UInt64); case s3StaleResizeAccepted(epoch: UInt64, current: UInt64); case s4InconsistentOwnerFields; case s5SupersededApplied(target: DisplayClientID, applied: UInt64, highest: UInt64); case s6NonOwnerResizedPTY(DisplayClientID); case s7NonOwnerInput(DisplayClientID); case l1Divergence(target: DisplayClientID); case l2SilentPromotion(DisplayClientID) }`
  - `struct Oracle { mutating func checkAfterEvent(store: SessionDisplayOwnershipStore, session: String, lastResize: SessionDisplayOwnershipResizeResult?, requestedEpoch: UInt64?) -> [Violation] }` — tracks the highest epoch seen across calls to detect S2 regressions.
  - `struct StoreWorld` that owns a real `SessionDisplayOwnershipStore` and applies an `Op` to it (ignoring adapter-only ops for now), returning the relevant result so the oracle can inspect it.

- [ ] **Step 1: Write the failing test.** First a positive control (random legal-ish op sequences never violate S1–S4), then a negative control (a deliberately injected stale resize is caught):

```swift
import Testing
import GrafttyProtocol
@testable import GrafttyKit

@Suite("Store invariants S1-S4")
struct StoreInvariantTests {
    private func grid(_ c: UInt16) -> DisplayGrid { try! DisplayGrid(cols: c, rows: 24) }

    @Test(arguments: Array<UInt64>(1...200))
    func randomSequencesNeverViolateStoreInvariants(seed: UInt64) {
        var world = StoreWorld(session: "main")
        var oracle = Oracle()
        var rng = DeterministicRNG(seed: seed)
        let clients = (0..<3).map { ModelClient(id: DisplayClientID("c\($0)"), kind: .mac, role: .interactive) }
        for _ in 0..<40 {
            let op = world.randomLegalOp(clients: clients, using: &rng)
            let result = world.apply(op)
            #expect(oracle.checkAfterEvent(store: world.store, session: "main",
                                           lastResize: result.resize, requestedEpoch: result.requestedEpoch).isEmpty)
        }
    }

    @Test func staleResizeIsRejectedByStoreAndOracleAgrees() throws {
        var world = StoreWorld(session: "main")
        let c = ModelClient(id: DisplayClientID("c0"), kind: .mac, role: .interactive)
        _ = world.apply(.attach(c, visible: true, grid: grid(80)))
        _ = world.apply(.takeControl(c.id, grid: grid(80)))   // epoch advances
        let stale = world.apply(.ownerResize(c.id, believedEpoch: 0, grid: grid(120)))  // wrong epoch
        #expect(stale.resize?.accepted == false)               // store rejects; S3 holds (no violation)
    }
}
```

- [ ] **Step 2: Run → FAIL.**
- [ ] **Step 3: Implement** `StoreWorld` (apply each `Op` to the real store; `randomLegalOp` builds an op from the client set using `rng`; track each client's last-known epoch so `ownerResize` can carry a believed epoch), and `Oracle.checkAfterEvent` for S1–S4: S1/S4 by reading `store.snapshot(...)`; S2 by comparing the snapshot epoch to the highest previously seen; S3 by asserting `result.accepted` implies `requestedEpoch == snapshot.epoch`.
- [ ] **Step 4: Run → PASS.**
- [ ] **Step 5: Commit.** `git commit -am "test(ownership-model): oracle + store invariants S1-S4"`

---

## Task 4: Fake network + web-server adapter (S5 / L1 for the web follower)

**Files:**
- Create: `Tests/OwnershipModelTests/FakeNetwork.swift`
- Create: `Tests/OwnershipModelTests/WebFollowerView.swift`
- Create: `Tests/OwnershipModelTests/MultiTransportWorld.swift` (extends `StoreWorld` with the web-server adapter)
- Test: `Tests/OwnershipModelTests/WebSeamTests.swift`

**Interfaces:**
- Consumes: the real `WebSocketSessionCoordinator.handleControl(_:)` (read `Tests/GrafttyKitTests/Web/WebSocketBridgeOwnershipTests.swift` for the `makeCoordinator`/`Recorder` construction pattern and reuse it verbatim) and the real `WebDisplayOwnershipBroadcaster`.
- Produces:
  - `final class WebFollowerView` recording the highest epoch it has applied; `func apply(_ snapshot: DisplayOwnershipSnapshot)` updates `(epoch, grid, owner)` only if `snapshot.epoch >= highestApplied` (this mirrors the real follower's intended guard — the harness's job is to detect when the REAL adapter fails to enforce it, so the view records the raw apply and the oracle judges).
  - `struct FakeNetwork` holding per-connection ordered out-queues; `mutating func enqueue(target:snapshot:connection:)` and integration with `EventQueue` so a `.deliver` event pops the next in-order frame for that connection. Cross-connection order is free (the scheduler interleaves); intra-connection order is preserved.

- [ ] **Step 1: Write the failing test** — the canonical stale-callback scenario (design success criterion). Drive the web coordinator to take control twice so epoch advances, then deliver the FIRST (lower-epoch) ownership snapshot to the follower AFTER the second; the oracle must raise `s5SupersededApplied` only if the follower applied it:

```swift
import Testing
import GrafttyProtocol
@testable import GrafttyKit

@Suite("Web seam S5/L1")
struct WebSeamTests {
    @Test func delayedLowerEpochSnapshotNeverAppliedOverNewer() throws {
        var world = MultiTransportWorld(session: "main")
        let web = DisplayClientID("web-1")
        world.webHandle(.hello(clientID: web, kind: .web, role: .interactive, visible: true, cols: 80, rows: 24))
        world.webHandle(.takeControl(clientID: web, kind: .web, cols: 80, rows: 24))   // epoch e1
        let e1Snapshot = world.store.snapshot(sessionName: "main")
        world.webHandle(.ownerResize(clientID: web, epoch: e1Snapshot.epoch, cols: 100, rows: 24)) // epoch e2 grid
        let newer = world.store.snapshot(sessionName: "main")
        // Deliver the stale e1 snapshot to the follower AFTER newer:
        world.deliverToWebFollower(newer)
        world.deliverToWebFollower(e1Snapshot)
        #expect(world.oracle.violations.contains(.s5SupersededApplied(target: web, applied: e1Snapshot.epoch, highest: newer.epoch)) == false)
        // Convergence (L1): the follower's applied epoch equals the store's.
        #expect(world.webFollower.highestApplied == newer.epoch)
    }
}
```

- [ ] **Step 2: Run → FAIL.**
- [ ] **Step 3: Implement** `MultiTransportWorld` wrapping the store + a real `WebSocketSessionCoordinator` (constructed as in `WebSocketBridgeOwnershipTests`), `webHandle` forwarding envelopes to `coordinator.handleControl`, `deliverToWebFollower` routing a snapshot through `WebFollowerView.apply` and invoking `Oracle` S5 (raise `s5SupersededApplied` when `apply` receives a lower epoch than `highestApplied`). Add L1 to the oracle: at quiescence `webFollower.highestApplied == store.snapshot().epoch`.
- [ ] **Step 4: Run → PASS.**
- [ ] **Step 5: Commit.** `git commit -am "test(ownership-model): fake network + web seam, S5/L1"`

---

## Task 5: Randomized web-transport driver (the first real model-check run)

**Files:**
- Create: `Tests/OwnershipModelTests/Runner.swift` (`runScenario(seed:opCount:) -> RunResult`)
- Test: `Tests/OwnershipModelTests/WebModelCheckTests.swift`

**Interfaces:**
- Produces: `struct RunResult { let seed: UInt64; let violations: [Violation]; let transcript: [String] }` and `func runScenario(seed: UInt64, opCount: Int) -> RunResult` that: generates ops over a mixed Mac+web client set, pushes them and their resulting deliveries into the `EventQueue`, drains via `popNext`, runs the oracle after each event, and collects a per-step transcript line.

- [ ] **Step 1: Write the failing test** — a seed sweep that must stay clean (positive control across the whole engine):

```swift
import Testing

@Suite("Web model-check sweep")
struct WebModelCheckTests {
    @Test(arguments: Array<UInt64>(1...500))
    func noInvariantViolationsAcrossSeeds(seed: UInt64) {
        let result = runScenario(seed: seed, opCount: 60)
        #expect(result.violations.isEmpty, "seed \(seed): \(result.violations)\n\(result.transcript.joined(separator: "\n"))")
    }
}
```

- [ ] **Step 2: Run → FAIL** (compile error / `runScenario` missing). Then once it compiles, if it surfaces a REAL violation, STOP and report — that is a genuine finding, not a test to force green. Capture the seed.
- [ ] **Step 3: Implement** `runScenario`: build clients, loop `opCount` times generating a legal-or-illegal op, apply to `MultiTransportWorld`, enqueue the resulting ownership snapshot as a `.deliver` to each follower's connection, drain the queue picking events via `popNext`, calling the oracle after each. Append a transcript line per event (e.g. `"#\(n) op=\(op) → owner=\(snap.ownerKind) epoch=\(snap.epoch)"`).
- [ ] **Step 4: Run → PASS** (clean sweep) or a reported finding.
- [ ] **Step 5: Commit.** `git commit -am "test(ownership-model): randomized web-transport model check"`

---

## Task 6: Mac adapter integration (S6 / S7 + PTY convergence)

**Files:**
- Create: `Tests/OwnershipModelTests/FakeZmxSession.swift` (conforms to `HostManagedZmxSession`)
- Modify: `Tests/OwnershipModelTests/MultiTransportWorld.swift` (add the Mac adapter)
- Test: `Tests/OwnershipModelTests/MacSeamTests.swift`

**Interfaces:**
- Consumes: `protocol HostManagedZmxSession { func start() throws; func write(_ data: Data) throws; func resize(cols: UInt16, rows: UInt16) throws; func close() }` and `HostManagedZmxOwnership` (the closure-bundle that wires the backend to the store — read `Sources/Graftty/Terminal/HostManagedZmxBackend.swift:24-58` for its initializer and bind each closure to the real store method). Wire the Mac backend via `ownership:` and `sessionFactory:` so the fake session is injected.
- Produces: `final class FakeZmxSession: HostManagedZmxSession` recording `resizes: [(UInt16,UInt16)]` and `writes: [Data]`; the Mac branch of `MultiTransportWorld` exposing the last PTY-attempted size and whether any input write occurred while the Mac client was a follower.

- [ ] **Step 1: Write the failing test:**

```swift
import Testing
import GrafttyProtocol
@testable import Graftty
@testable import GrafttyKit

@Suite("Mac seam S6/S7")
struct MacSeamTests {
    @Test func followerMacNeverResizesPTYAndConvergesToOwnerGrid() throws {
        var world = MultiTransportWorld(session: "main")
        let mac = DisplayClientID("mac-1"); let web = DisplayClientID("web-1")
        world.attachMac(id: mac, grid: try DisplayGrid(cols: 80, rows: 24))      // mac becomes owner
        world.webHandle(.hello(clientID: web, kind: .web, role: .interactive, visible: true, cols: 100, rows: 30))
        world.webHandle(.takeControl(clientID: web, kind: .web, cols: 100, rows: 30)) // web takes over; mac is follower
        world.quiesce()
        #expect(world.oracle.violations.contains { if case .s6NonOwnerResizedPTY = $0 { return true }; return false } == false)
        #expect(world.macPTYLastSize == nil || world.macPTYLastSize! == (100, 30)) // converges to owner grid (L1)
    }
}
```

- [ ] **Step 2: Run → FAIL.**
- [ ] **Step 3: Implement** `FakeZmxSession`, wire the real `HostManagedZmxBackend` into `MultiTransportWorld` with `ownership:` closures bound to the store and `sessionFactory:` returning the fake. Feed the backend its ownership-snapshot observer so it reacts to takeovers. Oracle S6: any `FakeZmxSession.resize` recorded while the Mac client is not the store's owner ⇒ `s6NonOwnerResizedPTY`. S7: any `write` while follower ⇒ `s7NonOwnerInput`. Extend `quiesce()` + L1 to assert PTY last size equals owner grid.
- [ ] **Step 4: Run → PASS.**
- [ ] **Step 5: Commit.** `git commit -am "test(ownership-model): Mac seam, S6/S7 + PTY convergence"`

---

## Task 7: iOS adapter integration (the async transport)

**Files:**
- Create: `Tests/OwnershipModelTests/FakeWebSocketClient.swift` (conforms to `WebSocketClient`)
- Create: `Tests/OwnershipModelTests/ManualClock.swift` (deterministic `Clock`)
- Modify: `Tests/OwnershipModelTests/MultiTransportWorld.swift`
- Test: `Tests/OwnershipModelTests/IOSSeamTests.swift`

**Interfaces:**
- Consumes: `protocol WebSocketClient: AnyObject { var supportsWebControlTextFrames: Bool { get }; func send(_:) async throws; func receive() async throws -> WebSocketFrame; func close(); func resize(cols:rows:) async; func sendHello(...) async; func takeControl(...) async; func ownerResize(...) async }` and `SessionClient.init(sessionName:webSocketFactory:clock:...)`.
- Produces: `final class FakeWebSocketClient: WebSocketClient` whose `receive()` returns frames the harness enqueues via `enqueueIncoming(_ frame: WebSocketFrame)` and suspends (awaitable continuation) until one is available; `ManualClock` advancing only when the scheduler ticks it; an `await world.pumpIOS()` that lets the `SessionClient` receive-loop consume exactly the frames currently enqueued and then return to quiescence.

> **Determinism note:** `SessionClient` runs a real `Task` receive loop. The harness must NOT race it. Drive it by: (a) injecting `FakeWebSocketClient` + `ManualClock`; (b) enqueuing incoming frames; (c) `await pumpIOS()` which awaits a harness-owned continuation the fake signals once it has delivered all currently-queued frames. No `Task.sleep`, no real time. If full determinism proves impossible for a given interaction, mark that specific assertion `.disabled("iOS async pump: needs controlled executor — see design §engine option 2")` and report it rather than introducing wall-clock waits.

- [ ] **Step 1: Write the failing test:**

```swift
import Testing
import GrafttyProtocol
@testable import GrafttyMobileKit

@Suite("iOS seam S5/L1")
struct IOSSeamTests {
    @Test func iosFollowerIgnoresSupersededOwnershipFrame() async throws {
        var world = MultiTransportWorld(session: "main")
        let ios = DisplayClientID("ios-1")
        await world.attachIOS(id: ios)                  // ios connects as follower (kind .ios never auto-owns)
        let e1 = world.makeOwnershipFrame(epoch: 1, cols: 80)
        let e2 = world.makeOwnershipFrame(epoch: 2, cols: 100)
        world.enqueueIOSIncoming(e2)                     // newer first
        world.enqueueIOSIncoming(e1)                     // then stale
        await world.pumpIOS()
        #expect(world.oracle.violations.contains { if case .s5SupersededApplied = $0 { return true }; return false } == false)
        #expect(world.iosAppliedEpoch == 2)              // L1: converged to newest, ignored stale
    }
}
```

- [ ] **Step 2: Run → FAIL.**
- [ ] **Step 3: Implement** `FakeWebSocketClient`, `ManualClock`, and the iOS branch of `MultiTransportWorld` (construct `SessionClient` with the fake factory + manual clock; expose the applied ownership epoch via the client's observable state). Implement `pumpIOS()` per the determinism note.
- [ ] **Step 4: Run → PASS** (or the marked-disabled fallback + report).
- [ ] **Step 5: Commit.** `git commit -am "test(ownership-model): iOS async seam, S5/L1"`

---

## Task 8: Shrinker + numbered transcript + regression emitter

**Files:**
- Create: `Tests/OwnershipModelTests/Shrinker.swift`
- Test: `Tests/OwnershipModelTests/ShrinkerTests.swift`

**Interfaces:**
- Produces: `func shrink(seed: UInt64, opCount: Int) -> ShrunkFailure?` where `ShrunkFailure { let ops: [Op]; let schedule: [Int]; let violation: Violation; let transcript: [String]; func asRegressionTest() -> String }`. Shrinking is delta-debugging: given a failing `(ops, schedule)`, greedily drop ops/shorten delays while `runScenario`-equivalent replay still reproduces the same `Violation`.

- [ ] **Step 1: Write the failing test** using a *synthetic* always-failing oracle hook (inject a predicate that flags as a violation any run containing a specific op), then assert the shrinker reduces a 50-op scenario to the 1 essential op:

```swift
import Testing

@Suite("Shrinker")
struct ShrinkerTests {
    @Test func reducesToMinimalReproducingTrace() {
        // A planted violation: "any trace containing a release of c7".
        let shrunk = shrinkWithPredicate(seed: 3, opCount: 50) { ops in
            ops.contains { if case let .release(id) = $0, id == DisplayClientID("c7") { return true }; return false }
        }
        #expect(shrunk != nil)
        #expect(shrunk!.ops.count == 1)
        if case let .release(id) = shrunk!.ops[0] { #expect(id == DisplayClientID("c7")) } else { Issue.record("wrong op") }
    }
}
```

- [ ] **Step 2: Run → FAIL.**
- [ ] **Step 3: Implement** delta-debugging shrink + `asRegressionTest()` emitting a `@Test` that replays the minimal op list. Provide both `shrink(seed:opCount:)` (real oracle) and the `shrinkWithPredicate` test seam.
- [ ] **Step 4: Run → PASS.**
- [ ] **Step 5: Commit.** `git commit -am "test(ownership-model): delta-debugging shrinker + regression emitter"`

---

## Task 9: Seed corpus, CI gate, and the historical-bug re-catch

**Files:**
- Create: `Tests/OwnershipModelTests/SeedCorpus.swift` (the committed deterministic gate)
- Create: `Tests/OwnershipModelTests/HistoricalRegressionTests.swift`
- Modify: `.github/workflows/ci.yml` (add an `ownership-model` job step)
- Test: the corpus sweep itself.

**Interfaces:**
- Consumes: `runScenario`, `shrink`, all oracle invariants.
- Produces: a `corpusSeeds: [UInt64]` gate test and at least one historical-bug reproduction proving the harness has teeth (design success criterion).

- [ ] **Step 1: Write the historical re-catch test.** Reconstruct the "ignore stale web socket ownership callbacks" scenario directly (a follower receiving a lower-epoch ownership frame after a newer one) and assert that, when the follower view's epoch guard is bypassed (a `bypassEpochGuard: true` flag on `WebFollowerView` used ONLY in this test), the oracle raises `s5SupersededApplied` — proving the invariant catches the real regression:

```swift
import Testing
import GrafttyProtocol
@testable import GrafttyKit

@Suite("Historical regression re-catch")
struct HistoricalRegressionTests {
    @Test func s5CatchesStaleWebsocketCallback() throws {
        var world = MultiTransportWorld(session: "main")
        world.webFollower.bypassEpochGuard = true        // simulate the pre-fix adapter
        let web = DisplayClientID("web-1")
        world.webHandle(.hello(clientID: web, kind: .web, role: .interactive, visible: true, cols: 80, rows: 24))
        world.webHandle(.takeControl(clientID: web, kind: .web, cols: 80, rows: 24))
        let e1 = world.store.snapshot(sessionName: "main")
        world.webHandle(.ownerResize(clientID: web, epoch: e1.epoch, cols: 100, rows: 24))
        let e2 = world.store.snapshot(sessionName: "main")
        world.deliverToWebFollower(e2)
        world.deliverToWebFollower(e1)                    // stale, applied because guard bypassed
        #expect(world.oracle.violations.contains(.s5SupersededApplied(target: web, applied: e1.epoch, highest: e2.epoch)))
    }
}
```

- [ ] **Step 2: Run → FAIL,** then implement the `bypassEpochGuard` test seam on `WebFollowerView` (test-only) and `corpusSeeds` (start with `Array(1...1000)`), and a corpus sweep test mirroring Task 5 over `corpusSeeds`.
- [ ] **Step 3: Run → PASS.**
- [ ] **Step 4: Add the CI job.** In `.github/workflows/ci.yml`, add a step to the test job: `swift test --filter OwnershipModel`. Keep the long random batch (seeds > 1000) out of the gate; document it as a manual/nightly invocation in a comment.
- [ ] **Step 5: Commit.** `git commit -am "test(ownership-model): seed corpus + CI gate + historical re-catch"`

---

## Task 10: Documentation + spec annotations

**Files:**
- Create: `Tests/OwnershipModelTests/README.md`
- Modify: `SPECS.md` via `scripts/generate-specs.py` if any `@spec` markers are added.

- [ ] **Step 1:** Write `README.md` documenting: how to run the gate (`swift test --filter OwnershipModel`), how to run a wide random batch, how to interpret a shrunk failure, the fault model and its explicit exclusions (no packet loss/corruption), and how to add a new boundary (git polling, remote, zmx PTY) by reusing the world/oracle/shrinker skeleton.
- [ ] **Step 2:** If any oracle invariant warrants a `@spec` ID (e.g., a `TERM-` or new `OWN-` requirement for "followers never apply superseded ownership frames"), add it to the relevant test title and run `scripts/generate-specs.py`; otherwise note that the harness enforces existing specs and skip.
- [ ] **Step 3: Commit.** `git commit -am "docs(ownership-model): harness README + spec annotations"`

---

## Self-Review notes (author)

- **Spec coverage:** Scope→Tasks 4/6/7 (all three Swift transports), fidelity→Global Constraints (drive-real-code), search→Tasks 5/8 (randomized + shrink), engine→Tasks 2/5 (discrete-event queue + adapter-internal `.deferred`), fault model F1–F4→Tasks 4/5/7, oracle S1–S7/L1–L2→Tasks 3/4/6/7, footprint→Global Constraints + Task 0, success criteria→Task 9. F4 (duplicate delivery) is folded into the FakeNetwork as an optional path exercised by the random schedule; if a reviewer wants it explicit, add a dedicated assertion in Task 5.
- **Determinism risk:** Task 7 (iOS async) is the one place real concurrency fights determinism; it carries an explicit fallback (`.disabled` + report) rather than a wall-clock hack.
- **Branch-base risk:** Task 0 depends on a clean merge of `ongoing-vertical-sizing-problems`; coordinate with that agent before starting so the adapters aren't mid-rewrite.
