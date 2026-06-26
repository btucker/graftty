import GrafttyProtocol

/// A minimal Swift model standing in for the TypeScript web client follower.
/// Records the highest epoch applied, the last applied emission sequence, and
/// the last applied grid/owner.
///
/// By default enforces a two-part monotonic guard: `apply` updates state only
/// when BOTH `tagged.snapshot.epoch >= highestApplied` AND
/// `tagged.emissionSeq >= highestAppliedEmission`.  Set `bypassEpochGuard =
/// true` to simulate a pre-fix adapter that applies every delivery
/// unconditionally — the oracle then catches ESN regressions via S5.
final class WebFollowerView {
    private(set) var highestApplied: UInt64 = 0
    private(set) var highestAppliedEmission: UInt64 = 0
    private(set) var grid: DisplayGrid?
    private(set) var ownerClientID: DisplayClientID?
    /// Test-only flag: when true, skips all monotonic guards so the oracle
    /// can detect ESN regressions that the guard would otherwise prevent.
    var bypassEpochGuard: Bool = false

    func apply(_ tagged: TaggedSnapshot) {
        guard (tagged.snapshot.epoch >= highestApplied && tagged.emissionSeq >= highestAppliedEmission) || bypassEpochGuard else { return }
        highestApplied = tagged.snapshot.epoch
        highestAppliedEmission = tagged.emissionSeq
        grid = tagged.snapshot.grid
        ownerClientID = tagged.snapshot.ownerClientID
    }
}
