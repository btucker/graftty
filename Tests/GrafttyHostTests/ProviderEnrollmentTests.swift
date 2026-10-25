import Foundation
import Testing
import GrafttyKit
import GrafttyProtocol
@testable import GrafttyHost

struct ProviderEnrollmentTests {
    @Test func hostCommandIsRegisteredAndRequiresStdin() throws {
        _ = try GrafttyHostCommand.parseAsRoot(["enroll-parent", "--stdin", "--state-directory", "/tmp/host-state"])
        #expect(throws: (any Error).self) { _ = try GrafttyHostCommand.parseAsRoot(["enroll-parent"]) }
    }

    @Test func existingHostIdentityAndParentTrustSurviveRetriesWithoutExportingPrivateKey() async throws {
        let root = URL(fileURLWithPath: "/tmp/enroll-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let config = HostConfiguration(stateDirectory: root, runtimeDirectory: root)
        let parent = LinuxHostTrustRequest(deviceID: "parent", displayName: "Mac", publicKey: Data(repeating: 9, count: 32).base64EncodedString(), serverPublicKey: Data(repeating: 8, count: 32).base64EncodedString())
        let request = ProviderHostEnrollmentRequest(operationID: UUID(), parent: parent)
        #expect(throws: (any Error).self) { _ = try ProviderHostEnrollment.accept(request, configuration: config) }
        let identity = try #require(try await HostSetup.prepare(configuration: config))
        let first = try ProviderHostEnrollment.accept(request, configuration: config)
        #expect(first.identity == identity)
        let second = try ProviderHostEnrollment.accept(request, configuration: config)
        #expect(first == second)
        let encoded = String(decoding: try JSONEncoder().encode(first), as: UTF8.self)
        #expect(!encoded.contains("privateKey"))
        let peers = TrustedPeerStore(directory: config.identityDirectory)
        let peer = try #require(try peers.get(id: .init(value: parent.deviceID)))
        #expect(peer.capabilities.terminalControl == .allowed)
        #expect(peer.capabilities.worktreeManagement == .allowed)
        #expect(peer.capabilities.replication == .disabled)
        let changed = ProviderHostEnrollmentRequest(operationID: UUID(), parent: .init(deviceID: parent.deviceID,
            displayName: parent.displayName, publicKey: Data(repeating: 7, count: 32).base64EncodedString(), serverPublicKey: parent.serverPublicKey))
        #expect(throws: (any Error).self) { _ = try ProviderHostEnrollment.accept(changed, configuration: config) }
        #expect(try peers.get(id: peer.id)?.publicKey == peer.publicKey)
        let changedServer = ProviderHostEnrollmentRequest(operationID: UUID(), parent: .init(deviceID: parent.deviceID,
            displayName: parent.displayName, publicKey: parent.publicKey, serverPublicKey: Data(repeating: 7, count: 32).base64EncodedString()))
        #expect(throws: (any Error).self) { _ = try ProviderHostEnrollment.accept(changedServer, configuration: config) }
        try peers.remove(id: peer.id)
        #expect(throws: (any Error).self) { _ = try ProviderHostEnrollment.accept(request, configuration: config) }
        #expect(try peers.list().isEmpty)
    }
}
