import Foundation
import GrafttyProtocol

enum RemoteOpenPresentation {
    static func directBrowserOffer(in offers: [RemoteOpenOffer]) -> RemoteOpenOffer? {
        guard offers.count == 1, let offer = offers.first,
              let scheme = offer.url?.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else { return nil }
        return offer
    }
}

/// Retained by the host connection coordinator, across pane navigation and focus changes.
struct RemoteAuthenticationOffers {
    private struct Entry {
        let expires: Date
        var completed: Bool
    }
    private var seen: [UUID: Entry] = [:]

    mutating func deferPresentation(of id: UUID) {
        if seen[id]?.completed == false { seen[id] = nil }
    }

    mutating func complete(_ id: UUID, now: Date = Date()) {
        seen[id] = Entry(expires: now.addingTimeInterval(900), completed: true)
    }

    mutating func dismiss(_ id: UUID) { complete(id) }

    mutating func consume(_ offers: [RemoteOpenOffer], sessionName: String,
                         ownerDeviceID: RemoteDeviceID?, canPresent: Bool = true,
                         now: Date = Date()) -> RemoteOpenOffer? {
        seen = seen.filter { $0.value.expires > now }
        guard canPresent, let ownerDeviceID else { return nil }
        guard let offer = offers.last(where: {
            guard $0.paneSessionName == sessionName, seen[$0.id] == nil,
                  $0.browserOwnerDeviceID == ownerDeviceID, let url = $0.url else { return false }
            return WorktreeAuthenticationURL(url: url) != nil
                && !WorktreeAuthenticationURL.isLoopbackHost(url.host ?? "")
                && ChromeTabAction.launchOffer(id: $0.id, url: url.absoluteString).isValid
        }) else { return nil }
        seen[offer.id] = Entry(expires: now.addingTimeInterval(900), completed: false)
        return offer
    }
}
