import Foundation
import GrafttyProtocol

/// The coordinator retains reservations and consumption across pane navigation.
struct RemotePreviewAutoOpen {
    private struct Entry {
        let expires: Date
        let completed: Bool
    }
    private var seen: [UUID: Entry] = [:]

    mutating func take(_ offer: RemoteOpenOffer?, isReady: Bool, canPresent: Bool, now: Date = Date()) -> Bool {
        seen = seen.filter { $0.value.expires > now }
        guard isReady, canPresent, let offer, seen[offer.id] == nil else { return false }
        seen[offer.id] = Entry(expires: now.addingTimeInterval(900), completed: false)
        return true
    }

    mutating func deferPresentation(of id: UUID) {
        if seen[id]?.completed == false { seen[id] = nil }
    }

    /// Mounted previews and reported failures both end automatic retries.
    mutating func complete(_ id: UUID, now: Date = Date()) {
        seen[id] = Entry(expires: now.addingTimeInterval(900), completed: true)
    }
}
