import Foundation

/// Process-local admission for host pairing ceremonies.
///
/// Graftty exposes pairing through both the Settings listener and the
/// always-on LAN Remote Mac routes. Those entry points use different session
/// objects, so their per-session busy checks cannot prevent two ceremonies
/// from running concurrently. Sharing one admission instance makes the
/// process own at most one ceremony while identity/trust persistence remains
/// shared.
@MainActor
final class HostPairingAdmission {
    struct Lease: Equatable {
        fileprivate let id = UUID()
    }

    private var activeLease: Lease?

    init() {}

    func acquire() -> Lease? {
        guard activeLease == nil else { return nil }
        let lease = Lease()
        activeLease = lease
        return lease
    }

    func release(_ lease: Lease) {
        guard activeLease == lease else { return }
        activeLease = nil
    }
}
