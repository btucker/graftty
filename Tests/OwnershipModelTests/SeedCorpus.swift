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
///   - S1–S4  (`SessionDisplayOwnershipStore` + real `WebSocketBridgeCoordinator`,
///             genuinely multi-client — one coordinator per web client; S3 driven
///             with real `ownerResize` acceptance results, see `S3Tests`)
///   - S5/L1  (`WebFollowerView` (epoch,revision) guard, deliveries round-tripped
///             through the real codec, non-vacuous via `multiPathGuardIsNonVacuous`)
///   - L2     (owner release → ownerless; see `l2PathIsNonVacuous` test)
///   - S6/S7  (real `HostManagedZmxBackend` gate via `MacSeamTests` +
///             randomized `MacModelCheckTests`)
///
/// The MODELED follower (`WebFollowerView`) mirrors the production followers'
/// (epoch,revision) guard.  The REAL followers are verified in their own suites,
/// NOT this target: the web guard by `web-client`'s `TerminalPane.test.tsx`
/// (WEB-5.10), the iOS guard by `GrafttyMobileKitTests/SessionClientTests`
/// (IOS-4.27, iOS CI job).  This target's `IOSSeamTests` is `#if canImport(UIKit)`
/// and runs in NO CI job (compiled out on macOS; `OwnershipModelTests` is not in
/// the iOS xcode scheme) — a local iOS-SDK convenience only.
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
