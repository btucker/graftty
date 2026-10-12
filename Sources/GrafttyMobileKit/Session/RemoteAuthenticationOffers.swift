import Foundation
import GrafttyProtocol

/// Retained by the host connection coordinator, across pane navigation and focus changes.
struct RemoteAuthenticationOffers {
    private var seen: [UUID: Date] = [:]

    mutating func deferPresentation(of id: UUID) { seen[id] = nil }

    mutating func consume(_ offers: [RemoteOpenOffer], sessionName: String,
                         ownerDeviceID: RemoteDeviceID?, canPresent: Bool = true,
                         now: Date = Date()) -> RemoteOpenOffer? {
        // Host offers expire after 900 seconds; consumed identities need no longer lifetime.
        seen = seen.filter { $0.value > now }
        if ownerDeviceID != nil && !canPresent { return nil }
        let matching = offers.filter { $0.paneSessionName == sessionName }
        defer {
            for offer in matching { seen[offer.id] = seen[offer.id] ?? now.addingTimeInterval(900) }
        }
        guard let ownerDeviceID else { return nil }
        return matching.last {
            guard seen[$0.id] == nil, $0.browserOwnerDeviceID == ownerDeviceID,
                  let url = $0.url else { return false }
            return WorktreeAuthenticationURL(url: url) != nil
                && !WorktreeAuthenticationURL.isLoopbackHost(url.host ?? "")
        }
    }
}
