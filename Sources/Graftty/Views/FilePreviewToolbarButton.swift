import SwiftUI
import GrafttyKit

@MainActor
struct FilePreviewToolbarButton: View {
    let worktreePath: String
    let inlinePane: PaneSlotID?
    let resolveInlineWorktree: ((PaneSlotID) -> String?)?
    @ObservedObject private var history: FilePreviewHistory
    @ObservedObject private var windows: FilePreviewWindows
    @ObservedObject private var inline: ImagePreviewStore

    init(worktreePath: String, inlinePane: PaneSlotID?, resolveInlineWorktree: ((PaneSlotID) -> String?)? = nil) {
        self.init(worktreePath: worktreePath, inlinePane: inlinePane, resolveInlineWorktree: resolveInlineWorktree,
                  history: .shared, windows: .shared, inline: .shared)
    }

    init(worktreePath: String, inlinePane: PaneSlotID?, resolveInlineWorktree: ((PaneSlotID) -> String?)? = nil,
         history: FilePreviewHistory, windows: FilePreviewWindows, inline: ImagePreviewStore) {
        self.worktreePath = worktreePath
        self.inlinePane = inlinePane
        self.resolveInlineWorktree = resolveInlineWorktree
        self.history = history
        self.windows = windows
        self.inline = inline
    }

    var entries: [FilePreviewHistory.Entry] {
        let panePreviews: [PaneSlotID: ImagePreviewStore.Preview]
        if let resolveInlineWorktree {
            panePreviews = inline.previews.filter { resolveInlineWorktree($0.key) == worktreePath }
        } else {
            panePreviews = inline.previews(forWorktreePath: worktreePath)
        }
        var active = panePreviews.map { pane, preview in
            FilePreviewHistory.Entry(preview: preview, pane: pane, worktreePath: worktreePath)
        }
        if let open = windows.selectedEntry(for: worktreePath) {
            active.append(open)
        }
        return history.entries(for: worktreePath, including: active)
    }

    var body: some View {
        if let latest = entries.first {
            Menu {
                ForEach(entries) { entry in
                    Button {
                        show(entry)
                    } label: {
                        Text(entry.title + " · " + entry.createdAt.formatted(date: .omitted, time: .shortened))
                    }
                }
            } label: {
                Label("Preview", systemImage: "doc.richtext")
                    .labelStyle(.iconOnly)
            } primaryAction: {
                show(latest)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Open latest preview; use the menu for recent previews")
            .accessibilityLabel("Preview")
            .accessibilityValue("\(entries.count) recent previews")
        }
    }

    private func show(_ entry: FilePreviewHistory.Entry) {
        windows.show(entry, inlinePane: inlinePane, resolveInlineWorktree: resolveInlineWorktree)
    }
}
