import Foundation
import GrafttyProtocol

public extension WorktreeStats {
    /// Project to the wire-shape consumed by the mobile sidebar's
    /// divergence gutter. `baseRef` is passed through (rather than
    /// derived from `upstreamRefs?.displayLabel`) so callers that
    /// already paid for the lookup can avoid re-resolving it.
    func toWire(baseRef: String?) -> WorktreeWireStats {
        WorktreeWireStats(
            ahead: ahead,
            behind: behind,
            hasUncommittedChanges: hasUncommittedChanges,
            baseRef: baseRef
        )
    }
}
