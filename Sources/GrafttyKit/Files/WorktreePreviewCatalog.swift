import Foundation
import GrafttyProtocol

/// Host-owned snapshots, indexed by worktree rather than the current display owner.
/// Only opaque offer IDs cross the wire; filenames never become host paths.
struct WorktreePreviewCatalog {
    struct Record: Codable {
        let worktree: String
        let offers: [RemoteOpenOffer]
    }
    let directory: URL?
    private var records: [Record] = []
    private var memory: [UUID: Data] = [:]
    private var loaded = false

    init(directory: URL?) { self.directory = directory }

    mutating func load() throws {
        guard !loaded else { return }
        if let directory {
            let index = directory.appendingPathComponent("index.json")
            if FileManager.default.fileExists(atPath: index.path) {
                records = try JSONDecoder().decode([Record].self, from: Data(contentsOf: index))
            }
        }
        loaded = true
    }

    mutating func publish(_ snapshots: [FilePreviewLoader.Snapshot], worktree: String,
                          paneSessionName: String, now: Date) throws -> [RemoteOpenOffer] {
        try load()
        try validate(snapshots)
        let group = UUID()
        let offers = snapshots.map {
            RemoteOpenOffer(id: UUID(), filename: $0.filename, byteCount: $0.bytes.count,
                paneSessionName: paneSessionName, previewKind: "file",
                previewGroupID: group, createdAt: now)
        }
        let record = Record(worktree: worktree, offers: offers)
        if let directory {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            try commit(offers, snapshots: snapshots, index: records + [record], to: directory)
        } else {
            for (offer, snapshot) in zip(offers, snapshots) { memory[offer.id] = snapshot.bytes }
        }
        records.append(record)
        return offers
    }

    /// Replaces a collection's bytes under its existing identities. A client mid-download
    /// can still straddle a revision: its stale offsets fail if a file shrank, and otherwise
    /// it holds the older revision number, so its next poll fetches the collection again.
    mutating func revise(group: UUID, snapshots: [FilePreviewLoader.Snapshot], worktree: String) throws -> [RemoteOpenOffer] {
        try load()
        try validate(snapshots)
        guard let index = records.firstIndex(where: { $0.worktree == worktree && $0.offers.first?.previewGroupID == group }) else {
            throw RemoteOpenStore.Failure.expired
        }
        let current = records[index].offers
        guard current.map(\.filename) == snapshots.map(\.filename) else { throw FilePreviewLoader.Failure.invalidCollection }
        let revision = (current.first?.contentRevision ?? 0) + 1
        let offers = zip(current, snapshots).map { $0.revised(byteCount: $1.bytes.count, contentRevision: revision) }
        var revised = records
        revised[index] = Record(worktree: worktree, offers: offers)
        if let directory {
            try commit(offers, snapshots: snapshots, index: revised, to: directory)
            for offer in current { try? FileManager.default.removeItem(at: storedFile(for: offer, in: directory)) }
        } else {
            for (offer, snapshot) in zip(offers, snapshots) { memory[offer.id] = snapshot.bytes }
        }
        records = revised
        return offers
    }

    /// Each revision has its own files, so the index alone commits it and a failure
    /// at any step leaves the previous revision readable.
    private func storedFile(for offer: RemoteOpenOffer, in directory: URL) -> URL {
        directory.appendingPathComponent(offer.id.uuidString + (offer.contentRevision.map { ".\($0)" } ?? ""))
    }

    private func commit(_ offers: [RemoteOpenOffer], snapshots: [FilePreviewLoader.Snapshot],
                        index: [Record], to directory: URL) throws {
        do {
            for (offer, snapshot) in zip(offers, snapshots) {
                try snapshot.bytes.write(to: storedFile(for: offer, in: directory), options: .atomic)
            }
            try JSONEncoder().encode(index).write(to: directory.appendingPathComponent("index.json"), options: .atomic)
        } catch {
            for offer in offers { try? FileManager.default.removeItem(at: storedFile(for: offer, in: directory)) }
            throw error
        }
    }

    private func validate(_ snapshots: [FilePreviewLoader.Snapshot]) throws {
        guard (1...FilePreviewLoader.maximumFiles).contains(snapshots.count),
              snapshots.allSatisfy({ (0...RemoteOpenOffer.maxBytes).contains($0.bytes.count) }),
              snapshots.reduce(0, { $0 + $1.bytes.count }) <= FilePreviewLoader.maximumTotalBytes else {
            throw FilePreviewLoader.Failure.invalidCollection
        }
        guard snapshots.allSatisfy({ !$0.filename.isEmpty && $0.filename != "." && $0.filename != ".."
            && !$0.filename.contains("/") && !$0.filename.contains("\0") }) else { throw FilePreviewLoader.Failure.unreadable }
    }

    mutating func list(worktree: String) throws -> [RemoteOpenOffer] {
        try load()
        return records.filter { $0.worktree == worktree }.flatMap(\.offers)
    }

    mutating func read(id: UUID, worktree: String, offset: Int) throws -> Data? {
        try load()
        guard let offer = records.first(where: { $0.worktree == worktree && $0.offers.contains { $0.id == id } })?.offers.first(where: { $0.id == id }) else { return nil }
        guard (0...offer.byteCount).contains(offset) else { throw RemoteOpenStore.Failure.invalidOffset }
        if let directory {
            let handle = try FileHandle(forReadingFrom: storedFile(for: offer, in: directory))
            defer { try? handle.close() }
            try handle.seek(toOffset: UInt64(offset))
            return try handle.read(upToCount: min(RemoteOpenOffer.chunkBytes, offer.byteCount - offset)) ?? Data()
        }
        guard let bytes = memory[id] else { throw RemoteOpenStore.Failure.expired }
        return bytes.subdata(in: offset..<min(bytes.count, offset + RemoteOpenOffer.chunkBytes))
    }
}
