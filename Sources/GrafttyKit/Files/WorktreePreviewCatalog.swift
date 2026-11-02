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
                          paneSessionName: String) throws -> [RemoteOpenOffer] {
        try load()
        guard (1...FilePreviewLoader.maximumFiles).contains(snapshots.count),
              snapshots.allSatisfy({ (0...RemoteOpenOffer.maxBytes).contains($0.bytes.count) }),
              snapshots.reduce(0, { $0 + $1.bytes.count }) <= FilePreviewLoader.maximumTotalBytes else {
            throw FilePreviewLoader.Failure.invalidCollection
        }
        guard snapshots.allSatisfy({ !$0.filename.isEmpty && $0.filename != "." && $0.filename != ".."
            && !$0.filename.contains("/") && !$0.filename.contains("\0") }) else { throw FilePreviewLoader.Failure.unreadable }
        let group = UUID()
        let offers = snapshots.map {
            RemoteOpenOffer(id: UUID(), filename: $0.filename, byteCount: $0.bytes.count,
                paneSessionName: paneSessionName, previewKind: "file",
                previewGroupID: group)
        }
        let record = Record(worktree: worktree, offers: offers)
        if let directory {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            do {
                for (offer, snapshot) in zip(offers, snapshots) {
                    try snapshot.bytes.write(to: directory.appendingPathComponent(offer.id.uuidString), options: .atomic)
                }
                try JSONEncoder().encode(records + [record]).write(to: directory.appendingPathComponent("index.json"), options: .atomic)
            } catch {
                for offer in offers { try? FileManager.default.removeItem(at: directory.appendingPathComponent(offer.id.uuidString)) }
                throw error
            }
        } else {
            for (offer, snapshot) in zip(offers, snapshots) { memory[offer.id] = snapshot.bytes }
        }
        records.append(record)
        return offers
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
            let handle = try FileHandle(forReadingFrom: directory.appendingPathComponent(id.uuidString))
            defer { try? handle.close() }
            try handle.seek(toOffset: UInt64(offset))
            return try handle.read(upToCount: min(RemoteOpenOffer.chunkBytes, offer.byteCount - offset)) ?? Data()
        }
        guard let bytes = memory[id] else { throw RemoteOpenStore.Failure.expired }
        return bytes.subdata(in: offset..<min(bytes.count, offset + RemoteOpenOffer.chunkBytes))
    }
}
