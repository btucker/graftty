import Foundation
import Testing
import GrafttyProtocol
@testable import GrafttyMobileKit

struct RemoteAuthenticationOffersTests {
    @Test func hostIdentityAndLocalizedPhoneIdentityStillRouteToPhone() {
        let url = URL(string: "https://example.com/authorize?redirect_uri=http%3A%2F%2F127.0.0.1%3A43210%2Fcallback")!
        let hostOwner = DisplayClientID("ssh-phone-device-\(UUID().uuidString)")
        // SSH owner IDs differ from the localized UUID in phone snapshots.
        let phoneOwner = DisplayClientID(UUID().uuidString)
        #expect(hostOwner != phoneOwner)
        // RemoteOpenStore exports the paired ID, not either transport's owner UUID.
        let device = RemoteDeviceID(value: "phone-device")
        let offer = RemoteOpenOffer(id: UUID(), filename: "Sign in", byteCount: 0, url: url,
                                    paneSessionName: "current", browserOwnerDeviceID: device)
        var tracker = RemoteAuthenticationOffers()
        #expect(tracker.consume([offer], sessionName: "current", ownerDeviceID: RemoteDeviceID(value: "phone-device")) == offer)
    }

    @Test("@spec PORTS-5.40: While a mobile resource preview is busy, the application shall defer new sign-in offers until presentation is available and retain consumption across pane focus changes.")
    func busyPresentationDefersWithoutConsuming() {
        let url = URL(string: "https://example.com/authorize?redirect_uri=http%3A%2F%2F127.0.0.1%3A43210%2Fcallback")!
        let owner = RemoteDeviceID(value: "phone")
        let offer = RemoteOpenOffer(id: UUID(), filename: "Sign in", byteCount: 0, url: url,
                                    paneSessionName: "pane", browserOwnerDeviceID: owner)
        var retainedTracker = RemoteAuthenticationOffers()
        #expect(retainedTracker.consume([offer], sessionName: "pane", ownerDeviceID: owner, canPresent: false) == nil)
        #expect(retainedTracker.consume([offer], sessionName: "pane", ownerDeviceID: owner) == offer)
        // Another sheet can appear while an authentication request is pending.
        retainedTracker.deferPresentation(of: offer.id)
        #expect(retainedTracker.consume([offer], sessionName: "pane", ownerDeviceID: owner, canPresent: false) == nil)
        #expect(retainedTracker.consume([offer], sessionName: "pane", ownerDeviceID: owner) == offer)
        // The coordinator retains this value across focus changes and route recreation.
        #expect(retainedTracker.consume([offer], sessionName: "pane", ownerDeviceID: owner) == nil)
        let secondPane = RemoteOpenOffer(id: UUID(), filename: "Sign in", byteCount: 0, url: url,
                                         paneSessionName: "second", browserOwnerDeviceID: owner)
        #expect(retainedTracker.consume([offer, secondPane], sessionName: "pane", ownerDeviceID: owner) == nil)
        #expect(retainedTracker.consume([offer, secondPane], sessionName: "second", ownerDeviceID: owner) == secondPane)
        #expect(retainedTracker.consume([offer, secondPane], sessionName: "pane", ownerDeviceID: owner) == nil)
    }

    @Test("@spec PORTS-5.37: When a new OAuth URL is offered by the mobile user's currently owned pane, the application shall open sign-in on that mobile device once and shall ignore offers from other panes, followers, and ordinary URLs.")
    func opensOnlyNewAuthenticationOffersForOwnedPane() throws {
        let url = URL(string: "https://example.com/authorize?redirect_uri=http%3A%2F%2F127.0.0.1%3A43210%2Fcallback")!
        func offer(_ session: String?, _ url: URL) -> RemoteOpenOffer {
            .init(id: UUID(), filename: url.absoluteString, byteCount: 0, url: url, paneSessionName: session, browserOwnerDeviceID: RemoteDeviceID(value: "current-owner"))
        }
        let owner = RemoteDeviceID(value: "current-owner")
        let authentication = offer("current", url)
        let other = offer("other", url)
        let legacy = offer(nil, url)
        let ordinary = offer("current", URL(string: "https://example.com/ordinary")!)
        let wrongOwner = RemoteOpenOffer(id: UUID(), filename: url.absoluteString, byteCount: 0,
                                         url: url, paneSessionName: "current",
                                         browserOwnerDeviceID: RemoteDeviceID(value: "another-phone"))
        var tracker = RemoteAuthenticationOffers()
        #expect(tracker.consume([other, legacy, ordinary, wrongOwner], sessionName: "current", ownerDeviceID: owner) == nil)
        #expect(tracker.consume([other, authentication], sessionName: "current", ownerDeviceID: owner) == authentication)
        #expect(tracker.consume([authentication], sessionName: "current", ownerDeviceID: owner) == nil)
        let followerOffer = offer("current", url)
        #expect(tracker.consume([followerOffer], sessionName: "current", ownerDeviceID: nil) == nil)
        #expect(tracker.consume([followerOffer], sessionName: "current", ownerDeviceID: owner) == nil)
        let next = offer("current", url)
        #expect(tracker.consume([next], sessionName: "current", ownerDeviceID: owner) == next)
    }
}
