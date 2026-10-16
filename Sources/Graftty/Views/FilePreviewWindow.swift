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

    func show(_ entry: FilePreviewHistory.Entry, activate: Bool = true,
              inlinePane: PaneSlotID? = nil, canShowInline: @escaping (PaneSlotID) -> Bool = { _ in true }) {
        objectWillChange.send()
        inline.dismiss(entry.pane)
        if let inlinePane, inlinePane != entry.pane { inline.dismiss(inlinePane) }
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
        let targetPane = inlinePane ?? entry.pane
        controller.model.showInline = { [weak self] selected in
            guard canShowInline(targetPane) else { return }
            self?.showInline(selected, pane: targetPane)
        }
        controller.model.canShowInline = canShowInline(targetPane)
        if activate { controller.window?.makeKeyAndOrderFront(nil) }
        else { controller.window?.orderFront(nil) }
    }

    func showInline(_ entry: FilePreviewHistory.Entry, pane: PaneSlotID? = nil) {
        controllers[entry.worktreePath]?.close()
        let target = pane ?? entry.pane
        inline.present(entry.preview, for: target)
        inlineTarget = InlineTarget(worktreePath: entry.worktreePath, pane: target)
    }

    func closeAll() {
        for controller in Array(controllers.values) { controller.close() }
    }
}

@MainActor
private final class FilePreviewWindowModel: ObservableObject {
    @Published var entry: FilePreviewHistory.Entry {
        willSet { selectionWillChange() }
    }
    var selectionWillChange: () -> Void = {}
    @Published var canShowInline = true
    var showInline: (FilePreviewHistory.Entry) -> Void = { _ in }
    init(entry: FilePreviewHistory.Entry) { self.entry = entry }
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
        let recent = history.entries(for: model.entry.worktreePath)
        // An open window continues owning its selected snapshot after history eviction.
        return recent.contains(where: { $0.id == model.entry.id }) ? recent : [model.entry] + recent
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
                Button("Show in Terminal") { model.showInline(model.entry) }
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
