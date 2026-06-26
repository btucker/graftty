import Foundation
import GrafttyRemoteClient
import Testing

@Suite("GrafttyRemoteClient exports")
struct GrafttyRemoteClientExportsTests {
    @Test("shared remote client types are importable")
    func sharedRemoteClientTypesAreImportable() {
        let _: ClientIdentityStore.Type = ClientIdentityStore.self
        let _: PinnedHostStore.Type = PinnedHostStore.self
        let _: ClientPairingSession.Type = ClientPairingSession.self
        let _: LocalPairingClient.Type = LocalPairingClient.self
        let _: SignalingClient.Type = SignalingClient.self
        let _: RemoteHostConnection.Type = RemoteHostConnection.self
    }

    @Test("API path helper is exported for client modules")
    func apiPathHelperIsExportedForClientModules() throws {
        let baseURL = try #require(URL(string: "https://example.test/graftty/"))

        #expect(baseURL.appendingAPIPath("sessions") == URL(string: "https://example.test/graftty/sessions"))
    }
}
