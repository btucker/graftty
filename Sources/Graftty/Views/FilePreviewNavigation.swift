import Foundation
import GrafttyKit
import GrafttyProtocol

/// The same file menu serves a detached window and a terminal tray.
@MainActor
struct FilePreviewNavigation {
    var worktreePath: String
    var worktreePaths: [String] = []
    var entries: [FilePreviewHistory.Entry] = []
    var catalog: [WorktreePreviewCollection] = []
    var canShowInTerminal = false
    var onSelectEntry: (FilePreviewHistory.Entry) -> Void = { _ in }
    var onOpenCollection: (WorktreePreviewCollection) -> Void = { _ in }
    var onSelectWorktree: (String) -> Void = { _ in }
    var onShowInTerminal: () -> Void = {}

    var choices: [Choice] {
        let localIDs = Set(entries.map(\.id))
        let combined = entries.map(Choice.session) + catalog.filter { !localIDs.contains($0.id) }.map(Choice.stored)
        // Old hosts supply no timestamp. Keep their library order stable.
        return combined.enumerated().sorted {
            let lhs = $0.element.createdAt ?? .distantPast
            let rhs = $1.element.createdAt ?? .distantPast
            return lhs == rhs ? $0.offset < $1.offset : lhs > rhs
        }.map(\.element)
    }

    enum Choice: Identifiable {
        case session(FilePreviewHistory.Entry)
        case stored(WorktreePreviewCollection)
        var id: UUID { switch self { case .session(let entry): entry.id; case .stored(let collection): collection.id } }
        var createdAt: Date? { switch self { case .session(let entry): entry.createdAt; case .stored(let collection): collection.createdAt } }
        var title: String { switch self { case .session(let entry): entry.menuTitle; case .stored(let collection): collection.menuTitle } }
    }
}

@MainActor
enum FilePreviewCollectionLoader {
    static func load(_ collection: WorktreePreviewCollection, sourceURLs: [URL?] = [],
                     request: (RemoteOpenRequest) async throws -> RemoteOpenResponse) async throws -> [FilePreviewFile] {
        guard (1...20).contains(collection.offers.count),
              collection.offers.allSatisfy({ (0...RemoteOpenOffer.maxBytes).contains($0.byteCount) }),
              collection.offers.reduce(0, { $0 + $1.byteCount }) <= FilePreviewLoader.maximumTotalBytes else {
            throw FilePreviewLoader.Failure.tooLarge
        }
        var files: [FilePreviewFile] = []
        for (index, offer) in collection.offers.enumerated() {
            var bytes = Data()
            while bytes.count < offer.byteCount {
                try Task.checkCancellation()
                guard case .chunk(let chunk) = try await request(.read(id: offer.id, offset: bytes.count)),
                      !chunk.isEmpty, chunk.count <= RemoteOpenOffer.chunkBytes,
                      chunk.count <= offer.byteCount - bytes.count else { throw RemoteOpenStore.Failure.invalidFile }
                bytes.append(chunk)
            }
            let snapshot = FilePreviewLoader.Snapshot(filename: offer.filename, bytes: bytes)
            let source = sourceURLs.indices.contains(index) ? sourceURLs[index] : nil
            files.append(try await Task.detached { try FilePreviewFile(snapshot, sourceURL: source) }.value)
        }
        try Task.checkCancellation()
        return files
    }
}
