import GrafttyProtocol
@testable import GrafttyKit

// MARK: - Public types

/// The result of a successful shrink: a minimal op list that still reproduces
/// the same `Violation`, plus a regression-test emitter.
struct ShrunkFailure {
    /// Minimal op sequence that reproduces `violation`.
    let ops: [Op]
    /// Delivery-schedule indices (placeholder; captures interleave order for
    /// the web-op replay path where schedule choices are available).
    let schedule: [Int]
    /// The first violation that this trace reproduces.
    let violation: Violation
    /// Human-readable event log for the minimal trace.
    let transcript: [String]

    /// Emit a `@Test` that replays the minimal op list through `StoreWorld`
    /// and asserts that at least one violation is found.  Compiles against
    /// the `OwnershipModelTests` target without modification.
    func asRegressionTest() -> String {
        let indent = "    "
        var lines: [String] = []
        lines.append("@Test func regression_\(violationLabel(violation))() {")
        lines.append("\(indent)let ops: [Op] = [")
        for op in ops {
            lines.append("\(indent)\(indent)\(opSourceLiteral(op)),")
        }
        lines.append("\(indent)]")
        lines.append("\(indent)var world = StoreWorld(session: \"regression\")")
        lines.append("\(indent)var oracle = Oracle()")
        lines.append("\(indent)for op in ops {")
        lines.append("\(indent)\(indent)let result = world.apply(op)")
        lines.append("\(indent)\(indent)oracle.checkAfterEvent(store: world.store, session: \"regression\",")
        lines.append("\(indent)\(indent)    lastResize: result.resize, requestedEpoch: result.requestedEpoch)")
        lines.append("\(indent)}")
        lines.append("\(indent)#expect(!oracle.violations.isEmpty)")
        lines.append("}")
        return lines.joined(separator: "\n")
    }
}

// MARK: - Public API

/// Delta-debug a failing scenario (real oracle) down to a minimal reproducing
/// trace.
///
/// Runs `runScenario(seed:opCount:)` to obtain the initial violation list.
/// Returns `nil` when there are no violations.  Otherwise, captures the
/// generated op sequence and greedily removes ops (preserving the sequential
/// delivery order in `replayWebOps`) until no further reduction reproduces the
/// same first `Violation`.
func shrink(seed: UInt64, opCount: Int) -> ShrunkFailure? {
    let initial = runScenario(seed: seed, opCount: opCount)
    guard let targetViolation = initial.violations.first else { return nil }

    let capturedOps = initial.capturedOps
    guard !capturedOps.isEmpty else { return nil }

    // Predicate: subset still reproduces the same first violation via sequential replay.
    let webPredicate: ([WebControlEnvelope]) -> Bool = { ops in
        guard !ops.isEmpty else { return false }
        return replayWebOps(ops: ops, session: "shrink-\(seed)").violations.first == targetViolation
    }

    // Fall back to the full trace if sequential replay can't reproduce the
    // violation (e.g. it depends on random delivery interleaving).
    let opsToShrink: [WebControlEnvelope]
    if webPredicate(capturedOps) {
        opsToShrink = greedyReduceWebOps(ops: capturedOps, predicate: webPredicate)
    } else {
        opsToShrink = capturedOps
    }

    let minimalOps = opsToShrink.map { webEnvelopeToOp($0) }
    let finalResult = replayWebOps(ops: opsToShrink, session: "shrink-final-\(seed)")

    return ShrunkFailure(
        ops: minimalOps,
        schedule: Array(0..<minimalOps.count),
        violation: targetViolation,
        transcript: finalResult.transcript
    )
}

/// Test seam: generate ops from `seed` using `StoreWorld` (single client c7),
/// then delta-debug the op list using `predicate` as the "failing" criterion
/// rather than a real oracle violation.
///
/// Returns `nil` when the full generated trace does not satisfy `predicate`.
/// Otherwise returns the minimal `[Op]` subset that still satisfies it.
func shrinkWithPredicate(
    seed: UInt64,
    opCount: Int,
    predicate: ([Op]) -> Bool
) -> ShrunkFailure? {
    // Single client c7 guarantees that any `release` op targets exactly the
    // ID the planted predicate watches for.
    let clients = [ModelClient(id: DisplayClientID("c7"), kind: .web, role: .interactive)]
    var world = StoreWorld(session: "shrink-seam-\(seed)")
    var rng = DeterministicRNG(seed: seed)
    var ops: [Op] = []
    for _ in 0..<opCount {
        let op = world.randomLegalOp(clients: clients, using: &rng)
        _ = world.apply(op)
        ops.append(op)
    }

    guard predicate(ops) else { return nil }

    let minimal = greedyReduceOps(ops: ops, predicate: predicate)

    return ShrunkFailure(
        ops: minimal,
        schedule: Array(0..<minimal.count),
        violation: .s1MultipleOwners,  // placeholder — test seam has no real oracle
        transcript: minimal.enumerated().map { "#\($0.offset) \(String(describing: $0.element))" }
    )
}

// MARK: - Delta-debugging

/// Greedily remove ops one at a time while `predicate` still holds.
/// Runs until a fixed point (no single removal improves the result).
private func greedyReduceOps(ops: [Op], predicate: ([Op]) -> Bool) -> [Op] {
    var current = ops
    var madeProgress = true
    while madeProgress {
        madeProgress = false
        var i = 0
        while i < current.count {
            var candidate = current
            candidate.remove(at: i)
            if predicate(candidate) {
                current = candidate
                madeProgress = true
                // Don't advance i — the next element has shifted into position i.
            } else {
                i += 1
            }
        }
    }
    return current
}

private func greedyReduceWebOps(
    ops: [WebControlEnvelope],
    predicate: ([WebControlEnvelope]) -> Bool
) -> [WebControlEnvelope] {
    var current = ops
    var madeProgress = true
    while madeProgress {
        madeProgress = false
        var i = 0
        while i < current.count {
            var candidate = current
            candidate.remove(at: i)
            if predicate(candidate) {
                current = candidate
                madeProgress = true
            } else {
                i += 1
            }
        }
    }
    return current
}

// MARK: - Conversion helpers

/// Best-effort conversion from a `WebControlEnvelope` to the nearest `Op`
/// equivalent, for use in `ShrunkFailure.ops`.
private func webEnvelopeToOp(_ env: WebControlEnvelope) -> Op {
    switch env {
    case let .hello(id, kind, role, visible, cols, rows):
        let grid = (try? DisplayGrid(cols: cols, rows: rows)) ?? .daemonFallback
        return .attach(ModelClient(id: id, kind: kind, role: role), visible: visible, grid: grid)
    case let .takeControl(id, _, cols, rows):
        let grid = (try? DisplayGrid(cols: cols, rows: rows)) ?? .daemonFallback
        return .takeControl(id, grid: grid)
    case let .ownerResize(id, epoch, cols, rows):
        let grid = (try? DisplayGrid(cols: cols, rows: rows)) ?? .daemonFallback
        return .ownerResize(id, believedEpoch: epoch, grid: grid)
    default:
        return .hello(DisplayClientID("unknown"))
    }
}

// MARK: - Source-emission helpers

private func violationLabel(_ v: Violation) -> String {
    switch v {
    case .s1MultipleOwners:              return "s1MultipleOwners"
    case .s2EpochRegressed:              return "s2EpochRegressed"
    case .s3StaleResizeAccepted:         return "s3StaleResizeAccepted"
    case .s4InconsistentOwnerFields:     return "s4InconsistentOwnerFields"
    case .s5SupersededApplied:           return "s5SupersededApplied"
    case .s6NonOwnerResizedPTY:          return "s6NonOwnerResizedPTY"
    case .s7NonOwnerInput:               return "s7NonOwnerInput"
    case .l1Divergence:                  return "l1Divergence"
    case .l2SilentPromotion:             return "l2SilentPromotion"
    }
}

private func opSourceLiteral(_ op: Op) -> String {
    switch op {
    case let .attach(c, vis, g):
        return ".attach(ModelClient(id: DisplayClientID(\"\(c.id.rawValue)\"), kind: .\(c.kind.rawValue), role: .\(c.role.rawValue)), visible: \(vis), grid: try! DisplayGrid(cols: \(g.cols), rows: \(g.rows)))"
    case let .detach(id):
        return ".detach(DisplayClientID(\"\(id.rawValue)\"))"
    case let .takeControl(id, g):
        return ".takeControl(DisplayClientID(\"\(id.rawValue)\"), grid: try! DisplayGrid(cols: \(g.cols), rows: \(g.rows)))"
    case let .release(id):
        return ".release(DisplayClientID(\"\(id.rawValue)\"))"
    case let .ownerResize(id, epoch, g):
        return ".ownerResize(DisplayClientID(\"\(id.rawValue)\"), believedEpoch: \(epoch), grid: try! DisplayGrid(cols: \(g.cols), rows: \(g.rows)))"
    case let .setVisible(id, vis):
        return ".setVisible(DisplayClientID(\"\(id.rawValue)\"), \(vis))"
    case let .hello(id):
        return ".hello(DisplayClientID(\"\(id.rawValue)\"))"
    }
}
