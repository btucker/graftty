import Foundation
import Testing
@testable import GrafttyProtocol

private final class CorruptListReadGate: @unchecked Sendable {
    let entered: AsyncStream<Void>
    let continuation: AsyncStream<Void>.Continuation
    let release = DispatchSemaphore(value: 0)

    init() { (entered, continuation) = AsyncStream.makeStream() }
}

private final class CorruptListReadGates: @unchecked Sendable {
    static let shared = CorruptListReadGates()
    private let lock = NSLock()
    private var gates: [String: CorruptListReadGate] = [:]
    func insert(_ gate: CorruptListReadGate, for name: String) { lock.withLock { gates[name] = gate } }
    func remove(_ name: String) { _ = lock.withLock { gates.removeValue(forKey: name) } }
    func gate(for name: String) -> CorruptListReadGate? { lock.withLock { gates[name] } }
}

private struct GatedListRow: Codable, Sendable, Equatable {
    let name: String
    init(_ name: String) { self.name = name }

    init(from decoder: Decoder) throws {
        name = try decoder.singleValueContainer().decode(String.self)
        if let gate = CorruptListReadGates.shared.gate(for: name) {
            gate.continuation.yield(())
            gate.release.wait()
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Invalid row"))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(name)
    }
}

@Suite("ObservableListStore")
@MainActor
struct ObservableListStoreTests {
    private final class ReadControl: @unchecked Sendable {
        private let lock = NSLock()
        private var denied = true
        func allow() { lock.withLock { denied = false } }
        func read(_ url: URL) throws -> Data {
            if lock.withLock({ denied }) { throw CocoaError(.fileReadNoPermission) }
            return try Data(contentsOf: url)
        }
    }

    @Test("@spec PERSIST-5.19: If an observable list encounters a non-decoding read error, then the application shall leave it unloaded and block writes until a later load succeeds so mutations retain the persisted rows.", arguments: [false, true], [false, true])
    func transientReadFailurePreservesList(asyncLoad: Bool, discard: Bool) async throws {
        let url = makeFileURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let original = JSONFileStore<[Row]>(fileURL: url)
        let saved = Row(name: "saved", rank: 1)
        let added = Row(name: "added", rank: 2)
        try original.save([saved])
        let bytes = try Data(contentsOf: url)
        let control = ReadControl()
        let store = ObservableListStore(
            file: JSONFileStore<[Row]>(fileURL: url, readData: { try control.read($0) }),
            corruptFile: discard ? .discard : .moveAside,
            areInIncreasingOrder: { $0.rank > $1.rank }
        )
        if asyncLoad { await store.loadIfNeeded() } else { store.ensureLoaded() }
        #expect(!store.hasLoaded)
        #expect(throws: CocoaError(.fileReadNoPermission)) { try store.write(store.elements + [added]) }
        #expect(try Data(contentsOf: url) == bytes)

        control.allow()
        // Restored read access alone cannot make a list built from empty safe to write.
        #expect(throws: CocoaError(.fileReadNoPermission)) { try store.write([added]) }
        #expect(try Data(contentsOf: url) == bytes)
        if asyncLoad { await store.loadIfNeeded() } else { store.ensureLoaded() }
        #expect(store.hasLoaded)
        #expect(store.elements == [saved])
        try store.write(store.elements + [added])
        #expect(try original.load() == [saved, added])
        #expect(store.elements == [added, saved])
        #expect(try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path) == ["rows.json"])
    }

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
        let unloaded = makeStore(blocker.appendingPathComponent("rows.json"))
        #expect(throws: (any Error).self) { try unloaded.write([Row(name: "a", rank: 1)]) }
        #expect(!unloaded.hasLoaded)

        let store = makeStore(blocker.appendingPathComponent("rows.json"))
        store.ensureLoaded()
        #expect(throws: (any Error).self) { try store.write([Row(name: "a", rank: 1)]) }
        #expect(store.elements.isEmpty)
    }

    @Test("a successful write marks the store loaded so a pending load cannot replace it")
    func writeMarksLoaded() async throws {
        let url = makeFileURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try makeStore(url).write([Row(name: "old", rank: 1)])

        let store = makeStore(url)
        try store.write([Row(name: "new", rank: 2)])
        #expect(store.hasLoaded)
        await store.loadIfNeeded()
        #expect(store.elements.map(\.name) == ["new"])
    }

    @Test("@spec PERSIST-5.11: When an asynchronous list load finishes after a successful write, the application shall preserve the written file rather than archive it as corrupt.")
    func staleCorruptLoadCannotArchiveNewWrite() async throws {
        let url = makeFileURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let file = JSONFileStore<[GatedListRow]>(fileURL: url)
        let gate = CorruptListReadGate()
        let corruptName = UUID().uuidString
        CorruptListReadGates.shared.insert(gate, for: corruptName)
        var released = false
        defer {
            if !released { gate.release.signal() }
            CorruptListReadGates.shared.remove(corruptName)
        }
        try file.save([GatedListRow(corruptName)])
        let store = ObservableListStore(file: file, corruptFile: .moveAside,
            areInIncreasingOrder: { $0.name < $1.name })
        let loading = Task { await store.loadIfNeeded() }
        var events = gate.entered.makeAsyncIterator()
        _ = await events.next()

        let fresh = [GatedListRow("fresh")]
        try store.write(fresh)
        gate.release.signal()
        released = true
        await loading.value

        #expect(store.elements == fresh)
        #expect(try file.load() == fresh)
        #expect(try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path) == ["rows.json"])
    }
}
