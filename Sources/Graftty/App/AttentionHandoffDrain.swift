import Foundation
import GrafttyKit

/// Applies Attention file-handoff events to `AppState` and deletes each
/// event file only after the result is on disk, so a failed or interrupted
/// save leaves the event for retry (REMOTE-23.10). One batch costs one
/// off-main `state.json` write instead of a synchronous write per event.
///
/// Drains run one at a time: the save suspends, and a second drain started
/// meanwhile would re-read and re-apply the same files.
@MainActor
final class AttentionHandoffDrain {
    private let handoff: AttentionFileHandoff
    private let apply: @MainActor (AttentionFileActivityEvent) -> Void
    private let persist: @MainActor () async throws -> Void
    private var isDraining = false
    private var drainAgain = false

    init(
        handoff: AttentionFileHandoff,
        apply: @escaping @MainActor (AttentionFileActivityEvent) -> Void,
        persist: @escaping @MainActor () async throws -> Void
    ) {
        self.handoff = handoff
        self.apply = apply
        self.persist = persist
    }

    func drain() async {
        guard !isDraining else {
            drainAgain = true
            return
        }
        isDraining = true
        defer { isDraining = false }
        repeat {
            drainAgain = false
            do {
                let handled = try handoff.takeActivities(apply)
                guard !handled.isEmpty else { continue }
                try await persist()
                try handoff.remove(handled)
            } catch {
                NSLog("[Graftty] Attention file handoff failed: %@", String(describing: error))
                return
            }
        } while drainAgain
    }
}
