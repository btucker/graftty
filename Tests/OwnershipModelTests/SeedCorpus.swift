import Testing

/// Committed deterministic seed corpus for the ownership-model CI gate.
///
/// Seeds 1…1000 run on every push/PR via the `ownership-model` step in
/// `.github/workflows/ci.yml`.  If any seed produces a violation that is a
/// real finding — stop and shrink with `shrink(seed:opCount:)` rather than
/// narrowing the corpus or weakening assertions.
///
/// Wider random batches (seeds > 1000) are intentionally excluded from the
/// CI gate.  Run them manually or as a nightly sweep:
///
///     swift test --filter OwnershipModel   # CI gate (seeds 1…1000)
///     # Manual / nightly: generate seeds > 1000 and replay via shrink / replayWebOps
///
/// ## Gate-honesty note
///
/// A green macOS `OwnershipModel` run exercises REAL production code for:
///   - S1–S4  (`SessionDisplayOwnershipStore` + `WebSocketBridgeCoordinator`)
///   - S5/L1  (`WebFollowerView` guard, now via genuine multi-path cross-channel
///             reordering — non-vacuous; see `multiPathGuardIsNonVacuous` test)
///   - L2     (owner release → ownerless; see `l2PathIsNonVacuous` test)
///   - S6/S7  (Mac `HostManagedZmxBackend` via `MacSeamTests`)
///
/// The MODELED follower (`WebFollowerView`) stands in for the TypeScript client.
/// The only REAL follower adapter — iOS `SessionClient` — is `#if canImport(UIKit)`
/// and runs only on the iOS CI job (`ios-build-and-test` in `ci.yml`).
/// A green macOS `OwnershipModel` run does NOT by itself certify the real iOS
/// follower; iOS CI is the authoritative check for that seam.
let corpusSeeds: [UInt64] = Array(1...1000)

@Suite("Ownership-model corpus sweep")
struct OwnershipModelCorpusSweepTests {
    @Test(arguments: corpusSeeds)
    func noViolationsInCorpus(seed: UInt64) {
        let result = runScenario(seed: seed, opCount: 60)
        #expect(
            result.violations.isEmpty,
            "seed \(seed): \(result.violations)\n\(result.transcript.joined(separator: "\n"))"
        )
    }
}
