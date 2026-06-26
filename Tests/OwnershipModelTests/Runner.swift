import GrafttyProtocol
@testable import GrafttyKit

struct RunResult {
    let seed: UInt64
    let violations: [Violation]
    let transcript: [String]
}

/// Run one randomized model-check scenario using a real discrete-event loop.
///
/// - Parameters:
///   - seed: Seed for the deterministic RNG — same seed always produces the same scenario.
///   - opCount: Number of web-control ops to generate and apply.
///
/// Uses `EventQueue` to interleave op application and per-connection deliveries
/// non-deterministically.  Within each follower connection deliveries remain FIFO
/// (mirroring TCP reality); across connections and between ops vs. deliveries the
/// scheduler may interleave freely.
///
/// Procedure:
/// 1. Seed `EventQueue` with a single `.nextOp` token.
/// 2. Pop events until the queue is empty:
///    - `.nextOp`: generate and apply the next web control op, run the S1–S4
///      oracle, `emit()` the resulting tagged snapshot, enqueue it on every
///      follower connection in `FakeNetwork`, push one `.advanceConnection`
///      token per connection into the queue, and push the next `.nextOp` if
///      more ops remain.
///    - `.advanceConnection(connID)`: dequeue the FIFO head for that connection
///      from `FakeNetwork` (preserving intra-connection order) and apply it to
///      the matching `WebFollowerView`, running S5 checks.
/// 3. At quiescence, run an L1 convergence check for every follower connection.
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

    // Two follower connections — each simulates a distinct browser observing the
    // session stream.  Per-connection FIFO is maintained by FakeNetwork; across
    // connections the event queue interleaves freely.
    let followerConnectionIDs = [0, 1]
    let followers: [Int: WebFollowerView] = Dictionary(
        uniqueKeysWithValues: followerConnectionIDs.map { ($0, WebFollowerView()) }
    )

    // Mutable state tracked across iterations to generate sensible ops.
    var attachedClients: [DisplayClientID] = []
    var currentEpoch: UInt64 = 0
    var currentOwner: DisplayClientID? = nil
    var opsApplied = 0

    // Seed the discrete-event queue with the first op token.
    var queue = EventQueue()
    queue.push(.nextOp)

    // Discrete-event loop: ops and deliveries interleave randomly via popNext.
    while let event = queue.popNext(using: &rng) {
        switch event {
        case .nextOp:
            // Generate and apply the next web control op.
            let (cols, rows) = rng.pick(availableGrids)
            let op = nextWebOp(
                clients: clients,
                attached: &attachedClients,
                owner: currentOwner,
                epoch: currentEpoch,
                cols: cols, rows: rows,
                using: &rng
            )

            world.webHandle(op)

            // S1–S4 store invariants checked after every op.
            let storeViolations = world.oracle.checkAfterEvent(
                store: world.store,
                session: "run-\(seed)",
                lastResize: nil,
                requestedEpoch: nil
            )

            let tagged = world.emit()
            currentEpoch = tagged.snapshot.epoch
            currentOwner = tagged.snapshot.ownerClientID
            opsApplied += 1

            // Enqueue the tagged snapshot on every follower connection and push
            // a corresponding .advanceConnection token so deliveries can
            // interleave with future ops and across connections.
            for connID in followerConnectionIDs {
                world.fakeNetwork.enqueue(
                    target: DisplayClientID("follower-\(connID)"),
                    snapshot: tagged.snapshot,
                    connection: connID,
                    emissionSeq: tagged.emissionSeq
                )
                queue.push(.advanceConnection(connID))
            }

            var line = "#\(opsApplied - 1) op=\(opLabel(op)) → owner=\(tagged.snapshot.ownerClientID?.rawValue ?? "none") epoch=\(tagged.snapshot.epoch) emit=\(tagged.emissionSeq)"
            if !storeViolations.isEmpty { line += " VIOLATIONS=\(storeViolations)" }
            transcript.append(line)

            // Push the next op token if more ops remain.
            if opsApplied < opCount {
                queue.push(.nextOp)
            }

        case .advanceConnection(let connID):
            // Dequeue the FIFO head for this connection from FakeNetwork —
            // NOT a random pick; intra-connection order is always preserved.
            guard let delivery = world.fakeNetwork.dequeue(connection: connID),
                  let follower = followers[connID] else { break }

            let tagged = TaggedSnapshot(snapshot: delivery.snapshot, emissionSeq: delivery.emissionSeq)
            let highestEpochBefore = follower.highestApplied
            let highestEmissionBefore = follower.highestAppliedEmission
            follower.apply(tagged)
            let target = DisplayClientID("follower-\(connID)")

            // S5 by epoch regression: a lower-epoch snapshot was applied.
            if tagged.snapshot.epoch < highestEpochBefore,
               follower.highestApplied == tagged.snapshot.epoch {
                world.oracle.violations.append(.s5SupersededApplied(
                    target: target, applied: tagged.snapshot.epoch, highest: highestEpochBefore
                ))
            }

            // S5 by ESN regression: a lower-emission snapshot was applied despite
            // a higher-emission one having been applied already (same-epoch reorder).
            if tagged.emissionSeq < highestEmissionBefore,
               follower.highestAppliedEmission == tagged.emissionSeq {
                world.oracle.violations.append(.s5SupersededApplied(
                    target: target, applied: tagged.snapshot.epoch, highest: highestEpochBefore
                ))
            }

            transcript.append("  deliver[conn=\(connID)] connSeq=\(delivery.connectionSeq) emit=\(delivery.emissionSeq) epoch=\(delivery.snapshot.epoch)")

        case .op, .deliver, .deferred:
            break  // not used by runScenario; reserved for other harness helpers
        }
    }

    // Quiescence: check L1 convergence for every follower connection.
    if world.emissionSeqCounter > 0 {
        let storeSnapshot = world.store.snapshot(sessionName: "run-\(seed)")
        for connID in followerConnectionIDs {
            guard let follower = followers[connID] else { continue }
            let target = DisplayClientID("follower-\(connID)")
            let epochOK = follower.highestApplied == storeSnapshot.epoch
            let emissionOK = follower.highestAppliedEmission == world.emissionSeqCounter
            let gridOK = follower.grid == storeSnapshot.grid

            if !epochOK || !emissionOK || !gridOK {
                world.oracle.violations.append(.l1Divergence(target: target))
                transcript.append("  L1 divergence conn=\(connID): follower epoch=\(follower.highestApplied) emit=\(follower.highestAppliedEmission) vs store epoch=\(storeSnapshot.epoch) emit=\(world.emissionSeqCounter)")
            }
        }
    }

    return RunResult(seed: seed, violations: world.oracle.violations, transcript: transcript)
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
