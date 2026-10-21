import Foundation
import Testing
@testable import GrafttyProtocol

@Suite("ObservableListStore")
@MainActor
struct ObservableListStoreTests {
    private struct Row: Codable, Sendable, Equatable {
        var name: String
        var rank: Int
    }

    private func makeFileURL() -> URL {
        URL.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("rows.json")
    }

    private func makeStore(
        _ url: URL,
        corruptFile: ObservableListStore<Row>.CorruptFilePolicy = .moveAside
    ) -> ObservableListStore<Row> {
        ObservableListStore(
            file: JSONFileStore(fileURL: url, outputFormatting: [.prettyPrinted, .sortedKeys]),
            corruptFile: corruptFile,
            isLoadable: { $0.rank >= 0 },
            areInIncreasingOrder: { $0.rank > $1.rank }
        )
    }

    @Test("@spec PERSIST-5.5: When an ObservableListStore is mutated before its asynchronous load completes, the application shall first load the persisted rows synchronously so the write builds on them instead of replacing them with an empty list.")
    func mutationBeforeLoadBuildsOnPersistedRows() async throws {
        let url = makeFileURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try makeStore(url).write([Row(name: "a", rank: 1), Row(name: "old", rank: -1)])

        let store = makeStore(url)
        #expect(!store.hasLoaded)
        store.ensureLoaded()
        try store.write(store.elements + [Row(name: "b", rank: 2)])
        #expect(store.elements.map(\.name) == ["b", "a"])

        let reloaded = makeStore(url)
        await reloaded.loadIfNeeded()
        #expect(reloaded.hasLoaded)
        #expect(reloaded.elements.map(\.name) == ["b", "a"])
    }

    @Test("@spec PERSIST-5.6: When an ObservableListStore reads malformed JSON, the application shall present an empty list and move the file aside only if the store's corrupt-file policy is moveAside.")
    func corruptFilePolicy() async throws {
        for policy in [ObservableListStore<Row>.CorruptFilePolicy.moveAside, .discard] {
            let url = makeFileURL()
            defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("{".utf8).write(to: url)

            let store = makeStore(url, corruptFile: policy)
            await store.loadIfNeeded()
            #expect(store.elements.isEmpty)
            let names = try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)
            switch policy {
            case .moveAside:
                #expect(names.count == 1)
                #expect(names.first?.hasPrefix("rows.json.corrupt.") == true)
            case .discard:
                #expect(names == ["rows.json"])
            }
        }
    }

    @Test("a failed write leaves the published elements unchanged")
    func failedWriteDoesNotPublish() throws {
        let blocker = makeFileURL().deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: blocker) }
        // A regular file where the store needs its parent directory.
        try Data().write(to: blocker)
        let store = makeStore(blocker.appendingPathComponent("rows.json"))
        store.ensureLoaded()

        #expect(throws: (any Error).self) { try store.write([Row(name: "a", rank: 1)]) }
        #expect(store.elements.isEmpty)
    }
}
