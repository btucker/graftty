import Foundation
import GrafttyProtocol

/// Retained by the presentation, independently of scene-driven viewer connections.
final class ChromeTabInitialLaunch {
    let offerID: UUID
    private let originalURL: String
    private var tabID: String?

    convenience init(offer: RemoteOpenOffer) {
        self.init(id: offer.id, url: offer.url?.absoluteString ?? "")
    }

    init(id: UUID, url: String) {
        offerID = id
        originalURL = url
    }

    var action: ChromeTabAction {
        if let tabID { return .select(tabID: tabID) }
        return .launchOffer(id: offerID, url: originalURL)
    }

    @discardableResult
    func accept(_ response: ChromeTabResponse) -> Bool {
        guard response.error == nil, let state = response.state, let id = state.selectedTabID,
              state.tabs.contains(where: { $0.id == id }) else { return false }
        tabID = id
        return true
    }
}
