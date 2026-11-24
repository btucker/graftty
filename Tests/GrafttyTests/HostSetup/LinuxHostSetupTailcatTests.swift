import Foundation
import Testing
import GrafttyProtocol
import GrafttyRemoteClient
@testable import GrafttyKit
@testable import Graftty

@MainActor
struct LinuxHostSetupTailcatTests {
    private final class Saved: @unchecked Sendable {
        var endpoints: [TailcatEndpoint] = []
    }

    private func save(tailcat: TailcatEndpoint?, supportsTailcat: Bool? = nil) async throws -> (RemoteMac, Saved) {
        let root = URL.temporaryDirectory.appendingPathComponent("linux-tailcat-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let model = RemoteMacsModel(store: RemoteMacStore(storeURL: root.appendingPathComponent("remotes.json")))
        await model.loadSavedRemotes()
        let saved = Saved()
        let controller = LinuxHostSetupConnectionController(pinnedHostStore: PinnedHostStore(directory: root.appendingPathComponent("pins")),
                                                            saveTailcatEndpoint: { endpoint, _ in saved.endpoints.append(endpoint) })
        let result = LinuxHostSetupResult(identity: .init(deviceID: "linux-id", displayName: "Ubuntu",
            publicKey: Data(repeating: 1, count: 32).base64EncodedString(), port: 8801, tailcatEndpoint: tailcat,
            supportsTailcat: supportsTailcat),
            openSSH: try .parse("hostname 192.0.2.2\nuser alice\nport 2222\n"), destination: try .init("linux-alias"), projectPaths: [])
        return (try controller.save(result, model: model), saved)
    }

    @Test("@spec REMOTE-33.16: When SSH setup finishes on a runner that reports a Tailcat endpoint, the application shall save the runner with the Tailcat transport and keep its OpenSSH destination for updates.")
    func savesTailcatRunner() async throws {
        let endpoint = TailcatEndpoint(address: "fixture", port: 8801)
        let (remote, saved) = try await save(tailcat: endpoint)
        #expect(remote.transport == .tailcat)
        #expect(remote.maintenanceDestination?.value == "linux-alias")
        #expect(saved.endpoints == [endpoint])
        let json = String(decoding: try JSONEncoder().encode(remote), as: UTF8.self)
        #expect(!json.contains("fixture"))
    }

    @Test("@spec REMOTE-33.17: When SSH setup finishes on a runner that reports no Tailcat endpoint, the application shall save it with direct SSH.")
    func savesDirectRunnerFromOlderArchive() async throws {
        let (remote, saved) = try await save(tailcat: nil)
        #expect(remote.transport == .directSSH)
        #expect(saved.endpoints.isEmpty)
    }

    @Test("@spec REMOTE-33.24: If a runner that supports Tailcat reports no Tailcat endpoint at setup, then the application shall fail setup without saving the runner.")
    func refusesTailcatRunnerWithoutEndpoint() async throws {
        await #expect(throws: LinuxHostSetupError.self) { _ = try await save(tailcat: nil, supportsTailcat: true) }
    }
}
