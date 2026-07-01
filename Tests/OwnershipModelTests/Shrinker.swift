import GrafttyProtocol
@testable import GrafttyKit

// MARK: - Public types

/// The result of a successful shrink: a minimal op list that still reproduces
/// the same `Violation`, plus a regression-test emitter.
struct ShrunkFailure {
    /// Minimal op sequence that reproduces `violation` (StoreWorld-style).
    let ops: [Op]
    /// Minimal WebControlEnvelope sequence that reproduces `violation` via
    /// `replayWebOps`, or `nil` when the violation is interleaving-dependent
    /// and cannot be replayed sequentially (or when `shrinkWithPredicate` is used).
    let webOps: [WebControlEnvelope]?
    /// Delivery-schedule indices (placeholder; captures interleave order for
    /// the web-op replay path where schedule choices are available).
    let schedule: [Int]
    /// The first violation that this trace reproduces.
    let violation: Violation
    /// Human-readable event log for the minimal trace.
    let transcript: [String]

    /// Emit a standalone Swift source snippet containing `import` lines and a
    /// `@Test` that reproduces `violation`.
    ///
    /// - For S1–S4 violations: replays through `StoreWorld + Oracle` (no followers
    ///   needed — the store itself catches these).
    /// - For S5/L1 violations with a sequential-replayable trace (`webOps != nil`):
    ///   replays through `replayWebOps`, which builds a `MultiTransportWorld` WITH
    ///   followers and detects S5/L1 — not a `StoreWorld` no-op.
    /// - For S5/L1 violations that are interleaving-dependent (`webOps == nil`) or
    ///   for S6/S7/L2 violations that require paths not covered by either replay:
    ///   emits a `.disabled` test with the op list in a comment so the trace is
    ///   preserved without emitting a green no-op.
    ///
    /// The emitted snippet includes the three necessary `import` declarations and
    /// compiles against the `OwnershipModelTests` target without modification.
    func asRegressionTest() -> String {
        let indent = "    "
        var lines: [String] = []

        // File-level imports required by the emitted snippet.
        lines.append("import Testing")
        lines.append("import GrafttyProtocol")
        lines.append("@testable import GrafttyKit")
        lines.append("")

        let fnName = "regression_\(violationLabel(violation))"

        switch violation {
        case .s5SupersededApplied, .l1Divergence:
            if let webOps = webOps {
                // Reproducible via sequential replay — exercise followers via replayWebOps.
                lines.append("@Test func \(fnName)() {")
                lines.append("\(indent)let webOps: [WebControlEnvelope] = [")
                for op in webOps {
                    lines.append("\(indent)\(indent)\(webEnvelopeSourceLiteral(op)),")
                }
                lines.append("\(indent)]")
                lines.append("\(indent)let result = replayWebOps(ops: webOps, session: \"regression\")")
                lines.append("\(indent)#expect(result.violations.contains \(violationCaseMatch(violation)))")
                lines.append("}")
            } else {
                // Interleaving-dependent — preserve trace as comment; disable to avoid no-op.
                lines.append("// Op trace (interleaving-dependent; not directly replayable via sequential path):")
                for op in ops {
                    lines.append("// \(opSourceLiteral(op))")
                }
                lines.append("@Test(.disabled(\"interleaving-dependent; minimal trace recorded in comment\"))")
                lines.append("func \(fnName)() async throws { }")
            }

        case .s6NonOwnerResizedPTY, .s7NonOwnerInput, .l2SilentPromotion:
            // Requires Mac/iOS backend path not covered by store or follower replay.
            lines.append("// Op trace (requires Mac/iOS backend; not replayable via store or follower path):")
            for op in ops {
                lines.append("// \(opSourceLiteral(op))")
            }
            lines.append("@Test(.disabled(\"requires Mac/iOS backend; minimal trace recorded in comment\"))")
            lines.append("func \(fnName)() async throws { }")

        case .s1MultipleOwners, .s2EpochRegressed, .s3StaleResizeAccepted, .s4InconsistentOwnerFields:
            // S1–S4: StoreWorld + Oracle is sufficient.
            lines.append("@Test func \(fnName)() {")
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
        }

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

    let reproducibleViaReplay = webPredicate(capturedOps)

    let opsToShrink: [WebControlEnvelope]
    let webOpsForRegression: [WebControlEnvelope]?
    let finalTranscript: [String]

    if reproducibleViaReplay {
        // The violation survives sequential replay — shrink and record the minimal web ops.
        opsToShrink = greedyReduce(capturedOps, predicate: webPredicate)
        webOpsForRegression = opsToShrink
        finalTranscript = replayWebOps(ops: opsToShrink, session: "shrink-final-\(seed)").transcript
    } else {
        // The violation is interleaving-dependent; keep the full trace unchanged.
        // Use the original run transcript (which shows the violation) rather than
        // a clean replay transcript that shows no violation.
        opsToShrink = capturedOps
        webOpsForRegression = nil
        finalTranscript = initial.transcript
            + ["<violation not reproducible via sequential replay; interleaving-dependent>"]
    }

    let minimalOps = opsToShrink.map { webEnvelopeToOp($0) }

    return ShrunkFailure(
        ops: minimalOps,
        webOps: webOpsForRegression,
        schedule: Array(0..<minimalOps.count),
        violation: targetViolation,
        transcript: finalTranscript
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

    let minimal = greedyReduce(ops, predicate: predicate)

    return ShrunkFailure(
        ops: minimal,
        webOps: nil,
        schedule: Array(0..<minimal.count),
        violation: .s1MultipleOwners,  // placeholder — test seam has no real oracle
        transcript: minimal.enumerated().map { "#\($0.offset) \(String(describing: $0.element))" }
    )
}

// MARK: - Delta-debugging

/// Greedily remove items one at a time while `predicate` still holds.
/// Runs until a fixed point (no single removal improves the result).
private func greedyReduce<T>(_ items: [T], predicate: ([T]) -> Bool) -> [T] {
    var current = items
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
    case .resize, .grid, .ownership:
        fatalError("unhandled envelope in webEnvelopeToOp: \(env)")
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

/// Returns a trailing-closure expression that matches `v` by case, ignoring
/// associated values.  Used inside the emitted `#expect(…)` assertion.
private func violationCaseMatch(_ v: Violation) -> String {
    switch v {
    case .s1MultipleOwners:
        return "{ if case .s1MultipleOwners = $0 { return true }; return false }"
    case .s2EpochRegressed:
        return "{ if case .s2EpochRegressed = $0 { return true }; return false }"
    case .s3StaleResizeAccepted:
        return "{ if case .s3StaleResizeAccepted = $0 { return true }; return false }"
    case .s4InconsistentOwnerFields:
        return "{ if case .s4InconsistentOwnerFields = $0 { return true }; return false }"
    case .s5SupersededApplied:
        return "{ if case .s5SupersededApplied = $0 { return true }; return false }"
    case .s6NonOwnerResizedPTY:
        return "{ if case .s6NonOwnerResizedPTY = $0 { return true }; return false }"
    case .s7NonOwnerInput:
        return "{ if case .s7NonOwnerInput = $0 { return true }; return false }"
    case .l1Divergence:
        return "{ if case .l1Divergence = $0 { return true }; return false }"
    case .l2SilentPromotion:
        return "{ if case .l2SilentPromotion = $0 { return true }; return false }"
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

private func webEnvelopeSourceLiteral(_ env: WebControlEnvelope) -> String {
    switch env {
    case let .hello(id, kind, role, visible, cols, rows):
        return ".hello(clientID: DisplayClientID(\"\(id.rawValue)\"), kind: .\(kind.rawValue), role: .\(role.rawValue), visible: \(visible), cols: \(cols), rows: \(rows))"
    case let .takeControl(id, kind, cols, rows):
        return ".takeControl(clientID: DisplayClientID(\"\(id.rawValue)\"), kind: .\(kind.rawValue), cols: \(cols), rows: \(rows))"
    case let .ownerResize(id, epoch, cols, rows):
        return ".ownerResize(clientID: DisplayClientID(\"\(id.rawValue)\"), epoch: \(epoch), cols: \(cols), rows: \(rows))"
    case let .resize(cols, rows):
        return ".resize(cols: \(cols), rows: \(rows))"
    case let .grid(cols, rows):
        return ".grid(cols: \(cols), rows: \(rows))"
    case .ownership:
        return "/* .ownership cannot be emitted as a source literal */"
    }
}
