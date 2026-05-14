#if canImport(UIKit)
import Foundation
import Testing
@testable import GrafttyMobileKit

@Suite("PushRegistrar")
struct PushRegistrarTests {
    private final class FakeHostStore: PushHostSource, @unchecked Sendable {
        let hosts: [PushTargetHost]
        init(hosts: [PushTargetHost]) { self.hosts = hosts }
    }

    private actor CapturingNetwork: PushRegisterNetwork {
        struct Call: Sendable { let baseURL: URL; let body: PushRegisterRequest }
        private(set) var calls: [Call] = []
        func register(baseURL: URL, body: PushRegisterRequest) async throws {
            calls.append(Call(baseURL: baseURL, body: body))
        }
        func snapshot() -> [Call] { calls }
    }

    @Test("""
@spec PUSH-1.1: When the iOS user adds a host or the application foregrounds with hosts already saved, the application shall POST `{deviceToken, deviceName, platform:"ios"}` to `<host>/push/register` for every saved host whose `lastUsedAt` is within 90 days.
""")
    func push_1_1_fansToEveryHost() async throws {
        let hosts: [PushTargetHost] = [
            .init(baseURL: URL(string: "http://h1.local")!, lastUsedAt: Date()),
            .init(baseURL: URL(string: "http://h2.local")!, lastUsedAt: Date()),
        ]
        let net = CapturingNetwork()
        let registrar = PushRegistrar(hostSource: FakeHostStore(hosts: hosts), network: net,
                                      deviceName: "iPhone-Test")
        await registrar.deviceTokenDidArrive(token: "deadbeef")
        await registrar.registerWithAllHosts()
        let calls = await net.snapshot()
        #expect(calls.count == 2)
        #expect(Set(calls.map(\.baseURL.host!)) == ["h1.local", "h2.local"])
        #expect(calls.allSatisfy { $0.body.deviceToken == "deadbeef" })
        #expect(calls.allSatisfy { $0.body.platform == "ios" })
        #expect(calls.allSatisfy { $0.body.deviceName == "iPhone-Test" })
    }

    @Test("""
@spec PUSH-1.2: If the iOS user denies notification authorization, the application shall not call `registerForRemoteNotifications()` and shall not POST `/push/register`.
""")
    func push_1_2_skipsWithoutToken() async throws {
        let net = CapturingNetwork()
        let registrar = PushRegistrar(hostSource: FakeHostStore(hosts: [
            .init(baseURL: URL(string: "http://h.local")!, lastUsedAt: Date())
        ]), network: net, deviceName: "iPhone")
        // Don't call deviceTokenDidArrive(...) — simulates "denied authorization, no token ever captured".
        await registrar.registerWithAllHosts()
        let calls = await net.snapshot()
        #expect(calls.isEmpty)
    }

    @Test func registerFiltersStaleHosts() async throws {
        let net = CapturingNetwork()
        let hosts: [PushTargetHost] = [
            .init(baseURL: URL(string: "http://fresh.local")!, lastUsedAt: Date()),
            .init(baseURL: URL(string: "http://stale.local")!,
                  lastUsedAt: Date().addingTimeInterval(-91 * 86_400)),
        ]
        let registrar = PushRegistrar(hostSource: FakeHostStore(hosts: hosts), network: net,
                                      deviceName: "iPhone")
        await registrar.deviceTokenDidArrive(token: "tok")
        await registrar.registerWithAllHosts()
        let calls = await net.snapshot()
        #expect(calls.count == 1)
        #expect(calls[0].baseURL.host == "fresh.local")
    }
}
#endif
