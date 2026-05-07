import Foundation
import GrafttyProtocol

public extension WorktreeStats {
    /// Project to the wire-shape consumed by the mobile sidebar's
    /// divergence gutter.
    func toWire() -> WorktreeWireStats {
        WorktreeWireStats(
            ahead: ahead,
            behind: behind,
            hasUncommittedChanges: hasUncommittedChanges,
            baseRef: upstreamRefs?.displayLabel
        )
    }
}
