import Foundation
import Sparkle

/// `SPUStandardUserDriverDelegate` conformance for `UpdaterController`.
///
/// The two interesting callbacks are
/// `standardUserDriverShouldHandleShowingScheduledUpdate(_:andInImmediateFocus:)`
/// and `standardUserDriverWillHandleShowingUpdate(_:forUpdate:state:)`.
/// The former lets us veto Sparkle's modal alert on silent scheduled
/// checks (return `false` so Sparkle hands responsibility to us). The
/// latter tells us — whether or not we're handling it — which update is
/// about to be shown; we snapshot its version into the controller's
/// published state so the titlebar badge can render without poking at
/// Sparkle internals.
///
/// User-initiated checks (`immediateFocus == true`) are always handled
/// by the standard driver (return `true`). That makes `Graftty → Check
/// for Updates…` and badge clicks both present Sparkle's standard
/// dialog, which is the consistent UX we want.
extension UpdaterController: @MainActor SPUStandardUserDriverDelegate {

    public var supportsGentleScheduledUpdateReminders: Bool { true }

    public func standardUserDriverShouldHandleShowingScheduledUpdate(
        _ update: SUAppcastItem,
        andInImmediateFocus immediateFocus: Bool
    ) -> Bool {
        // Let the standard driver show the modal when the check is
        // user-initiated or the app is being immediately focused (e.g.
        // the user just came back to the app and there's a pending
        // update). Suppress it for silent background checks — the
        // titlebar badge surfaces those instead.
        return immediateFocus
    }

    public func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool,
        forUpdate update: SUAppcastItem,
        state: SPUUserUpdateState
    ) {
        if handleShowingUpdate {
            // Standard driver is about to show the modal for this update —
            // the badge is redundant; clear it so we don't have both UI
            // surfaces arguing about the same update. Subsequent install /
            // skip / defer choices are tracked by Sparkle's own state;
            // when the updater cycle resets on the next scheduled tick,
            // `willHandleShowingUpdate(false, …)` will re-populate the
            // badge if an update is still pending.
            notifyPendingUpdateCleared()
        } else {
            // We're responsible for surfacing this update — populate the
            // badge with the advertised version.
            notifyPendingUpdateDiscovered(version: update.displayVersionString)
        }
    }
}
