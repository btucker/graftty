import Foundation
import Testing
import GrafttyProtocol
import GrafttyRemoteClient
@testable import GrafttyKit
@testable import Graftty

@MainActor
@Suite("@spec REMOTE-21.11: When Linux setup completes, the application shall pin the public identity obtained over authenticated OpenSSH and use the resolved hostname with the Graftty SSH port; if that identity conflicts with a saved device or endpoint, then the application shall reject it without replacing trust.")
struct LinuxHostSetupConnectionTests {
    @Test func pinsResultAndKeepsRuntimePort() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("linux-pin-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = PinnedHostStore(directory: root)
        let controller = LinuxHostSetupConnectionController(pinnedHostStore: store)
        let result = try makeResult(keyByte: 1)
        let prepared = try controller.accept(result, kind: .mac, knownRemotes: [])
        #expect(prepared.hostname == "192.0.2.2")
        #expect(prepared.port == 8801)
        #expect(prepared.port != result.openSSH.port)
        #expect(prepared.host.publicKey.rawRepresentation == Data(repeating: 1, count: 32))
        let persisted = try #require(try store.get(id: prepared.host.id))
        #expect(persisted.publicKey == prepared.host.publicKey)
        #expect(persisted.pairingURL == prepared.host.pairingURL)
        let again = try controller.accept(result, kind: .mac, knownRemotes: [RemoteMacIdentity(id: prepared.host.id, fingerprint: prepared.host.fingerprint)])
        #expect(again.host.pinnedAt == persisted.pinnedAt)
        #expect(try store.list().count == 1)
    }

    @Test func rejectsChangedKeyForDevice() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("linux-pin-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = PinnedHostStore(directory: root)
        let controller = LinuxHostSetupConnectionController(pinnedHostStore: store)
        let original = try controller.accept(makeResult(keyByte: 1), kind: .mac, knownRemotes: [])
        let persisted = try #require(try store.get(id: original.host.id))
        #expect(throws: LinuxHostSetupError.self) { try controller.accept(makeResult(keyByte: 2), kind: .mac, knownRemotes: []) }
        #expect(try store.get(id: original.host.id) == persisted)
    }

    @Test func rejectsChangedDeviceAtSavedEndpoint() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("linux-pin-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = PinnedHostStore(directory: root)
        let controller = LinuxHostSetupConnectionController(pinnedHostStore: store)
        let original = try controller.accept(makeResult(keyByte: 1), kind: .mac, knownRemotes: [])
        let known = RemoteMacIdentity(id: original.host.id, fingerprint: original.host.fingerprint)
        let persisted = try store.list()
        #expect(throws: LinuxHostSetupError.self) { try controller.accept(makeResult(device: "replacement", keyByte: 2), kind: .mac, knownRemotes: [known]) }
        #expect(try store.list() == persisted)
    }

    @Test func savedRemoteRejectsChangeEvenWithoutPinFile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("linux-pin-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = PinnedHostStore(directory: root)
        let controller = LinuxHostSetupConnectionController(pinnedHostStore: store)
        let key = try RemoteIdentityPublicKey(rawRepresentation: Data(repeating: 1, count: 32))
        let known = RemoteMacIdentity(id: .init(value: "linux-id"), fingerprint: .init(of: key))
        #expect(throws: LinuxHostSetupError.self) { try controller.accept(makeResult(keyByte: 2), kind: .mac, knownRemotes: [known]) }
        #expect(try store.list().isEmpty)
    }

    private func makeResult(device: String = "linux-id", keyByte: UInt8) throws -> LinuxHostSetupResult {
        LinuxHostSetupResult(identity: .init(deviceID: device, displayName: "Ubuntu", publicKey: Data(repeating: keyByte, count: 32).base64EncodedString(), port: 8801), openSSH: try .parse("hostname 192.0.2.2\nuser alice\nport 2222\n"), destination: try .init("ubuntu-alias"), projectPaths: ["/home/alice/app"])
    }
}
