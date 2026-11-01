import Foundation
import Combine
import GrafttyKit

/// Session history owns snapshots independently of pane and window lifetime.
@MainActor
final class FilePreviewHistory: ObservableObject {
    static let shared = FilePreviewHistory()
    static let maximumEntries = 32

    struct Entry: Identifiable {
        var id: UUID { preview.id }
        let preview: ImagePreviewStore.Preview
        let pane: PaneSlotID
        let worktreePath: String
        var createdAt: Date { preview.createdAt }

        var title: String {
            preview.files.count == 1 ? preview.filename : "\(preview.filename) + \(preview.files.count - 1) more"
        }
    }

    @Published private(set) var entries: [Entry] = []

    func entries(for worktreePath: String, including active: [Entry] = []) -> [Entry] {
        let recent = entries.filter { $0.worktreePath == worktreePath }
        var seen = Set(recent.map(\.id))
        let additional = active.filter { $0.worktreePath == worktreePath && seen.insert($0.id).inserted }
        return (recent + additional).sorted { $0.preview.createdInstant > $1.preview.createdInstant }
    }

    @discardableResult
    func record(files: [FilePreviewFile], pane: PaneSlotID, worktreePath: String, id: UUID = UUID()) -> Entry {
        let entry = Entry(preview: .init(files: files, id: id), pane: pane, worktreePath: worktreePath)
        entries.removeAll { $0.id == id && $0.worktreePath == worktreePath }
        entries.insert(entry, at: 0)
        if entries.count > Self.maximumEntries { entries.removeLast(entries.count - Self.maximumEntries) }
        return entry
    }
}
