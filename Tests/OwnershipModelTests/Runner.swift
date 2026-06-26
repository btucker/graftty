import GrafttyProtocol
@testable import GrafttyKit

struct RunResult {
    let seed: UInt64
    let violations: [Violation]
    let transcript: [String]
    /// The web-control ops generated during the run, in application order.
    /// Populated by `runScenario`; empty for replay results.
    let capturedOps: [WebControlEnvelope]
    /// How many times the S5 monotonic guard correctly rejected a stale delivery
    /// during `runScenario`.  Non-zero proves that multi-path cross-channel
    /// reordering actually occurred and the guard is non-vacuously exercised.
    let rejectCount: Int
    /// How many times the L2 owner-release path was exercised during `runScenario`.
    let l2CheckCount: Int

    init(
        seed: UInt64,
        violations: [Violation],
        transcript: [String],
        capturedOps: [WebControlEnvelope] = [],
        rejectCount: Int = 0,
        l2CheckCount: Int = 0
    ) {
        self.seed = seed
        self.violations = violations
        self.transcript = transcript
        self.capturedOps = capturedOps
        self.rejectCount = rejectCount
        self.l2CheckCount = l2CheckCount
    }
}

// MARK: - Shared follower-delivery helpers

/// Apply a tagged snapshot to a follower and run the S5 monotonic-guard checks.
///
/// Returns `true` when the delivery was stale before `apply` was called — i.e.,
/// the guard would correctly reject it.  In multi-path mode, a `true` return
/// increments the reject counter that proves S5 is non-vacuously exercised.
private func applyToFollower(
    _ follower: WebFollowerView,
    tagged: TaggedSnapshot,
    target: DisplayClientID,
    oracle: inout Oracle
) -> Bool {
    let highestEpochBefore = follower.highestApplied
    let highestEmissionBefore = follower.highestAppliedEmission

    // Measure staleness BEFORE applying so the guard's decision is captured
    // regardless of whether the guard is bypassed.
    let isStale = tagged.emissionSeq < highestEmissionBefore
        || tagged.snapshot.epoch < highestEpochBefore

    follower.apply(tagged)

    // S5 by epoch regression: a lower-epoch snapshot was applied.
    if tagged.snapshot.epoch < highestEpochBefore,
       follower.highestApplied == tagged.snapshot.epoch {
        oracle.violations.append(.s5SupersededApplied(
            target: target,
            applied: tagged.snapshot.epoch,
            highest: highestEpochBefore
        ))
    }

    // S5 by ESN regression: a lower-emission snapshot was applied despite a
    // higher-emission one already having been applied (same-epoch grid reorder).
    if tagged.emissionSeq < highestEmissionBefore,
       follower.highestAppliedEmission == tagged.emissionSeq {
        oracle.violations.append(.s5SupersededApplied(
            target: target,
            applied: tagged.snapshot.epoch,
            highest: highestEpochBefore
        ))
    }

    return isStale
}

/// Check L1 convergence for one follower at quiescence.
///
/// Appends `.l1Divergence` to `oracle.violations` and a diagnostic line to
/// `transcript` when the follower's state does not match the store's.
private func checkL1(
    follower: WebFollowerView,
    storeSnapshot: DisplayOwnershipSnapshot,
    emissionSeq: UInt64,
    target: DisplayClientID,
    oracle: inout Oracle,
    transcript: inout [String]
) {
    guard follower.highestApplied != storeSnapshot.epoch
       || follower.highestAppliedEmission != emissionSeq
       || follower.grid != storeSnapshot.grid else { return }
    oracle.violations.append(.l1Divergence(target: target))
    transcript.append(
        "  L1 divergence \(target.rawValue): follower epoch=\(follower.highestApplied)"
        + " emit=\(follower.highestAppliedEmission)"
        + " vs store epoch=\(storeSnapshot.epoch) emit=\(emissionSeq)"
    )
}

// MARK: - Randomized scenario runner

/// Run one randomized model-check scenario using a real discrete-event loop.
///
/// - Parameters:
///   - seed: Seed for the deterministic RNG — same seed always produces the same scenario.
///   - opCount: Number of web-control ops (including owner-release ops) to apply.
///
/// Uses `EventQueue` to interleave op application and per-connection deliveries
/// non-deterministically.  Within each follower channel deliveries remain FIFO
/// (mirroring TCP reality); across channels and between ops vs. deliveries the
/// scheduler may interleave freely.
///
/// **Multi-path delivery (S5 non-vacuity):** each follower has TWO independent
/// channels.  On every `emit()`, the tagged snapshot is enqueued on BOTH channels
/// for EACH follower, and two `.advanceConnection` tokens are pushed per follower.
/// The event queue can advance channel-A of a follower ahead of channel-B, so the
/// follower may see emission-2 before emission-1 arrives on the other channel.
/// The follower's (epoch, ESN) guard rejects the stale emission-1.  `rejectCount`
/// in the returned `RunResult` proves the reject path is genuinely exercised and
/// S5 is non-vacuous (not just always-passing because reordering never happens).
///
/// **L2 path:** with 1-in-8 probability when a current owner exists, a
/// `releaseOwner` op is issued instead of a normal web op.  The L2 oracle check
/// verifies the store transitions to ownerless without silently promoting another
/// client.  `l2CheckCount` in the returned `RunResult` proves this path is reached.
///
/// Procedure:
/// 1. Seed `EventQueue` with a single `.nextOp` token.
/// 2. Pop events until the queue is empty:
///    - `.nextOp`: decide whether to release (L2 path) or generate a normal web
///      control op; apply it; run oracle checks; `emit()` the resulting tagged
///      snapshot; enqueue it on BOTH channels for EACH follower in `FakeNetwork`;
///      push one `.advanceConnection` token per channel; push the next `.nextOp`
///      if more ops remain.
///    - `.advanceConnection(channelID)`: dequeue the FIFO head for that channel
///      from `FakeNetwork` (preserving intra-channel order) and apply it to the
///      owning `WebFollowerView`, running S5 checks.  Returns `true` (stale) when
///      the delivery was a cross-channel reorder the guard correctly blocked.
/// 3. At quiescence, run an L1 convergence check for every follower.
func runScenario(seed: UInt64, opCount: Int) -> RunResult {
    var rng = DeterministicRNG(seed: seed)
    var world = MultiTransportWorld(session: "run-\(seed)")
    var transcript: [String] = []

    // Fixed set of web clients for this scenario.
    let clients = [
        DisplayClientID("web-a"),
        DisplayClientID("web-b"),
        DisplayClientID("web-c"),
    ]
    let availableGrids: [(UInt16, UInt16)] = [(80, 24), (120, 24), (220, 48)]

    // Two followers, each with TWO independent delivery channels.
    // Channels 0,1 serve follower 0; channels 2,3 serve follower 1.
    // Intra-channel deliveries are FIFO; across a follower's two channels the
    // event queue may interleave freely, allowing emission-N on channel-A to
    // reach the follower before emission-M (M < N) on channel-B arrives.
    // The follower's (epoch, ESN) guard rejects the stale M-emission; counting
    // these rejections proves the gate is non-vacuously exercised (FIX 1).
    let followerChannels: [(id: Int, channels: [Int])] = [
        (id: 0, channels: [0, 1]),
        (id: 1, channels: [2, 3]),
    ]
    let channelToFollower: [Int: Int] = Dictionary(
        uniqueKeysWithValues: followerChannels.flatMap { fc in
            fc.channels.map { ($0, fc.id) }
        }
    )
    let followers = [0: WebFollowerView(), 1: WebFollowerView()]

    // Mutable state tracked across iterations to generate sensible ops.
    var attachedClients: [DisplayClientID] = []
    var currentEpoch: UInt64 = 0
    var currentOwner: DisplayClientID? = nil
    var opsApplied = 0
    var capturedOps: [WebControlEnvelope] = []
    var rejectCount = 0   // stale cross-channel deliveries correctly rejected
    var l2CheckCount = 0  // times the L2 owner-release path was exercised

    // Seed the discrete-event queue with the first op token.
    var queue = EventQueue()
    queue.push(.nextOp)

    // Discrete-event loop: ops and deliveries interleave randomly via popNext.
    while let event = queue.popNext(using: &rng) {
        switch event {
        case .nextOp:
            // Decide whether to exercise the L2 owner-release path (1-in-8
            // probability when an owner exists) or generate a normal web op.
            let shouldRelease = currentOwner != nil && rng.int(in: 0..<8) == 0
            let (cols, rows) = rng.pick(availableGrids)

            var storeViolations: [Violation] = []
            let opDesc: String

            if shouldRelease, let ownerID = currentOwner {
                // L2 path: owner voluntarily releases ownership.  Not added to
                // capturedOps because the shrinker emits .disabled for L2 violations.
                let epochBefore = currentEpoch
                world.releaseOwner(ownerID: ownerID)
                storeViolations += world.oracle.checkAfterOwnerRelease(
                    store: world.store,
                    session: "run-\(seed)",
                    previousOwnerID: ownerID,
                    epochBeforeRelease: epochBefore
                )
                storeViolations += world.oracle.checkAfterEvent(
                    store: world.store,
                    session: "run-\(seed)",
                    lastResize: nil,
                    requestedEpoch: nil
                )
                l2CheckCount += 1
                opDesc = "release(\(ownerID.rawValue))"
            } else {
                // Normal web control op.
                let op = nextWebOp(
                    clients: clients,
                    attached: &attachedClients,
                    owner: currentOwner,
                    epoch: currentEpoch,
                    cols: cols, rows: rows,
                    using: &rng
                )
                capturedOps.append(op)
                world.webHandle(op)
                storeViolations += world.oracle.checkAfterEvent(
                    store: world.store,
                    session: "run-\(seed)",
                    lastResize: nil,
                    requestedEpoch: nil
                )
                opDesc = opLabel(op)
            }

            let tagged = world.emit()
            currentEpoch = tagged.snapshot.epoch
            currentOwner = tagged.snapshot.ownerClientID
            opsApplied += 1

            // Enqueue the tagged snapshot on BOTH channels for EACH follower and push
            // one .advanceConnection token per channel so deliveries can interleave
            // with future ops and across the two channels of the same follower.
            for fc in followerChannels {
                for channelID in fc.channels {
                    world.fakeNetwork.enqueue(
                        target: DisplayClientID("follower-\(fc.id)"),
                        snapshot: tagged.snapshot,
                        connection: channelID,
                        emissionSeq: tagged.emissionSeq
                    )
                    queue.push(.advanceConnection(channelID))
                }
            }

            var line = "#\(opsApplied - 1) op=\(opDesc)"
                + " → owner=\(tagged.snapshot.ownerClientID?.rawValue ?? "none")"
                + " epoch=\(tagged.snapshot.epoch) emit=\(tagged.emissionSeq)"
            if !storeViolations.isEmpty { line += " VIOLATIONS=\(storeViolations)" }
            transcript.append(line)

            if opsApplied < opCount { queue.push(.nextOp) }

        case .advanceConnection(let connID):
            // Dequeue the FIFO head for this channel from FakeNetwork —
            // NOT a random pick; intra-channel order is always preserved.
            guard let delivery = world.fakeNetwork.dequeue(connection: connID),
                  let followerID = channelToFollower[connID],
                  let follower = followers[followerID] else { break }

            let tagged = TaggedSnapshot(snapshot: delivery.snapshot, emissionSeq: delivery.emissionSeq)
            let target = DisplayClientID("follower-\(followerID)")

            // Apply to follower and run S5 checks.  Returns true when the delivery
            // was stale before apply — genuine cross-channel reordering the guard
            // correctly rejected.
            let wasStale = applyToFollower(follower, tagged: tagged, target: target, oracle: &world.oracle)
            if wasStale { rejectCount += 1 }

            transcript.append(
                "  deliver[conn=\(connID) follower=\(followerID)]"
                + " connSeq=\(delivery.connectionSeq)"
                + " emit=\(delivery.emissionSeq) epoch=\(delivery.snapshot.epoch)"
            )

        case .op, .deliver, .deferred:
            break  // not used by runScenario; reserved for other harness helpers
        }
    }

    // Quiescence: check L1 convergence for every follower.
    if world.emissionSeqCounter > 0 {
        let storeSnapshot = world.store.snapshot(sessionName: "run-\(seed)")
        for fc in followerChannels {
            guard let follower = followers[fc.id] else { continue }
            let target = DisplayClientID("follower-\(fc.id)")
            checkL1(
                follower: follower,
                storeSnapshot: storeSnapshot,
                emissionSeq: world.emissionSeqCounter,
                target: target,
                oracle: &world.oracle,
                transcript: &transcript
            )
        }
    }

    return RunResult(
        seed: seed,
        violations: world.oracle.violations,
        transcript: transcript,
        capturedOps: capturedOps,
        rejectCount: rejectCount,
        l2CheckCount: l2CheckCount
    )
}

// MARK: - Explicit-op replay

/// Replay an explicit list of web-control ops deterministically.
///
/// Unlike `runScenario`, deliveries to followers happen sequentially after each
/// op (connection 0 then connection 1) rather than via the random event-queue
/// interleaver.  This determinism is sufficient for the shrinker to check
/// whether a violation still occurs in a reduced op list.
func replayWebOps(ops: [WebControlEnvelope], session: String) -> RunResult {
    var world = MultiTransportWorld(session: session)
    var transcript: [String] = []

    // One channel per follower for deterministic sequential replay.
    let followerConnectionIDs = [0, 1]
    let followers: [Int: WebFollowerView] = Dictionary(
        uniqueKeysWithValues: followerConnectionIDs.map { ($0, WebFollowerView()) }
    )

    for (index, op) in ops.enumerated() {
        world.webHandle(op)

        let storeViolations = world.oracle.checkAfterEvent(
            store: world.store,
            session: session,
            lastResize: nil,
            requestedEpoch: nil
        )

        let tagged = world.emit()

        // Enqueue this snapshot on every follower connection.
        for connID in followerConnectionIDs {
            world.fakeNetwork.enqueue(
                target: DisplayClientID("follower-\(connID)"),
                snapshot: tagged.snapshot,
                connection: connID,
                emissionSeq: tagged.emissionSeq
            )
        }

        // Drain each connection in FIFO order (deterministic, no interleaving).
        for connID in followerConnectionIDs {
            while let delivery = world.fakeNetwork.dequeue(connection: connID) {
                guard let follower = followers[connID] else { break }
                let deliveredTagged = TaggedSnapshot(
                    snapshot: delivery.snapshot,
                    emissionSeq: delivery.emissionSeq
                )
                let target = DisplayClientID("follower-\(connID)")
                _ = applyToFollower(follower, tagged: deliveredTagged, target: target, oracle: &world.oracle)
            }
        }

        var line = "#\(index) op=\(opLabel(op))"
            + " → owner=\(tagged.snapshot.ownerClientID?.rawValue ?? "none")"
            + " epoch=\(tagged.snapshot.epoch) emit=\(tagged.emissionSeq)"
        if !storeViolations.isEmpty { line += " VIOLATIONS=\(storeViolations)" }
        transcript.append(line)
    }

    // Quiescence: check L1 convergence for every follower connection.
    if world.emissionSeqCounter > 0 {
        let storeSnapshot = world.store.snapshot(sessionName: session)
        for connID in followerConnectionIDs {
            guard let follower = followers[connID] else { continue }
            let target = DisplayClientID("follower-\(connID)")
            checkL1(
                follower: follower,
                storeSnapshot: storeSnapshot,
                emissionSeq: world.emissionSeqCounter,
                target: target,
                oracle: &world.oracle,
                transcript: &transcript
            )
        }
    }

    return RunResult(seed: 0, violations: world.oracle.violations, transcript: transcript)
}

// MARK: - Op generation

private func nextWebOp(
    clients: [DisplayClientID],
    attached: inout [DisplayClientID],
    owner: DisplayClientID?,
    epoch: UInt64,
    cols: UInt16,
    rows: UInt16,
    using rng: inout DeterministicRNG
) -> WebControlEnvelope {
    // Always attach at least one client first.
    if attached.isEmpty {
        let client = rng.pick(clients)
        attached.append(client)
        return .hello(clientID: client, kind: .web, role: .interactive, visible: true, cols: cols, rows: rows)
    }

    let client = rng.pick(attached)

    switch rng.int(in: 0..<5) {
    case 0:
        // hello: attach/re-hello a client (possibly a new one).
        let newClient = rng.pick(clients)
        if !attached.contains(newClient) { attached.append(newClient) }
        return .hello(clientID: newClient, kind: .web, role: .interactive, visible: rng.int(in: 0..<2) == 0, cols: cols, rows: rows)
    case 1:
        return .takeControl(clientID: client, kind: .web, cols: cols, rows: rows)
    case 2:
        // ownerResize: requires a current owner; fall back to takeControl.
        if let ownerID = owner {
            // Occasionally send a stale epoch (0) to exercise the store's rejection gate.
            let sendEpoch = rng.int(in: 0..<4) == 0 ? 0 : epoch
            return .ownerResize(clientID: ownerID, epoch: sendEpoch, cols: cols, rows: rows)
        }
        return .takeControl(clientID: client, kind: .web, cols: cols, rows: rows)
    case 3:
        return .takeControl(clientID: client, kind: .web, cols: cols, rows: rows)
    default:
        // ownerResize again (higher weight — this is the ESN-relevant path).
        if let ownerID = owner {
            return .ownerResize(clientID: ownerID, epoch: epoch, cols: cols, rows: rows)
        }
        return .hello(clientID: client, kind: .web, role: .interactive, visible: true, cols: cols, rows: rows)
    }
}

private func opLabel(_ op: WebControlEnvelope) -> String {
    switch op {
    case .hello(let id, _, _, _, let c, let r): return "hello(\(id.rawValue),\(c)x\(r))"
    case .takeControl(let id, _, let c, let r): return "takeControl(\(id.rawValue),\(c)x\(r))"
    case .ownerResize(let id, let e, let c, let r): return "ownerResize(\(id.rawValue),epoch=\(e),\(c)x\(r))"
    default: return "\(op)"
    }
}
