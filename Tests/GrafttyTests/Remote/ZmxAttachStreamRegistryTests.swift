import Foundation
import Testing
@testable import Graftty
@testable import GrafttyKit

@Suite("ZmxAttachStream — RemoteAttachmentRegistry wiring")
struct ZmxAttachStreamRegistryTests {
    @Test("ZmxAttachStream shall register with the RemoteAttachmentRegistry when the attach process spawns and deregister exactly once on close (TERM-11.5).")
    func registersAttachOnSpawnAndDetachOnClose() async throws {
        let registry = RemoteAttachmentRegistry()
        let stream = try ZmxAttachStream(
            zmxExecutable: URL(fileURLWithPath: "/bin/cat"),
            zmxDir: URL(fileURLWithPath: "/tmp"),
            sessionName: "ssh-reg-test",
            workingDirectory: nil,
            attachmentRegistry: registry
        )
        #expect(registry.isRemoteAttached(sessionName: "ssh-reg-test"))

        // A second client under the same name makes a double-detach
        // observable (it would drop this count to zero).
        registry.attach(sessionName: "ssh-reg-test")

        await stream.close()
        #expect(registry.isRemoteAttached(sessionName: "ssh-reg-test"))

        await stream.close()   // idempotent: must not detach again
        #expect(registry.isRemoteAttached(sessionName: "ssh-reg-test"))

        registry.detach(sessionName: "ssh-reg-test")
        #expect(!registry.isRemoteAttached(sessionName: "ssh-reg-test"))
    }

    @Test("ZmxAttachStream init failure shall leave the registry untouched (TERM-11.5).")
    func spawnFailureDoesNotRegister() {
        let registry = RemoteAttachmentRegistry()
        #expect(throws: Error.self) {
            _ = try ZmxAttachStream(
                zmxExecutable: URL(fileURLWithPath: "/nonexistent-zmx-binary"),
                zmxDir: URL(fileURLWithPath: "/tmp"),
                sessionName: "ssh-fail-test",
                workingDirectory: nil,
                attachmentRegistry: registry
            )
        }
        #expect(!registry.isRemoteAttached(sessionName: "ssh-fail-test"))
    }
}
