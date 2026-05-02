#if canImport(UIKit)
import Foundation
import Testing
@testable import GrafttyMobileKit

@Suite
@MainActor
struct HostStoreTests {

    private func tempStoreURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("graftty-host-test-\(UUID().uuidString).json")
    }

    private func makeStore(at url: URL? = nil) -> (HostStore, URL) {
        let u = url ?? tempStoreURL()
        return (HostStore(storeURL: u), u)
    }

    @Test
    func startsEmpty() throws {
        let (store, _) = makeStore()
        #expect(store.hosts.isEmpty)
        #expect(store.hasLoaded == false)
    }

    @Test("""
@spec IOS-2.5: `HostStore.init` shall not perform filesystem I/O — neither reading `hosts.json` nor creating its parent directory. The picker view shall populate the store by `await store.loadIfNeeded()` from a SwiftUI `.task` modifier, so the JSON read + decode runs after the first frame commits rather than during view-tree construction on the launch path. While `store.hasLoaded` is false, `HostPickerView` shall suppress the "No saved hosts yet." copy so a user with persisted hosts does not see a flicker of the empty-state text in the brief window between view appearance and the detached read landing back on the main actor. Mutations (`add` / `update` / `delete` / `deleteAll`) shall guard with a synchronous `ensureLoaded()` fallback so a user-initiated mutation that races ahead of the async load cannot overwrite persisted state with an empty `next` list. The `~/Library/Application Support/<bundleID>/` parent directory shall be created lazily on first `write(_:)` (idempotent `createDirectory(withIntermediateDirectories:)`), so a launch that performs no mutation makes no directory-creation syscalls.
""")
    func initDoesNotReadFromDisk() async throws {
        let url = tempStoreURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let prepop = HostStore(storeURL: url)
        let h = Host(label: "mac", baseURL: URL(string: "http://mac:8799/")!)
        try prepop.add(h)

        let store = HostStore(storeURL: url)
        #expect(store.hasLoaded == false)
        #expect(store.hosts.isEmpty)

        await store.loadIfNeeded()
        #expect(store.hasLoaded)
        #expect(store.hosts.map(\.id) == [h.id])
    }

    @Test
    func mutationBeforeAsyncLoadPreservesPersistedHosts() async throws {
        let url = tempStoreURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let existing = Host(label: "mac", baseURL: URL(string: "http://mac:8799/")!)
        let added = Host(label: "ipad", baseURL: URL(string: "http://ipad:8799/")!)
        try HostStore(storeURL: url).add(existing)

        let store = HostStore(storeURL: url)
        try store.add(added)
        await store.loadIfNeeded()

        #expect(store.hosts.map(\.id).contains(existing.id))
        #expect(store.hosts.map(\.id).contains(added.id))
    }

    /// `.task` can re-fire on view re-creation; the second load must
    /// not re-read the file.
    @Test
    func loadIfNeededIsIdempotent() async throws {
        let (store, url) = makeStore()
        defer { try? FileManager.default.removeItem(at: url) }
        await store.loadIfNeeded()
        await store.loadIfNeeded()
        #expect(store.hasLoaded)
    }

    @Test
    func addPersistsAcrossInstances() async throws {
        let url = tempStoreURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let h = Host(label: "mac", baseURL: URL(string: "http://mac.ts.net:8799/")!)
        do {
            let store = HostStore(storeURL: url)
            try store.add(h)
            #expect(store.hosts.count == 1)
            #expect(store.hosts.first == h)
        }
        let other = HostStore(storeURL: url)
        await other.loadIfNeeded()
        #expect(other.hosts.count == 1)
        #expect(other.hosts.first == h)
    }

    @Test
    func updateReplacesMatchingId() throws {
        let (store, url) = makeStore()
        defer { try? FileManager.default.removeItem(at: url) }
        var h = Host(label: "mac", baseURL: URL(string: "http://mac:8799/")!)
        try store.add(h)
        h.label = "renamed"
        try store.update(h)
        #expect(store.hosts.first?.label == "renamed")
    }

    @Test
    func deleteRemovesById() throws {
        let (store, url) = makeStore()
        defer { try? FileManager.default.removeItem(at: url) }
        let a = Host(label: "a", baseURL: URL(string: "http://a:8799/")!)
        let b = Host(label: "b", baseURL: URL(string: "http://b:8799/")!)
        try store.add(a)
        try store.add(b)
        try store.delete(a.id)
        #expect(store.hosts.map(\.id) == [b.id])
    }
}
#endif
