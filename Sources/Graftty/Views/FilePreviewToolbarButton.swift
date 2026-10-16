import SwiftUI
import GrafttyKit

@MainActor
struct FilePreviewToolbarButton: View {
    let worktreePath: String
    let inlinePane: PaneSlotID?
    let canShowInline: (PaneSlotID) -> Bool
    @ObservedObject private var history: FilePreviewHistory
    @ObservedObject private var windows: FilePreviewWindows
    @ObservedObject private var inline: ImagePreviewStore

    init(worktreePath: String, inlinePane: PaneSlotID?, canShowInline: @escaping (PaneSlotID) -> Bool) {
        self.init(worktreePath: worktreePath, inlinePane: inlinePane, canShowInline: canShowInline,
                  history: .shared, windows: .shared, inline: .shared)
    }

    init(worktreePath: String, inlinePane: PaneSlotID?, canShowInline: @escaping (PaneSlotID) -> Bool,
         history: FilePreviewHistory, windows: FilePreviewWindows, inline: ImagePreviewStore) {
        self.worktreePath = worktreePath
        self.inlinePane = inlinePane
        self.canShowInline = canShowInline
        self.history = history
        self.windows = windows
        self.inline = inline
    }

    var entries: [FilePreviewHistory.Entry] {
        var entries = history.entries(for: worktreePath)
        if let open = windows.selectedEntry(for: worktreePath), !entries.contains(where: { $0.id == open.id }) {
            entries.insert(open, at: 0)
        }
        if let pane = inlinePane, let preview = inline.previews[pane], !entries.contains(where: { $0.id == preview.id }) {
            entries.insert(.init(preview: preview, pane: pane, worktreePath: worktreePath), at: 0)
        }
        return entries
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
        windows.show(entry, inlinePane: inlinePane, canShowInline: canShowInline)
    }
}
