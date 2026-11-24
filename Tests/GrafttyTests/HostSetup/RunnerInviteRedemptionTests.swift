import Foundation
import Testing
import GrafttyProtocol
import GrafttyRemoteClient
@testable import GrafttyKit
@testable import Graftty

@MainActor
struct RunnerInviteRedemptionTests {
    private final class Saved: @unchecked Sendable { var endpoints: [TailcatEndpoint] = [] }

    @MainActor private struct Fixture {
        let root = URL.temporaryDirectory.appendingPathComponent("runner-invite-\(UUID())")
        let saved = Saved()
        var pins: PinnedHostStore { PinnedHostStore(directory: root.appendingPathComponent("pins")) }
        func model() async -> RemoteMacsModel {
            let model = RemoteMacsModel(store: RemoteMacStore(storeURL: root.appendingPathComponent("remotes.json")))
            await model.loadSavedRemotes()
            return model
        }
        func redemption() -> RunnerInviteRedemption {
            let saved = saved
            return RunnerInviteRedemption(pinnedHostStore: pins, saveTailcatEndpoint: { endpoint, _ in saved.endpoints.append(endpoint) })
        }
    }

    private static func identity(name: String = "Build Box", keyByte: UInt8 = 4) -> LinuxHostIdentity {
        LinuxHostIdentity(deviceID: "runner-id", displayName: name,
                          publicKey: Data(repeating: keyByte, count: 32).base64EncodedString(), port: 8801)
    }

    @Test("@spec REMOTE-33.18: When the user adds a runner with an invite, the application shall pin the invite key and save the runner with the Tailcat transport and no OpenSSH destination.")
    func savesInvitedRunner() async throws {
        let fixture = Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let model = await fixture.model()
        let endpoint = TailcatEndpoint(address: "fixture", port: 8801)
        let remote = try fixture.redemption().save(identity: Self.identity(), endpoint: endpoint, model: model)
        #expect(remote.transport == .tailcat)
        #expect(remote.maintenanceDestination == nil)
        #expect(remote.directEndpoint == nil)
        #expect(fixture.saved.endpoints == [endpoint])
        #expect(try fixture.pins.get(id: remote.id)?.kind == .linux)
        #expect(try fixture.pins.get(id: remote.id)?.publicKey.rawRepresentation == Data(repeating: 4, count: 32))
    }

    @Test("@spec REMOTE-33.19: When an invite names a runner already saved with the same key, the application shall replace the saved entry; if the key differs, then the application shall refuse it.")
    func replacesSameKeyAndRefusesChangedKey() async throws {
        let fixture = Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let model = await fixture.model()
        let endpoint = TailcatEndpoint(address: "fixture", port: 8801)
        _ = try fixture.redemption().save(identity: Self.identity(), endpoint: endpoint, model: model)
        _ = try fixture.redemption().save(identity: Self.identity(name: "Renamed"), endpoint: endpoint, model: model)
        #expect(model.savedRemoteMacs.count == 1)
        #expect(model.savedRemoteMacs.first?.label == "Renamed")
        #expect(throws: LinuxHostSetupError.self) {
            try fixture.redemption().save(identity: Self.identity(keyByte: 5), endpoint: endpoint, model: model)
        }
        #expect(model.savedRemoteMacs.count == 1)
    }
}
