import AppKit
import SwiftUI
import GrafttyKit

/// Each worktree reuses a standard document window. Agent delivery never makes it key.
@MainActor
final class FilePreviewWindows: ObservableObject {
    static let shared = FilePreviewWindows(history: .shared, inline: .shared)
    private let history: FilePreviewHistory
    private let inline: ImagePreviewStore
    private var controllers: [String: FilePreviewWindowController] = [:]
    private struct HiddenPreview {
        let entry: FilePreviewHistory.Entry
        let pane: PaneSlotID?
    }
    private var hiddenPreviews: [HiddenPreview] = []

    func hiddenEntry(for path: String) -> FilePreviewHistory.Entry? {
        hiddenPreviews.first { $0.entry.worktreePath == path }?.entry
    }

    func hide(_ entry: FilePreviewHistory.Entry, inlinePane: PaneSlotID?) {
        objectWillChange.send()
        hiddenPreviews.removeAll { $0.entry.worktreePath == entry.worktreePath }
        hiddenPreviews.insert(HiddenPreview(entry: entry, pane: inlinePane), at: 0)
        hiddenPreviews = Array(hiddenPreviews.prefix(FilePreviewHistory.maximumEntries))
        if let inlinePane { inline.dismiss(inlinePane) }
        else { controllers[entry.worktreePath]?.close() }
    }

    func restoreHidden(for path: String, inlinePane: PaneSlotID?, resolveWorktree: ((PaneSlotID) -> String?)?) -> Bool {
        guard let hidden = hiddenPreviews.first(where: { $0.entry.worktreePath == path }) else { return false }
        if let previousPane = hidden.pane {
            let target = inlinePane ?? previousPane
            if resolveWorktree == nil || resolveWorktree?(target) == path {
                showInline(hidden.entry, pane: target, worktreePath: path)
                return true
            }
        }
        show(hidden.entry, inlinePane: inlinePane, resolveInlineWorktree: resolveWorktree)
        return true
    }

    struct InlineTarget: Equatable {
        let id = UUID()
        let worktreePath: String
        let pane: PaneSlotID
    }
    @Published private(set) var inlineTarget: InlineTarget?

    init(history: FilePreviewHistory, inline: ImagePreviewStore) {
        self.history = history
        self.inline = inline
    }

    func window(for worktreePath: String) -> NSWindow? { controllers[worktreePath]?.window }
    func selectedEntry(for worktreePath: String) -> FilePreviewHistory.Entry? {
        controllers[worktreePath]?.model.entry
    }
    /// Test seam for the history picker and return-to-terminal action.
    func model(for worktreePath: String) -> FilePreviewWindowModel? { controllers[worktreePath]?.model }

    func show(_ entry: FilePreviewHistory.Entry, activate: Bool = true,
              inlinePane: PaneSlotID? = nil, resolveInlineWorktree: ((PaneSlotID) -> String?)? = nil) {
        objectWillChange.send()
        hiddenPreviews.removeAll { $0.entry.worktreePath == entry.worktreePath }
        inline.dismiss(previewID: entry.id)
        let controller: FilePreviewWindowController
        if let existing = controllers[entry.worktreePath] {
            controller = existing
            controller.model.entry = entry
        } else {
            controller = FilePreviewWindowController(entry: entry, history: history)
            controllers[entry.worktreePath] = controller
            let path = entry.worktreePath
            controller.model.selectionWillChange = { [weak self] in self?.objectWillChange.send() }
            controller.onClose = { [weak self] in
                self?.objectWillChange.send()
                self?.controllers.removeValue(forKey: path)
            }
        }
        controller.model.configureInline(pane: inlinePane, resolveWorktree: resolveInlineWorktree) { [weak self] selected, target, path in
            self?.showInline(selected, pane: target, worktreePath: path)
        }
        if activate { controller.window?.makeKeyAndOrderFront(nil) }
        else { controller.window?.orderFront(nil) }
    }

    func showInline(_ entry: FilePreviewHistory.Entry, pane: PaneSlotID? = nil, worktreePath: String? = nil) {
        objectWillChange.send()
        hiddenPreviews.removeAll { $0.entry.worktreePath == entry.worktreePath }
        controllers[entry.worktreePath]?.close()
        let target = pane ?? entry.pane
        let path = worktreePath ?? entry.worktreePath
        inline.dismiss(previewID: entry.id)
        inline.present(entry.preview, for: target, worktreePath: path)
        inlineTarget = InlineTarget(worktreePath: path, pane: target)
    }

    func closeAll() {
        for controller in Array(controllers.values) { controller.close() }
    }
}

@MainActor
final class FilePreviewWindowModel: ObservableObject {
    @Published var entry: FilePreviewHistory.Entry {
        willSet { selectionWillChange() }
    }
    var selectionWillChange: () -> Void = {}
    private var inlinePane: PaneSlotID?
    private var resolveInlineWorktree: ((PaneSlotID) -> String?)?
    private var onShowInline: (FilePreviewHistory.Entry, PaneSlotID, String) -> Void = { _, _, _ in }
    private var targetPane: PaneSlotID { inlinePane ?? entry.pane }
    private var targetWorktreePath: String? {
        if let resolveInlineWorktree { return resolveInlineWorktree(targetPane) }
        return entry.worktreePath
    }
    var canShowInline: Bool { targetWorktreePath != nil }
    init(entry: FilePreviewHistory.Entry) { self.entry = entry }

    func configureInline(pane: PaneSlotID?, resolveWorktree: ((PaneSlotID) -> String?)?,
                         onShow: @escaping (FilePreviewHistory.Entry, PaneSlotID, String) -> Void) {
        objectWillChange.send()
        inlinePane = pane
        resolveInlineWorktree = resolveWorktree
        onShowInline = onShow
    }

    func showInline() {
        guard let path = targetWorktreePath else { return }
        onShowInline(entry, targetPane, path)
    }
}

@MainActor
private final class FilePreviewWindowController: NSWindowController, NSWindowDelegate {
    let model: FilePreviewWindowModel
    var onClose: () -> Void = {}

    init(entry: FilePreviewHistory.Entry, history: FilePreviewHistory) {
        model = FilePreviewWindowModel(entry: entry)
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 900, height: 650),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "\(URL(fileURLWithPath: entry.worktreePath).lastPathComponent) Previews"
        window.minSize = NSSize(width: 480, height: 320)
        window.center()
        window.setFrameAutosaveName("FilePreview-" + entry.worktreePath)
        super.init(window: window)
        window.delegate = self
        window.contentView = NSHostingView(rootView: FilePreviewWindowContent(model: model, history: history,
            onClose: { [weak self] in self?.close() }))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func windowWillClose(_ notification: Notification) {
        // Removing the hosted view invokes the representable's idempotent Quick Look teardown.
        window?.contentView = nil
        onClose()
    }
}

private struct FilePreviewWindowContent: View {
    @ObservedObject var model: FilePreviewWindowModel
    @ObservedObject var history: FilePreviewHistory
    let onClose: () -> Void

    private var entries: [FilePreviewHistory.Entry] {
        // An open window continues owning its selected snapshot after history eviction.
        history.entries(for: model.entry.worktreePath, including: [model.entry])
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("Preview history", selection: Binding(
                    get: { model.entry.id },
                    set: { id in if let entry = entries.first(where: { $0.id == id }) { model.entry = entry } }
                )) {
                    ForEach(entries) { entry in
                        Text(entry.title + " · " + entry.createdAt.formatted(date: .omitted, time: .shortened)).tag(entry.id)
                    }
                }
                .labelsHidden()
                .accessibilityLabel("Preview history")
                Button("Show in Terminal") { model.showInline() }
                    .disabled(!model.canShowInline)
            }
            .padding(10)
            Divider()
            FilePreviewTray(preview: model.entry.preview, onDismiss: onClose,
                            onInteraction: { _ in }, isWindowed: true)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
