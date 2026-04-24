#if canImport(UIKit)
import Foundation
import Observation

/// CRUD store for saved hosts, persisted as a single JSON file in the
/// app's Application Support directory. SSH private keys and host-key
/// pins do not live here; they belong in Keychain entries keyed separately
/// from this non-secret host metadata.
@Observable
@MainActor
public final class HostStore {

    public enum StoreError: Error, Equatable {
        case io(String)
    }

    public private(set) var hosts: [Host] = []

    private let storeURL: URL

    public init(storeURL: URL = HostStore.defaultStoreURL()) {
        self.storeURL = storeURL
        hosts = (try? readAll()) ?? []
    }

    /// `~/Library/Application Support/<bundleID>/hosts.json`. Falls back to
    /// a temp path if the directory can't be created (unlikely on iOS).
    public nonisolated static func defaultStoreURL() -> URL {
        let fm = FileManager.default
        let base = (try? fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? fm.temporaryDirectory
        let dir = base.appendingPathComponent(
            Bundle.main.bundleIdentifier ?? "net.graftty.GrafttyMobile",
            isDirectory: true
        )
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("hosts.json")
    }

    public func add(_ host: Host) throws {
        var next = hosts
        // Dedupe by normalized baseURL first (belt-and-suspenders against
        // the scanner firing twice before the Save sheet dismisses). If a
        // host with the same URL exists, refresh its timestamp + label
        // rather than inserting a duplicate under a new UUID.
        if let incomingURL = host.directBaseURL,
           let idx = next.firstIndex(where: { existing in
               guard let existingURL = existing.directBaseURL else { return false }
               return Self.sameURL(existingURL, incomingURL)
           }) {
            var existing = next[idx]
            existing.label = host.label
            existing.lastUsedAt = Date()
            next[idx] = existing
        } else if let idx = next.firstIndex(where: { $0.id == host.id }) {
            next[idx] = host
        } else {
            next.append(host)
        }
        try write(next)
    }

    /// URLs compare case-insensitively on scheme/host and pass-through on
    /// path/port. `http://Mac.local:8799/` and `http://mac.local:8799`
    /// address the same server.
    private static func sameURL(_ a: URL, _ b: URL) -> Bool {
        (a.scheme?.lowercased() ?? "") == (b.scheme?.lowercased() ?? "")
            && (a.host?.lowercased() ?? "") == (b.host?.lowercased() ?? "")
            && (a.port ?? -1) == (b.port ?? -1)
    }

    public func update(_ host: Host) throws {
        var next = hosts
        guard let idx = next.firstIndex(where: { $0.id == host.id }) else {
            throw StoreError.io("no host with id \(host.id)")
        }
        next[idx] = host
        try write(next)
    }

    public func delete(_ id: UUID) throws {
        let next = hosts.filter { $0.id != id }
        try write(next)
    }

    public func deleteAll() throws {
        try write([])
    }

    private func write(_ list: [Host]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            let data = try encoder.encode(list)
            try data.write(to: storeURL, options: [.atomic])
            hosts = sorted(list)
        } catch {
            throw StoreError.io("\(error)")
        }
    }

    private func readAll() throws -> [Host] {
        guard FileManager.default.fileExists(atPath: storeURL.path) else { return [] }
        let data = try Data(contentsOf: storeURL)
        let list = try JSONDecoder().decode([Host].self, from: data)
        return sorted(list)
    }

    private func sorted(_ list: [Host]) -> [Host] {
        list.sorted { ($0.lastUsedAt ?? $0.addedAt) > ($1.lastUsedAt ?? $1.addedAt) }
    }
}

private extension Host {
    var directBaseURL: URL? {
        if case .directHTTP(let baseURL) = transport { return baseURL }
        return nil
    }
}
#endif
