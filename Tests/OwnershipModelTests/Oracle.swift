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
/// Call `checkAfterEvent` after every store operation; it accumulates the highest
/// epoch seen so it can detect S2 regressions across the sequence.
/// S5 and L1 violations for the web transport are accumulated in `violations`
/// via `MultiTransportWorld.deliverToWebFollower` and `checkL1`.
struct Oracle {
    private var highestEpoch: UInt64 = 0

    /// Accumulated violations from S5/L1 web-transport checks.
    var violations: [Violation] = []

    mutating func checkAfterEvent(
        store: SessionDisplayOwnershipStore,
        session: String,
        lastResize: SessionDisplayOwnershipResizeResult?,
        requestedEpoch: UInt64?
    ) -> [Violation] {
        let snapshot = store.snapshot(sessionName: session)
        var violations: [Violation] = []

        // S1: at most one owner at any instant. ownerClientID is a single optional today,
        // so the count is structurally ≤1 — this guard fires if a future snapshot shape
        // exposes a second owner field.
        let ownerCount = [snapshot.ownerClientID].compactMap { $0 }.count
        if ownerCount > 1 {
            violations.append(.s1MultipleOwners)
        }

        // S4: ownerClientID == nil ⟺ ownerKind == nil
        if (snapshot.ownerClientID == nil) != (snapshot.ownerKind == nil) {
            violations.append(.s4InconsistentOwnerFields)
        }

        // S2: epoch never decreases across calls.
        // A fully torn-down session legitimately restarts at epoch 0; reset the high-water mark.
        if snapshot.epoch == 0 && highestEpoch > 0 {
            highestEpoch = 0
        } else if snapshot.epoch < highestEpoch {
            violations.append(.s2EpochRegressed(from: highestEpoch, to: snapshot.epoch))
        }
        highestEpoch = max(highestEpoch, snapshot.epoch)

        // S3: accepted resize ⇒ requestedEpoch == snapshot.epoch
        if let resize = lastResize, resize.accepted, let reqEpoch = requestedEpoch,
           reqEpoch != snapshot.epoch {
            violations.append(.s3StaleResizeAccepted(epoch: reqEpoch, current: snapshot.epoch))
        }

        return violations
    }
}
