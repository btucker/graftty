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
    }

    @Test
    func addPersistsAcrossInstances() throws {
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
