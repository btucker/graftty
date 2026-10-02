import Foundation
import Testing
@testable import Graftty

@Suite("Full Disk Access setup offer")
struct FullDiskAccessOfferTests {
    @Test("""
    @spec CONFIG-3.1: When the Full Disk Access setup offer has not been acknowledged, the application shall offer optional access guidance at launch; either response shall dismiss future launch offers, and only Open System Settings shall open the permission settings without recording access as granted.
    """, arguments: [true, false])
    @MainActor
    func acknowledgementPersistsWithoutGrantingAccess(openSettings: Bool) throws {
        let name = "FullDiskAccessOfferTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        #expect(FullDiskAccessOffer.shouldOffer(in: defaults))
        var openedURLs: [URL] = []
        FullDiskAccessOffer.respond(
            openSettings: openSettings,
            defaults: defaults,
            open: { openedURLs.append($0) }
        )
        let reopenedDefaults = try #require(UserDefaults(suiteName: name))
        #expect(!FullDiskAccessOffer.shouldOffer(in: reopenedDefaults))
        #expect(openedURLs == (openSettings ? [FullDiskAccessOffer.settingsURL] : []))
        #expect(defaults.persistentDomain(forName: name)?.count == 1)
    }
}
