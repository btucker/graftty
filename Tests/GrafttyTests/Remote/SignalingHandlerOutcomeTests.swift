import Testing
import GrafttyHostAgent
import GrafttyKit
@testable import Graftty

/// `GrafttyApp` wires `POST /v1/rtc/offer` to `WebRTCHostAgent.acceptOffer`
/// via a closure that maps a thrown error to a `WebServer.SignalingHandlerOutcome`.
/// `GrafttyApp.signalingOutcome(forAcceptOfferFailure:)` is that mapping,
/// extracted so it's testable without booting the whole app — see
/// `GrafttyApp.swift`'s `startup()` for the production call site.
@Suite("GrafttyApp.signalingOutcome(forAcceptOfferFailure:) — maps acceptOffer failures to signaling HTTP outcomes.")
struct SignalingHandlerOutcomeTests {

    /// @spec-less regression test (Task 2 has no @spec ID — see the W3
    /// task brief): `WebRTCHostAgent.HostError.busy` — thrown when a
    /// second offer arrives while a negotiation is already in flight —
    /// must map to `.unavailable` (503, retryable) rather than
    /// `.internalFailure` (500), so `RemoteConnectionCoordinator` can
    /// tell "temporarily busy" apart from a real server error and fall
    /// back to `/ws` without marking the host permanently bad.
    @Test
    func busyErrorMapsToUnavailable() {
        let outcome = GrafttyApp.signalingOutcome(forAcceptOfferFailure: WebRTCHostAgent.HostError.busy)
        guard case .unavailable = outcome else {
            Issue.record("expected .unavailable, got \(outcome)")
            return
        }
    }

    @Test
    func otherErrorsMapToInternalFailure() {
        let outcome = GrafttyApp.signalingOutcome(forAcceptOfferFailure: WebRTCHostAgent.HostError.sdpGenerationFailed)
        guard case .internalFailure = outcome else {
            Issue.record("expected .internalFailure, got \(outcome)")
            return
        }
    }
}
