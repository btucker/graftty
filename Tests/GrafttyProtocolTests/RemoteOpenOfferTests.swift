import Foundation
import Testing
@testable import GrafttyProtocol

struct RemoteOpenOfferTests {
    @Test("@spec PORTS-5.38: When a remote open offer crosses a host connection, the application shall preserve its originating pane session and intended paired mobile device, and decode older offers without those identities as unspecified.")
    func paneIdentityRoundTripsWithoutChangingLegacyOffers() throws {
        let url = URL(string: "https://example.com/authorize?state=unchanged")!
        let offer = RemoteOpenOffer(id: UUID(), filename: url.absoluteString, byteCount: 0,
                                    url: url, paneSessionName: "graftty-pane", browserOwnerDeviceID: RemoteDeviceID(value: "phone"))
        let bytes = try JSONEncoder().encode(offer)
        #expect(try JSONDecoder().decode(RemoteOpenOffer.self, from: bytes) == offer)
        var old = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        old.removeValue(forKey: "paneSessionName")
        old.removeValue(forKey: "browserOwnerDeviceID")
        let legacy = try JSONDecoder().decode(RemoteOpenOffer.self, from: JSONSerialization.data(withJSONObject: old))
        #expect(legacy.paneSessionName == nil)
        #expect(legacy.browserOwnerDeviceID == nil)
        #expect(legacy.url == url)
        #expect(legacy.id == offer.id)
    }
}
