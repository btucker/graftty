import Foundation
import GrafttyProtocol

/// Selects native preview collections for the originating pane and paired device.
enum RemoteImageOffers {
    static func browserResources(in offers: [RemoteOpenOffer]) -> [RemoteOpenOffer] {
        offers.filter { !$0.isNativePreview }
    }

    static func latest(in offers: [RemoteOpenOffer], scope: TerminalBrowserRequest.Scope) -> RemoteOpenOffer? {
        guard let device = scope.ownerDeviceID else { return nil }
        return offers.last {
            $0.isNativePreview && $0.url == nil && $0.paneSessionName == scope.sessionName
                && $0.previewOwnerDeviceID == device
        }
    }

    static func collection(in offers: [RemoteOpenOffer], scope: TerminalBrowserRequest.Scope) -> [RemoteOpenOffer] {
        guard let latest = latest(in: offers, scope: scope) else { return [] }
        guard let group = latest.previewGroupID else { return [latest] }
        return offers.filter {
            $0.isNativePreview && $0.previewGroupID == group && $0.url == nil
                && $0.paneSessionName == scope.sessionName && $0.previewOwnerDeviceID == scope.ownerDeviceID
        }
    }

    /// The collection holding `offer` when the host has revised its content, whether or
    /// not it is still a pending delivery. Library entries carry no recipient.
    static func revisedCollection(of offer: RemoteOpenOffer, in offers: [RemoteOpenOffer]) -> [RemoteOpenOffer]? {
        let group = offer.previewGroupID ?? offer.id
        guard let collection = RemoteOpenOffer.previewCollections(in: offers).first(where: { $0.id == group }),
              collection.contentRevision != (offer.contentRevision ?? 0) else { return nil }
        return collection.offers
    }

    /// Retains the route selected by the user's tap across asynchronous downloads.
    struct Request: Equatable {
        let offer: RemoteOpenOffer
        let scope: TerminalBrowserRequest.Scope

        func isCurrent(latest: RemoteOpenOffer?, scope: TerminalBrowserRequest.Scope, isReady: Bool) -> Bool {
            // Compare identity: a revised offer is the same request with newer content.
            isReady && self.scope == scope && offer.id == latest?.id
        }
    }
}
