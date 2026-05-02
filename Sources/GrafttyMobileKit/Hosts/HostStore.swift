#if canImport(UIKit)
import Foundation
import Observation

/// CRUD store for saved hosts, persisted as a single JSON file in the
/// app's Application Support directory. File-backed rather than
/// Keychain-backed because:
///   1. Hosts don't contain secrets — URL + user label + timestamps;
///   2. iOS-simulator Keychain access is contingent on a code-sign
///      context that the simulator refuses to grant to ad-hoc builds
///      without a DEVELOPMENT_TEAM, making Keychain a dev-workflow
///      foot-gun here.
/// If a future field does store a secret (token, cookie), it should be
/// split into a keyed Keychain item keyed by Host.id and fetched
/// separately — not mixed into this store.
@Observable
@MainActor
public final class HostStore {

    public enum StoreError: Error, Equatable {
        case io(String)
    }

    public private(set) var hosts: [Host] = []

    /// Distinguishes "loaded, zero hosts" from "load not yet completed",
    /// so the picker can suppress its empty-state copy during the brief
    /// pre-load window.
    public private(set) var hasLoaded: Bool = false

    private let storeURL: URL

    public init(storeURL: URL = HostStore.defaultStoreURL()) {
        self.storeURL = storeURL
        // No I/O here. `init` runs at `@State` construction on the iOS
        // launch path; eager file read would block first-frame commit.
    }

    /// Pure URL composition — safe to evaluate at `@State` default-init
    /// time. Parent directory is created lazily on first `write(_:)`.
    public nonisolated static func defaultStoreURL() -> URL {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fm.temporaryDirectory
        let dir = base.appendingPathComponent(
            Bundle.main.bundleIdentifier ?? "net.graftty.GrafttyMobile",
            isDirectory: true
        )
        return dir.appendingPathComponent("hosts.json")
    }

    /// Idempotent. Call from a SwiftUI `.task` so the JSON read runs
    /// after the first frame commits.
    public func loadIfNeeded() async {
        guard !hasLoaded else { return }
        let url = storeURL
        let loaded = await Task.detached(priority: .userInitiated) {
            HostStore.readSync(from: url)
        }.value
        guard !hasLoaded else { return }
        hosts = sorted(loaded)
        hasLoaded = true
    }

    /// Sync fallback for mutations that race ahead of the async load.
    /// Without it, the mutation would build `next` from an empty `hosts`
    /// and clobber the persisted file. No-op when already loaded.
    private func ensureLoaded() {
        guard !hasLoaded else { return }
        hosts = sorted(HostStore.readSync(from: storeURL))
        hasLoaded = true
    }

    public func add(_ host: Host) throws {
        ensureLoaded()
        var next = hosts
        // Dedupe by normalized baseURL first (belt-and-suspenders against
        // the scanner firing twice before the Save sheet dismisses). If a
        // host with the same URL exists, refresh its timestamp + label
        // rather than inserting a duplicate under a new UUID.
        if let idx = next.firstIndex(where: { Self.sameURL($0.baseURL, host.baseURL) }) {
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
        ensureLoaded()
        var next = hosts
        guard let idx = next.firstIndex(where: { $0.id == host.id }) else {
            throw StoreError.io("no host with id \(host.id)")
        }
        next[idx] = host
        try write(next)
    }

    public func delete(_ id: UUID) throws {
        ensureLoaded()
        let next = hosts.filter { $0.id != id }
        try write(next)
    }

    public func deleteAll() throws {
        ensureLoaded()
        try write([])
    }

    private func write(_ list: [Host]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            let data = try encoder.encode(list)
            // Lazy mkdir keeps `defaultStoreURL()` pure on the launch path.
            try FileManager.default.createDirectory(
                at: storeURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: storeURL, options: [.atomic])
            hosts = sorted(list)
        } catch {
            throw StoreError.io("\(error)")
        }
    }

    nonisolated private static func readSync(from url: URL) -> [Host] {
        // `Data(contentsOf:)` returns nil through `try?` for a missing
        // file, so a `fileExists` pre-check would just be a wasted stat.
        guard let data = try? Data(contentsOf: url),
              let list = try? JSONDecoder().decode([Host].self, from: data)
        else { return [] }
        return list
    }

    private func sorted(_ list: [Host]) -> [Host] {
        list.sorted { ($0.lastUsedAt ?? $0.addedAt) > ($1.lastUsedAt ?? $1.addedAt) }
    }
}
#endif
