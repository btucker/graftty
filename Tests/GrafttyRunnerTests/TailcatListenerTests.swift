import Foundation
import GrafttyProtocol
import GrafttyTailcat
import Testing

@Suite("Tailcat listener state")
struct TailcatListenerStateFileTests {
    @Test("@spec REMOTE-33.2: When the runner saves its Tailcat listener state, the application shall write it to a file readable only by its owner.")
    func savesOwnerOnlyFile() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("identity/tailcat-listener.json")
        let store = TailcatListenerStateFile(url: url)
        #expect(try store.load() == nil)
        let state = TailcatListenerState(identity: try .generate(), address: "fixture-address-\(UUID().uuidString)")
        try store.save(state)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        let loaded = try #require(try store.load())
        #expect(loaded.address == state.address)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        #expect(try encoder.encode(loaded.identity) == encoder.encode(state.identity))
        #expect(!String(describing: loaded).contains(state.address))
    }
}

@Suite("Tailcat SSH listener")
struct TailcatSSHListenerTests {
    @Test("@spec REMOTE-33.3: When the Tailcat listener restarts with saved state, the application shall keep the same Tailcat address.",
          .timeLimit(.minutes(2)))
    func keepsAddressAcrossRestart() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = TailcatListenerStateFile(url: directory.appendingPathComponent("tailcat-listener.json"))
        let first = try await Self.endpoint(store: store)
        let second = try await Self.endpoint(store: store)
        #expect(first.address == second.address)
        #expect(first.port == 8801)
    }

    /// Runs a listener until it is ready, then stops it.
    private static func endpoint(store: TailcatListenerStateFile) async throws -> TailcatEndpoint {
        let (ready, continuation) = AsyncStream.makeStream(of: TailcatEndpoint.self)
        let listener = TailcatSSHListener(store: store, port: 8801) { _ in { } }
        let task = Task {
            defer { continuation.finish() }
            try await listener.run { continuation.yield($0) }
        }
        defer { task.cancel() }
        var iterator = ready.makeAsyncIterator()
        let endpoint = try #require(await iterator.next())
        task.cancel()
        _ = await task.result
        return endpoint
    }
}
