import Foundation
import GrafttyProtocol

/// Downloads only an offered ID. Host paths never become mobile cache paths.
enum FilePreviewDownload {
    enum Failure: LocalizedError {
        case invalidOffer, invalidChunk
        var errorDescription: String? {
            switch self {
            case .invalidOffer: "This file cannot be previewed."
            case .invalidChunk: "The file download was interrupted. Try opening it again."
            }
        }
    }

    static func download(
        _ offer: RemoteOpenOffer,
        read: (Int) async throws -> Data
    ) async throws -> URL {
        guard offer.url == nil, (0...RemoteOpenOffer.maxBytes).contains(offer.byteCount),
              !offer.filename.isEmpty, offer.filename != ".", offer.filename != "..",
              !offer.filename.contains("/"),
              !offer.filename.contains("\0") else { throw Failure.invalidOffer }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("graftty-preview-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let file = directory.appendingPathComponent(offer.filename)
        do {
            try Data().write(to: file)
            let handle = try FileHandle(forWritingTo: file)
            defer { try? handle.close() }
            var offset = 0
            while offset < offer.byteCount {
                try Task.checkCancellation()
                let chunk = try await read(offset)
                guard !chunk.isEmpty, chunk.count <= RemoteOpenOffer.chunkBytes,
                      chunk.count <= offer.byteCount - offset else { throw Failure.invalidChunk }
                try Task.checkCancellation()
                try handle.write(contentsOf: chunk)
                offset += chunk.count
            }
            try Task.checkCancellation()
            return file
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    static func download(_ offers: [RemoteOpenOffer], read: (RemoteOpenOffer, Int) async throws -> Data) async throws -> [URL] {
        guard (1...20).contains(offers.count),
              offers.allSatisfy({ (0...RemoteOpenOffer.maxBytes).contains($0.byteCount) }),
              offers.reduce(0, { $0 + $1.byteCount }) <= 50 * 1024 * 1024 else { throw Failure.invalidOffer }
        var files: [URL] = []
        do {
            for offer in offers {
                let file = try await download(offer) { offset in try await read(offer, offset) }
                files.append(file)
            }
            return files
        } catch {
            files.forEach(remove)
            throw error
        }
    }

    static func remove(_ file: URL) {
        try? FileManager.default.removeItem(at: file.deletingLastPathComponent())
    }
}
