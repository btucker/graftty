import Foundation
import Testing
@testable import GrafttyProtocol

struct RemoteOpenOfferTests {
    @Test("@spec IMAGE-2.1: When an image offer crosses a host connection, the application shall preserve optional image intent and recipient metadata while decoding absent or unknown intent without treating it as an image request.")
    func imageIntentRoundTripsAndLegacyOffersRemainUnspecified() throws {
        let image = RemoteOpenOffer(id: UUID(), filename: "image.png", byteCount: 4, paneSessionName: "pane",
                                    previewKind: "image", previewOwnerDeviceID: .init(value: "phone"))
        let encoded = try JSONEncoder().encode(image)
        #expect(try JSONDecoder().decode(RemoteOpenOffer.self, from: encoded) == image)
        var legacy = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        legacy.removeValue(forKey: "previewKind")
        legacy.removeValue(forKey: "previewOwnerDeviceID")
        let old = try JSONDecoder().decode(RemoteOpenOffer.self, from: JSONSerialization.data(withJSONObject: legacy))
        #expect(old.previewKind == nil)
        #expect(old.previewOwnerDeviceID == nil)
        legacy["previewKind"] = "future"
        #expect(try JSONDecoder().decode(RemoteOpenOffer.self, from: JSONSerialization.data(withJSONObject: legacy)).previewKind == "future")
    }
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
