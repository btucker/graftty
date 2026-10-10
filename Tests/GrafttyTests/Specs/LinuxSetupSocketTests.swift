import Foundation
import Testing
import GrafttyProtocol
import GrafttyRemoteClient
@testable import GrafttyKit
@testable import Graftty

@MainActor
struct LinuxSetupSocketTests {
    @Test("@spec REMOTE-21.23: When the local CLI provisions a Linux host, the socket protocol shall carry only the public client identity and the complete setup result, rejecting invalid SSH destinations.")
    func wireRoundTripsPublicIdentityAndResult() throws {
        let result = try result()
        for request in [NotificationMessage.linuxSetupIdentity, .completeLinuxSetup(result)] {
            #expect(request.expectsResponse)
            let bytes = try JSONEncoder().encode(request)
            #expect(try JSONDecoder().decode(NotificationMessage.self, from: bytes) == request)
            #expect(!String(decoding: bytes, as: UTF8.self).contains("privateKey"))
        }
        let identity = LinuxHostTrustRequest(deviceID: "mac-id", displayName: "Mac", publicKey: Data(repeating: 2, count: 32).base64EncodedString())
        let response = ResponseMessage.linuxSetupIdentity(identity)
        #expect(try JSONDecoder().decode(ResponseMessage.self, from: JSONEncoder().encode(response)) == response)
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(LinuxHostDestination.self, from: Data(#"{"value":"-oProxyCommand=bad"}"#.utf8))
        }
    }

    @Test("@spec REMOTE-21.24: When Linux setup is completed through the CLI or UI, the shared save operation shall persist its direct endpoint and reject changed device or endpoint identities before mutating trust.")
    func sharedSavePreservesConflictChecks() async throws {
        let root = URL.temporaryDirectory.appendingPathComponent("linux-socket-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let pins = PinnedHostStore(directory: root.appendingPathComponent("pins"))
        let model = RemoteMacsModel(store: RemoteMacStore(storeURL: root.appendingPathComponent("remotes.json")))
        await model.loadSavedRemotes()
        let controller = LinuxHostSetupConnectionController(pinnedHostStore: pins)
        let saved = try controller.save(result(), model: model)
        #expect(saved.transport == .directSSH)
        #expect(saved.directEndpoint?.host == "192.0.2.2")
        #expect(saved.directEndpoint?.port == 8801)
        #expect(try pins.get(id: saved.id)?.kind == .linux)
        let oldPins = try pins.list()
        for changed in [try result(key: 2), try result(device: "replacement", key: 2)] {
            #expect(throws: LinuxHostSetupError.self) { try controller.save(changed, model: model) }
            #expect(try pins.list() == oldPins)
            #expect(model.savedRemoteMacs == [saved])
        }
        let otherModel = RemoteMacsModel(store: RemoteMacStore(storeURL: root.appendingPathComponent("other-remotes.json")))
        await otherModel.loadSavedRemotes()
        // Endpoint normalization must agree with the pin comparison even when
        // the saved-remotes file is empty and only the pin file remains.
        #expect(throws: LinuxHostSetupError.self) {
            try controller.save(result(device: "replacement", key: 2, hostname: "192.0.2.2 "), model: otherModel)
        }
        #expect(try pins.list() == oldPins)
        #expect(otherModel.savedRemoteMacs.isEmpty)
        // Saved remote identity remains authoritative if its pin file is lost.
        try FileManager.default.removeItem(at: root.appendingPathComponent("pins"))
        #expect(throws: LinuxHostSetupError.self) { try controller.save(result(key: 2), model: model) }
        #expect(try pins.list().isEmpty)
        #expect(model.savedRemoteMacs == [saved])
    }

    private func result(device: String = "linux-id", key: UInt8 = 1, hostname: String = "192.0.2.2") throws -> LinuxHostSetupResult {
        LinuxHostSetupResult(identity: .init(deviceID: device, displayName: "Linux", publicKey: Data(repeating: key, count: 32).base64EncodedString(), port: 8801), openSSH: try .parse("hostname \(hostname)\nuser alice\nport 2222\n"), destination: try .init("linux-alias"), projectPaths: ["/home/alice/project"])
    }
}
