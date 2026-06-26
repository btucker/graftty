import GrafttyProtocol

/// A minimal Swift model standing in for the TypeScript web client follower.
/// Records the highest epoch applied and the last applied grid/owner.
///
/// By default enforces a monotonic guard: `apply` updates state only when
/// `snapshot.epoch >= highestApplied`.  A future `bypassEpochGuard` flag
/// could disable the guard — but that flag is NOT present in this task (YAGNI).
final class WebFollowerView {
    private(set) var highestApplied: UInt64 = 0
    private(set) var grid: DisplayGrid?
    private(set) var ownerClientID: DisplayClientID?

    func apply(_ snapshot: DisplayOwnershipSnapshot) {
        guard snapshot.epoch >= highestApplied else { return }
        highestApplied = snapshot.epoch
        grid = snapshot.grid
        ownerClientID = snapshot.ownerClientID
    }
}
