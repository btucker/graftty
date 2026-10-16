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
        let createdAt = Date()

        var title: String {
            preview.files.count == 1 ? preview.filename : "\(preview.filename) + \(preview.files.count - 1) more"
        }
    }

    @Published private(set) var entries: [Entry] = []

    func entries(for worktreePath: String) -> [Entry] {
        entries.filter { $0.worktreePath == worktreePath }
    }

    @discardableResult
    func record(files: [FilePreviewFile], pane: PaneSlotID, worktreePath: String) -> Entry {
        let entry = Entry(preview: .init(files: files), pane: pane, worktreePath: worktreePath)
        entries.insert(entry, at: 0)
        if entries.count > Self.maximumEntries { entries.removeLast(entries.count - Self.maximumEntries) }
        return entry
    }
}
