import Foundation
import GrafttyProtocol

/// A "PR resolved — delete worktree?" offer (GIT-4.7) captured for a
/// later retry. Value type so it's trivially testable and comparable.
struct PendingResolvedOffer: Equatable {
    let worktreePath: String
    let prNumber: Int
    let prTitle: String
    let state: PRInfo.State
}

/// @spec GIT-4.20
/// Holds resolved-PR offers that fired while no window was available to
/// host the sheet, so a later window-available event can retry them.
///
/// `PRStatusStore.onPRResolved` fires the resolved edge exactly once —
/// the GIT-4.7 idempotent-refetch guard forbids re-firing for the same
/// terminal PR — so an offer dropped because `NSApp.mainWindow` was nil
/// (app backgrounded, or Settings / the Team Activity Log foregrounded
/// at merge time) would otherwise be lost forever. Keyed by worktree so
/// a newer resolution supersedes an older pending one for the same
/// worktree.
@MainActor
final class PendingResolvedOfferQueue {
    private var offersByWorktree: [String: PendingResolvedOffer] = [:]

    var isEmpty: Bool { offersByWorktree.isEmpty }

    /// Remember an offer that couldn't present now.
    func enqueue(_ offer: PendingResolvedOffer) {
        offersByWorktree[offer.worktreePath] = offer
    }

    /// Forget a worktree's pending offer (it presented, or the worktree
    /// went away).
    func remove(worktreePath: String) {
        offersByWorktree.removeValue(forKey: worktreePath)
    }

    /// Return every pending offer and clear the queue. The caller
    /// re-attempts each and re-enqueues any that still can't present.
    func drain() -> [PendingResolvedOffer] {
        defer { offersByWorktree.removeAll() }
        return Array(offersByWorktree.values)
    }
}
