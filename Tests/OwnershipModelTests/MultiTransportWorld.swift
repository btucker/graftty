import Foundation
import GhosttyKit
import GrafttyProtocol
@testable import Graftty
@testable import GrafttyKit
#if canImport(UIKit)
@testable import GrafttyMobileKit
#endif

/// Extends `StoreWorld`-style ownership driving with the real
/// `WebSocketBridgeCoordinator` + `WebDisplayOwnershipBroadcaster` so the
/// harness can exercise the full web-server path, not just the bare store.
///
/// The web follower (`webFollower`) is a model standing in for the TypeScript
/// client; `deliverToWebFollower` routes a tagged snapshot through it and runs
/// the S5 monotonic-guard checks (epoch regression and ESN regression).  Call
/// `checkL1` at quiescence to verify the follower converged to the store's
/// authoritative epoch, emission, and grid.
struct MultiTransportWorld {
    let session: String
    let store: SessionDisplayOwnershipStore
    var oracle: Oracle
    private(set) var webFollower: WebFollowerView
    var fakeNetwork: FakeNetwork

    private let coordinator: WebSocketBridgeCoordinator
    private let broadcaster: WebDisplayOwnershipBroadcaster

    /// The browser-side protocol client ID from the most-recent `.hello` frame.
    /// Used as the `target` field in S5/L1 violations.
    private var webClientID: DisplayClientID?

    /// Harness-side monotonic emission counter.  Incremented once per `emit()`
    /// call; NOT a store field — the store's `ownerResize` updates the grid
    /// without bumping `epoch`, so epoch alone cannot version grids.
    private(set) var emissionSeqCounter: UInt64 = 0

    // MARK: - Mac backend (Task 6)

    /// Wrapper that calls `releaseReceiveUserdataAfterSurfaceFree()` on
    /// dealloc, ensuring the backend's lifecycle is closed cleanly even
    /// though `MultiTransportWorld` is a value type without a deinit.
    private var macBackendBox: MacBackendBox?
    private var macSession: FakeZmxSession?
    private var macCoalescer: MacResizeCoalescer?
    private var macViolations: PendingViolations?

    /// Last (cols, rows) pair that actually reached `FakeZmxSession.resize`.
    /// Nil when no PTY resize has been attempted (e.g. `markLayoutSettled`
    /// fired while the Mac client was a follower and the ownership gate
    /// blocked the flush).
    private(set) var macPTYLastSize: (UInt16, UInt16)?

    // MARK: - iOS adapter (Task 7)

#if canImport(UIKit)
    /// Wraps the `@MainActor`-isolated `SessionClient` in an unchecked-
    /// Sendable reference so the struct (which is not actor-isolated) can
    /// store it.  Access only from `@MainActor` contexts.
    private var iosClientBox: IOSClientBox?
    private var iosFakeWS: FakeWebSocketClient?
    private var iosClientIDValue: DisplayClientID?
    /// Highest epoch from ownership frames enqueued via `enqueueIOSIncoming`.
    /// Used by `pumpIOS()` for the post-pump S5 check.
    private var iosHighestEnqueuedEpoch: UInt64 = 0
#endif

    init(session: String) {
        let store = SessionDisplayOwnershipStore()
        let broadcaster = WebDisplayOwnershipBroadcaster()
        let coordinator = WebSocketBridgeCoordinator(
            sessionName: session,
            clientID: DisplayClientID("server-web-harness"),
            defaultKind: .web,
            ownershipStore: store,
            broadcaster: broadcaster,
            sendText: { _ in },
            resize: { _, _ in },
            write: { _ in }
        )
        self.session = session
        self.store = store
        self.oracle = Oracle()
        self.webFollower = WebFollowerView()
        self.fakeNetwork = FakeNetwork()
        self.broadcaster = broadcaster
        self.coordinator = coordinator
        self.webClientID = nil
    }

    /// Forward a control envelope to the real coordinator.
    /// Records the browser-side client ID from `.hello` frames so violations
    /// can be attributed to the right target.
    mutating func webHandle(_ envelope: WebControlEnvelope) {
        if case let .hello(clientID, _, _, _, _, _) = envelope {
            webClientID = clientID
        }
        coordinator.handleControl(envelope)
    }

    /// Snapshot the store's current state and tag it with the next monotonic
    /// emission sequence number.  Call once after each `webHandle` that may
    /// have mutated the store.
    mutating func emit() -> TaggedSnapshot {
        emissionSeqCounter += 1
        let snapshot = store.snapshot(sessionName: session)
        return TaggedSnapshot(snapshot: snapshot, emissionSeq: emissionSeqCounter)
    }

    /// Deliver a tagged snapshot to the web follower and run the S5 checks.
    ///
    /// S5 fires when the follower actually applies a delivery that is
    /// superseded — either by epoch regression or by ESN regression (a
    /// same-epoch stale grid delivered out of emission order).  With the
    /// guards in effect both cases are silently ignored, so S5 never fires in
    /// normal (non-bypass) operation.
    mutating func deliverToWebFollower(_ tagged: TaggedSnapshot) {
        let highestEpochBefore = webFollower.highestApplied
        let highestEmissionBefore = webFollower.highestAppliedEmission
        webFollower.apply(tagged)
        let target = webClientID ?? DisplayClientID("unknown")

        // S5 by epoch regression: a lower-epoch snapshot was applied (bypass was on
        // or the guard was absent).
        if tagged.snapshot.epoch < highestEpochBefore,
           webFollower.highestApplied == tagged.snapshot.epoch {
            oracle.violations.append(.s5SupersededApplied(
                target: target,
                applied: tagged.snapshot.epoch,
                highest: highestEpochBefore
            ))
        }

        // S5 by ESN regression: a lower-emission snapshot was applied despite a
        // higher-emission one having been applied already.  This catches
        // same-epoch grid reordering (e.g. ownerResize delivered out of order).
        if tagged.emissionSeq < highestEmissionBefore,
           webFollower.highestAppliedEmission == tagged.emissionSeq {
            oracle.violations.append(.s5SupersededApplied(
                target: target,
                applied: tagged.snapshot.epoch,
                highest: highestEpochBefore
            ))
        }
    }

    /// Check L1 convergence at quiescence.
    ///
    /// The follower's `highestApplied` must equal the store's current epoch,
    /// `highestAppliedEmission` must equal the latest emission this world
    /// produced, and the follower's grid must match the store's grid.
    mutating func checkL1() {
        guard emissionSeqCounter > 0, let target = webClientID else { return }
        let storeSnapshot = store.snapshot(sessionName: session)
        let epochOK = webFollower.highestApplied == storeSnapshot.epoch
        let emissionOK = webFollower.highestAppliedEmission == emissionSeqCounter
        let gridOK = webFollower.grid == storeSnapshot.grid
        if !epochOK || !emissionOK || !gridOK {
            oracle.violations.append(.l1Divergence(target: target))
        }
    }

    // MARK: - Mac adapter

    /// Wire the real `HostManagedZmxBackend` into the harness.
    ///
    /// Attaches a Mac client with the given `id` to the shared ownership store
    /// and starts it (without calling `markLayoutSettled`), so the backend is
    /// in the running state but has not yet attempted a PTY resize.
    ///
    /// The injected `FakeZmxSession` records every resize/write and fires
    /// Oracle S6/S7 checks at the moment of the call.  Call `quiesce()` to
    /// settle the layout and flush any pending violations into `oracle`.
    mutating func attachMac(id: DisplayClientID, grid: DisplayGrid) throws {
        let session = FakeZmxSession()
        let coalescer = MacResizeCoalescer()
        let violations = PendingViolations()

        // Capture by value/reference for use inside closures; `store` is a
        // class reference so copying the property copies the pointer, not the store.
        let storeRef = store
        let sessionName = self.session

        session.onResize = { cols, rows in
            let snapshot = storeRef.snapshot(sessionName: sessionName)
            if snapshot.ownerClientID != id {
                violations.append(.s6NonOwnerResizedPTY(id))
            }
        }
        session.onWrite = { _ in
            let snapshot = storeRef.snapshot(sessionName: sessionName)
            if snapshot.ownerClientID != id {
                violations.append(.s7NonOwnerInput(id))
            }
        }

        let ownership = HostManagedZmxOwnership(
            store: storeRef,
            sessionName: sessionName,
            clientID: id,
            kind: .mac
        )
        let backend = HostManagedZmxBackend(
            spawnConfiguration: ZmxSpawnConfiguration(
                sessionName: sessionName,
                argv: ["/tmp/zmx", "attach", sessionName],
                env: ["ZMX_DIR": "/tmp/zmx-dir", "SHELL": "/bin/zsh"],
                workingDirectory: URL(fileURLWithPath: "/tmp/worktree", isDirectory: true)
            ),
            ownership: ownership,
            scheduleCoalescedResize: { delay, fire in coalescer.schedule(delay, fire) },
            sessionFactory: { _, _, _ in session }
        )
        backend.bindSurfaceSync(
            currentGridSize: { (grid.cols, grid.rows) },
            requestRefresh: {}
        )
        // Start the backend (attaches to ownership store + spawns session)
        // but do NOT call markLayoutSettled — that happens in quiesce() so
        // the ownership gate is evaluated after all takeover events have run.
        try backend.start(surface: Self.fakeSurface())

        macBackendBox = MacBackendBox(backend)
        macSession = session
        macCoalescer = coalescer
        macViolations = violations
    }

    /// Settle the Mac backend layout and drain all pending S6/S7 violations
    /// into `oracle`.
    ///
    /// Calling sequence:
    ///   1. Fire any coalesced resizes already queued in the Mac backend.
    ///   2. Call `markLayoutSettled()` — triggers the ownership-gated PTY
    ///      flush; if the Mac client is a follower the flush is blocked and no
    ///      resize reaches the PTY.
    ///   3. Fire any trailing coalesced resizes the settle may have opened.
    ///   4. Record the last PTY-attempted size (nil when all flushes were
    ///      blocked).
    ///   5. Merge Mac S6/S7 violations collected by the session callbacks into
    ///      `oracle.violations`.
    mutating func quiesce() {
        macCoalescer?.fireAll()
        macBackendBox?.markLayoutSettled()
        macCoalescer?.fireAll()
        if let last = macSession?.resizes.last {
            macPTYLastSize = last
        }
        oracle.violations.append(contentsOf: macViolations?.drain() ?? [])
    }

    // MARK: - Fault-injection seams (teeth tests)

    /// Directly invoke the Mac `FakeZmxSession.resize`, bypassing the real
    /// backend's ownership gate.  Used to prove the S6 oracle has teeth:
    /// the `onResize` hook checks the store and records a violation when
    /// the Mac is not the current owner.  Violations are drained into
    /// `oracle.violations` immediately so callers can assert right after
    /// this call.
    mutating func injectMacPTYResize(cols: UInt16, rows: UInt16) {
        try? macSession?.resize(cols: cols, rows: rows)
        oracle.violations.append(contentsOf: macViolations?.drain() ?? [])
    }

    /// Directly invoke the Mac `FakeZmxSession.write`, bypassing the real
    /// backend's ownership gate.  Used to prove the S7 oracle has teeth:
    /// the `onWrite` hook checks the store and records a violation when
    /// the Mac is not the current owner.  Violations are drained into
    /// `oracle.violations` immediately so callers can assert right after
    /// this call.
    mutating func injectMacPTYWrite(_ data: Data) {
        try? macSession?.write(data)
        oracle.violations.append(contentsOf: macViolations?.drain() ?? [])
    }

    private static func fakeSurface() -> ghostty_surface_t {
        UnsafeMutableRawPointer(bitPattern: 0x1234)!
    }

    // MARK: - iOS adapter methods (Task 7)

#if canImport(UIKit)
    /// Wire the real `SessionClient` into the harness as an iOS follower.
    ///
    /// Constructs the client with `FakeWebSocketClient` (queue-based, no network)
    /// and `ManualClock` (no wall-clock), starts it, then waits for the real
    /// receive loop to park in `receive()`.  The client's receive loop is real
    /// Swift async running on `@MainActor`; determinism comes from the fake WS's
    /// continuation-based drain signal, not from `Task.sleep`.
    @MainActor
    mutating func attachIOS(id: DisplayClientID) async {
        let fakeWS = FakeWebSocketClient()
        let clock = ManualClock()
        let box = IOSClientBox()
        let client = SessionClient(
            sessionName: session,
            webSocketFactory: { fakeWS },
            clock: clock
        )
        box.client = client
        iosClientBox = box
        iosFakeWS = fakeWS
        iosClientIDValue = id
        client.start()
        // Wait for the receive loop to set up and park in receive() with
        // an empty queue — this is the quiescent initial state.
        await fakeWS.awaitDrained()
    }

    /// Build a text `WebSocketFrame` carrying an ownership snapshot where
    /// a fixed harness-owned web client holds the display at the given epoch
    /// and column count.  Delivering this frame to the iOS client puts it into
    /// follower state (the ownerClientID is never the iOS client's own UUID).
    func makeOwnershipFrame(epoch: UInt64, cols: UInt16) -> WebSocketFrame {
        // swiftlint:disable:next force_try
        let snapshot = try! DisplayOwnershipSnapshot(
            sessionName: session,
            ownerClientID: DisplayClientID("harness-web-owner"),
            ownerKind: .web,
            // swiftlint:disable:next force_try
            grid: try! DisplayGrid(cols: cols, rows: 24),
            epoch: epoch
        )
        return .text(WebControlEnvelope.ownership(snapshot).encoded())
    }

    /// Enqueue an incoming frame for the iOS client's receive loop.
    ///
    /// Tracks the highest epoch from ownership frames for the post-pump S5
    /// check.  Frames are processed in FIFO order by the real receive loop.
    mutating func enqueueIOSIncoming(_ frame: WebSocketFrame) {
        if case .text(let text) = frame,
           let envelope = try? WebControlEnvelope.parse(Data(text.utf8)),
           case .ownership(let snapshot) = envelope {
            iosHighestEnqueuedEpoch = max(iosHighestEnqueuedEpoch, snapshot.epoch)
        }
        iosFakeWS?.enqueueIncoming(frame)
    }

    /// Pump the iOS receive loop: wait until all currently-queued frames
    /// have been processed and the loop has re-parked in `receive()`.
    ///
    /// After returning, runs the S5 check: if the client's applied epoch is
    /// below the highest epoch that was enqueued, a stale snapshot was applied
    /// and an `.s5SupersededApplied` violation is recorded in `oracle`.
    @MainActor
    mutating func pumpIOS() async {
        guard let fakeWS = iosFakeWS else { return }
        await fakeWS.awaitDrained()
        // S5 post-pump check: convergence to the highest enqueued epoch.
        // If the client applied a stale snapshot its current epoch is lower.
        if let client = iosClientBox?.client {
            let applied = client.ownershipSnapshot?.epoch ?? 0
            if applied < iosHighestEnqueuedEpoch {
                oracle.violations.append(.s5SupersededApplied(
                    target: iosClientIDValue ?? DisplayClientID("unknown-ios"),
                    applied: applied,
                    highest: iosHighestEnqueuedEpoch
                ))
            }
        }
    }

    /// The epoch of the ownership snapshot currently applied by the iOS client,
    /// or 0 if no snapshot has been applied yet.
    @MainActor
    var iosAppliedEpoch: UInt64 {
        iosClientBox?.client?.ownershipSnapshot?.epoch ?? 0
    }
#endif
}

// MARK: - Private harness helpers

/// Wraps `HostManagedZmxBackend` and calls
/// `releaseReceiveUserdataAfterSurfaceFree()` on dealloc so the backend
/// deinit does not print the "userdata was not released" warning to stderr.
private final class MacBackendBox {
    private let backend: HostManagedZmxBackend

    init(_ backend: HostManagedZmxBackend) {
        self.backend = backend
    }

    func markLayoutSettled() {
        backend.markLayoutSettled()
    }

    deinit {
        backend.releaseReceiveUserdataAfterSurfaceFree()
    }
}

/// Thread-safe violation mailbox: `FakeZmxSession` callbacks append to this;
/// `quiesce()` drains it into the oracle.
private final class PendingViolations {
    private let lock = NSLock()
    private var _violations: [Violation] = []

    func append(_ v: Violation) {
        lock.lock()
        _violations.append(v)
        lock.unlock()
    }

    func drain() -> [Violation] {
        lock.lock()
        defer { lock.unlock() }
        let v = _violations
        _violations = []
        return v
    }
}

/// Deterministic resize-coalescing scheduler: records each scheduled trailing
/// fire; `quiesce()` pumps them via `fireAll()`.
private final class MacResizeCoalescer {
    private final class Entry {
        var cancelled = false
        let fire: () -> Void
        init(_ fire: @escaping () -> Void) { self.fire = fire }
    }

    private let lock = NSLock()
    private var pending: [Entry] = []

    func schedule(_ delay: TimeInterval, _ fire: @escaping () -> Void) -> (() -> Void) {
        // delay is ignored: the test harness collapses all delays to zero for
        // determinism; fireAll() pumps entries synchronously.
        _ = delay
        let entry = Entry(fire)
        lock.lock()
        pending.append(entry)
        lock.unlock()
        return { [weak entry] in entry?.cancelled = true }
    }

    func fireAll() {
        while true {
            lock.lock()
            guard !pending.isEmpty else { lock.unlock(); return }
            let entry = pending.removeFirst()
            lock.unlock()
            if !entry.cancelled { entry.fire() }
        }
    }
}

#if canImport(UIKit)
/// Wraps a `@MainActor`-isolated `SessionClient` in an `@unchecked Sendable`
/// reference so the non-isolated `MultiTransportWorld` struct can store it.
/// Access only from `@MainActor` contexts (i.e. `IOSSeamTests`).
private final class IOSClientBox: @unchecked Sendable {
    nonisolated(unsafe) var client: SessionClient?
    init() {}
}
#endif
