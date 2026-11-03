import Foundation
import Combine
import GrafttyKit
import GrafttyProtocol

/// Session history owns snapshots independently of pane and window lifetime.
/// Only a pane's latest preview takes revisions; earlier requests stay frozen.
@MainActor
final class FilePreviewHistory: ObservableObject {
    static let shared = FilePreviewHistory()
    static let maximumEntries = 32

    struct Entry: Identifiable {
        var id: UUID { preview.id }
        let preview: ImagePreviewStore.Preview
        let pane: PaneSlotID
        let worktreePath: String
        var createdAt: Date? { preview.createdAt }

        var menuTitle: String { WorktreePreviewCollection.menuTitle(title, createdAt: createdAt) }

        var title: String {
            preview.files.count == 1 ? preview.filename : "\(preview.filename) + \(preview.files.count - 1) more"
        }

        func revised(files: [FilePreviewFile], contentRevision: Int) -> Entry {
            Entry(preview: preview.revised(files: files, contentRevision: contentRevision), pane: pane, worktreePath: worktreePath)
        }
    }

    @Published private(set) var entries: [Entry] = []

    func entries(for worktreePath: String, including active: [Entry] = []) -> [Entry] {
        let recent = entries.filter { $0.worktreePath == worktreePath }
        var seen = Set(recent.map(\.id))
        let additional = active.filter { $0.worktreePath == worktreePath && seen.insert($0.id).inserted }
        return (recent + additional).sorted {
            let lhs = $0.createdAt ?? .distantPast
            let rhs = $1.createdAt ?? .distantPast
            return lhs == rhs ? $0.preview.createdInstant > $1.preview.createdInstant : lhs > rhs
        }
    }

    @discardableResult
    func record(files: [FilePreviewFile], pane: PaneSlotID, worktreePath: String, id: UUID = UUID(), createdAt: Date? = Date(),
                contentRevision: Int = 0) -> Entry {
        let entry = Entry(preview: .init(files: files, id: id, createdAt: createdAt, contentRevision: contentRevision), pane: pane, worktreePath: worktreePath)
        entries.removeAll { $0.id == id && $0.worktreePath == worktreePath }
        entries.insert(entry, at: 0)
        if entries.count > Self.maximumEntries { entries.removeLast(entries.count - Self.maximumEntries) }
        return entry
    }

    /// A revision is the same request with newer content, so it keeps its place.
    func applyRevision(of id: UUID, worktreePath: String, files: [FilePreviewFile], contentRevision: Int) {
        guard let index = entries.firstIndex(where: { $0.id == id && $0.worktreePath == worktreePath }) else { return }
        entries[index] = entries[index].revised(files: files, contentRevision: contentRevision)
    }
}
