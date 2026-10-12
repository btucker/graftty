import Foundation
import GrafttyProtocol

/// Retained by the presentation, independently of scene-driven viewer connections.
final class ChromeTabInitialLaunch {
    let target: String
    let offerID: UUID
    private let originalURL: String
    private var tabID: String?

    init(offer: RemoteOpenOffer) {
        target = offer.paneSessionName ?? ""
        offerID = offer.id
        originalURL = offer.url?.absoluteString ?? ""
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
