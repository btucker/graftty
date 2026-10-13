import Foundation
import GrafttyProtocol

/// Image arrival only changes availability. Presentation always requires a tap.
enum RemoteImageOffers {
    static func browserResources(in offers: [RemoteOpenOffer]) -> [RemoteOpenOffer] {
        offers.filter { $0.previewKind != "image" }
    }

    static func latest(in offers: [RemoteOpenOffer], scope: TerminalBrowserRequest.Scope) -> RemoteOpenOffer? {
        guard let device = scope.ownerDeviceID else { return nil }
        return offers.last {
            $0.previewKind == "image" && $0.url == nil && $0.paneSessionName == scope.sessionName
                && $0.previewOwnerDeviceID == device
        }
    }

    /// Retains the route selected by the user's tap across asynchronous downloads.
    struct Request: Equatable {
        let offer: RemoteOpenOffer
        let scope: TerminalBrowserRequest.Scope

        func isCurrent(latest: RemoteOpenOffer?, scope: TerminalBrowserRequest.Scope, isReady: Bool) -> Bool {
            isReady && self.scope == scope && offer == latest
        }
    }
}
