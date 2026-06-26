import GrafttyProtocol
@testable import GrafttyKit

enum Violation: Equatable {
    case s1MultipleOwners
    case s2EpochRegressed(from: UInt64, to: UInt64)
    case s3StaleResizeAccepted(epoch: UInt64, current: UInt64)
    case s4InconsistentOwnerFields
    case s5SupersededApplied(target: DisplayClientID, applied: UInt64, highest: UInt64)
    case s6NonOwnerResizedPTY(DisplayClientID)
    case s7NonOwnerInput(DisplayClientID)
    case l1Divergence(target: DisplayClientID)
    case l2SilentPromotion(DisplayClientID)
}

/// Stateful checker for display-ownership invariants S1–S7 and L1–L2.
///
/// **Single cumulative source of truth:** `violations` accumulates every
/// violation found across the lifetime of this oracle — from both
/// `checkAfterEvent` (S1–S4) and the web-transport helpers in
/// `MultiTransportWorld` (S5, L1).
///
/// `checkAfterEvent` returns the per-call *delta* (newly-found violations
/// only) so callers can assert on the current event without scanning the
/// whole history, while still having everything recorded in `violations`
/// for a final quiescence assertion.
struct Oracle {
    private var highestEpoch: UInt64 = 0

    /// All violations found so far (S1–S7, L1–L2), in discovery order.
    var violations: [Violation] = []

    /// Check S1–S4 invariants after a store event.
    ///
    /// Appends any violations found to `self.violations` AND returns them
    /// as the per-call delta so callers can write:
    ///     `#expect(oracle.checkAfterEvent(...).isEmpty)`
    @discardableResult
    mutating func checkAfterEvent(
        store: SessionDisplayOwnershipStore,
        session: String,
        lastResize: SessionDisplayOwnershipResizeResult?,
        requestedEpoch: UInt64?
    ) -> [Violation] {
        let snapshot = store.snapshot(sessionName: session)
        var found: [Violation] = []

        // S1: at most one owner at any instant. ownerClientID is a single optional today,
        // so the count is structurally ≤1 — this guard fires if a future snapshot shape
        // exposes a second owner field.
        let ownerCount = [snapshot.ownerClientID].compactMap { $0 }.count
        if ownerCount > 1 {
            found.append(.s1MultipleOwners)
        }

        // S4: ownerClientID == nil ⟺ ownerKind == nil
        if (snapshot.ownerClientID == nil) != (snapshot.ownerKind == nil) {
            found.append(.s4InconsistentOwnerFields)
        }

        // S2: epoch never decreases across calls.
        // A fully torn-down session legitimately restarts at epoch 0; reset the high-water mark.
        if snapshot.epoch == 0 && highestEpoch > 0 {
            highestEpoch = 0
        } else if snapshot.epoch < highestEpoch {
            found.append(.s2EpochRegressed(from: highestEpoch, to: snapshot.epoch))
        }
        highestEpoch = max(highestEpoch, snapshot.epoch)

        // S3: accepted resize ⇒ requestedEpoch == snapshot.epoch
        if let resize = lastResize, resize.accepted, let reqEpoch = requestedEpoch,
           reqEpoch != snapshot.epoch {
            found.append(.s3StaleResizeAccepted(epoch: reqEpoch, current: snapshot.epoch))
        }

        violations.append(contentsOf: found)
        return found
    }
}
