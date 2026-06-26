import GrafttyProtocol
@testable import GrafttyKit

struct RunResult {
    let seed: UInt64
    let violations: [Violation]
    let transcript: [String]
}

/// Run one randomized model-check scenario.
///
/// - Parameters:
///   - seed: Seed for the deterministic RNG — same seed always produces the same scenario.
///   - opCount: Number of web-control ops to generate and apply.
///
/// Procedure:
/// 1. Apply `opCount` ops (hello / takeControl / ownerResize) via `webHandle`.
/// 2. After each op, `emit()` and enqueue the tagged snapshot as a network
///    delivery in `world.fakeNetwork`.
/// 3. After all ops are applied, drain `fakeNetwork` in random order
///    (simulating network reordering across the one delivery connection).
/// 4. Route each delivery through `deliverToWebFollower` so the S5 oracle check runs.
/// 5. Call `checkL1()` at quiescence and collect all violations.
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

    /// Mutable state tracked across iterations to generate sensible ops.
    var attachedClients: [DisplayClientID] = []
    var currentEpoch: UInt64 = 0
    var currentOwner: DisplayClientID? = nil

    // -- Phase 1: generate and apply ops, emit and enqueue deliveries --

    for step in 0..<opCount {
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

        // S1-S4 store invariants checked after every op.
        let storeViolations = world.oracle.checkAfterEvent(
            store: world.store,
            session: "run-\(seed)",
            lastResize: nil,
            requestedEpoch: nil
        )

        let tagged = world.emit()
        currentEpoch = tagged.snapshot.epoch
        currentOwner = tagged.snapshot.ownerClientID

        // Enqueue on connection 0 (single-connection scenario; FakeNetwork
        // preserves FIFO within a connection but the drain picks randomly, so
        // deliveries accumulate and are drained in random order after all ops).
        world.fakeNetwork.enqueue(
            target: DisplayClientID("web-a"),
            snapshot: tagged.snapshot,
            connection: 0,
            emissionSeq: tagged.emissionSeq
        )

        var line = "#\(step) op=\(opLabel(op)) → owner=\(tagged.snapshot.ownerClientID?.rawValue ?? "none") epoch=\(tagged.snapshot.epoch) emit=\(tagged.emissionSeq)"
        if !storeViolations.isEmpty { line += " VIOLATIONS=\(storeViolations)" }
        transcript.append(line)
    }

    // -- Phase 2: drain deliveries in random order --

    var deliveryIndex = 0
    while let event = world.fakeNetwork.popNext(using: &rng) {
        guard case .deliver(let delivery) = event else { continue }
        let tagged = TaggedSnapshot(snapshot: delivery.snapshot, emissionSeq: delivery.emissionSeq)
        world.deliverToWebFollower(tagged)
        transcript.append("  deliver[\(deliveryIndex)] connSeq=\(delivery.connectionSeq) emit=\(delivery.emissionSeq) epoch=\(delivery.snapshot.epoch)")
        deliveryIndex += 1
    }

    // -- Phase 3: quiescence checks --

    world.checkL1()
    if let v = world.oracle.violations.last, case .l1Divergence = v {
        transcript.append("  L1 divergence: follower epoch=\(world.webFollower.highestApplied) emit=\(world.webFollower.highestAppliedEmission) vs store epoch=\(world.store.snapshot(sessionName: "run-\(seed)").epoch) emit=\(world.emissionSeqCounter)")
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
