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
        if let hidden = windows.hiddenEntry(for: worktreePath) { active.append(hidden) }
        return history.entries(for: worktreePath, including: active)
    }

    private var activeInline: (key: PaneSlotID, value: ImagePreviewStore.Preview)? {
        guard let pane = inlinePane, let preview = inline.previews[pane] else { return nil }
        if let resolveInlineWorktree {
            guard resolveInlineWorktree(pane) == worktreePath else { return nil }
        } else if inline.previews(forWorktreePath: worktreePath)[pane] == nil { return nil }
        return (pane, preview)
    }
    var isPreviewOpen: Bool { activeInline != nil || windows.selectedEntry(for: worktreePath) != nil }
    var displayTitle: String {
        activeInline?.value.filename ?? windows.selectedEntry(for: worktreePath)?.title
            ?? windows.hiddenEntry(for: worktreePath)?.title ?? entries.first?.title ?? "Preview"
    }
    func togglePreview() {
        if let activeInline {
            windows.hide(.init(preview: activeInline.value, pane: activeInline.key, worktreePath: worktreePath), inlinePane: activeInline.key)
        } else if let entry = windows.selectedEntry(for: worktreePath) {
            windows.hide(entry, inlinePane: nil)
        } else if !windows.restoreHidden(for: worktreePath, inlinePane: inlinePane, resolveWorktree: resolveInlineWorktree), let latest = entries.first {
            show(latest)
        }
    }

    var body: some View {
        if !entries.isEmpty {
            Menu {
                ForEach(entries) { entry in
                    Button {
                        show(entry)
                    } label: {
                        Text(entry.title + " · " + entry.createdAt.formatted(date: .omitted, time: .shortened))
                    }
                }
            } label: {
                ViewThatFits(in: .horizontal) {
                    Label(displayTitle, systemImage: "doc.richtext").lineLimit(1).frame(maxWidth: 140)
                    Image(systemName: "doc.richtext")
                }.padding(.horizontal, 7).frame(height: 28)
                    .background(isPreviewOpen ? Color.primary.opacity(0.12) : .clear, in: Capsule())
            } primaryAction: {
                togglePreview()
            }
            .menuStyle(.borderlessButton)
            .fixedSize(horizontal: false, vertical: true)
            .help("\(displayTitle). Click to toggle; use the menu for recent previews.")
            .accessibilityLabel("Preview")
            .accessibilityValue("\(entries.count) recent previews")
        }
    }

    private func show(_ entry: FilePreviewHistory.Entry) {
        windows.show(entry, inlinePane: inlinePane, resolveInlineWorktree: resolveInlineWorktree)
    }
}
