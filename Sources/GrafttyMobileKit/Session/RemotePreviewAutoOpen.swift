import Foundation
import GrafttyProtocol

/// Consumption survives dismissal, focus changes and transport suspension.
struct RemotePreviewAutoOpen {
    private var attempted = Set<UUID>()
    mutating func take(_ offer: RemoteOpenOffer?, isReady: Bool, canPresent: Bool) -> Bool {
        guard isReady, canPresent, let offer, !attempted.contains(offer.id) else { return false }
        attempted.insert(offer.id)
        return true
    }
}
