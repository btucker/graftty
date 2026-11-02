import AppKit
import SwiftUI
import GrafttyKit
import GrafttyProtocol

/// Each worktree reuses a standard document window. Agent delivery never makes it key.
@MainActor
final class FilePreviewWindows: ObservableObject {
    static let shared = FilePreviewWindows(history: .shared, inline: .shared)
    private let history: FilePreviewHistory
    private let inline: ImagePreviewStore
    @Published private(set) var theme: GhosttyTheme = .fallback
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

    func updateTheme(_ theme: GhosttyTheme) {
        guard theme != self.theme else { return }
        self.theme = theme
        for controller in controllers.values { controller.applyTheme(theme) }
    }

    var worktreePaths: [String] {
        Set(history.entries.map(\.worktreePath) + Array(controllers.keys) + hiddenPreviews.map { $0.entry.worktreePath }).sorted()
    }

    func raise(worktreePath: String) {
        if let controller = controllers[worktreePath] {
            controller.window?.makeKeyAndOrderFront(nil)
        } else if let entry = hiddenEntry(for: worktreePath) ?? history.entries(for: worktreePath).first {
            show(entry)
        }
    }

    func window(for worktreePath: String) -> NSWindow? { controllers[worktreePath]?.window }
    func selectedEntry(for worktreePath: String) -> FilePreviewHistory.Entry? {
        controllers[worktreePath]?.model.entry
    }
    /// Test seam for the history picker and return-to-terminal action.
    func model(for worktreePath: String) -> FilePreviewWindowModel? { controllers[worktreePath]?.model }

    func show(_ entry: FilePreviewHistory.Entry, activate: Bool = true,
              inlinePane: PaneSlotID? = nil, resolveInlineWorktree: ((PaneSlotID) -> String?)? = nil,
              catalogRequest: ((RemoteOpenRequest) async throws -> RemoteOpenResponse)? = nil) {
        objectWillChange.send()
        hiddenPreviews.removeAll { $0.entry.worktreePath == entry.worktreePath }
        inline.dismiss(previewID: entry.id)
        let controller: FilePreviewWindowController
        if let existing = controllers[entry.worktreePath] {
            controller = existing
            controller.model.entry = entry
        } else {
            controller = FilePreviewWindowController(entry: entry, history: history, windows: self)
            controllers[entry.worktreePath] = controller
            let path = entry.worktreePath
            controller.model.selectionWillChange = { [weak self] in self?.objectWillChange.send() }
            controller.onClose = { [weak self] in
                self?.objectWillChange.send()
                self?.controllers.removeValue(forKey: path)
            }
        }
        controller.model.catalogRequest = catalogRequest
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
        willSet { selectionRevision &+= 1; selectionWillChange() }
    }
    private var selectionRevision: UInt64 = 0
    var catalogRequest: ((RemoteOpenRequest) async throws -> RemoteOpenResponse)?
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

    func open(_ collection: WorktreePreviewCollection, history: FilePreviewHistory,
              request: (RemoteOpenRequest) async throws -> RemoteOpenResponse) async throws {
        let revision = selectionRevision
        let files = try await FilePreviewCollectionLoader.load(collection, request: request)
        try Task.checkCancellation()
        // A newer agent delivery or user selection wins over this download.
        guard selectionRevision == revision else { return }
        entry = history.record(files: files, pane: entry.pane, worktreePath: entry.worktreePath,
            id: collection.id, createdAt: collection.createdAt ?? Date())
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

    init(entry: FilePreviewHistory.Entry, history: FilePreviewHistory, windows: FilePreviewWindows) {
        model = FilePreviewWindowModel(entry: entry)
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 900, height: 650),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.title = "\(URL(fileURLWithPath: entry.worktreePath).lastPathComponent) Previews"
        window.minSize = NSSize(width: 480, height: 320)
        window.center()
        window.setFrameAutosaveName("FilePreview-" + entry.worktreePath)
        super.init(window: window)
        window.delegate = self
        let host = NSHostingView(rootView: FilePreviewWindowContent(model: model, history: history, windows: windows,
            onClose: { [weak self] in self?.close() }).ignoresSafeArea())
        host.safeAreaRegions = []
        window.contentView = host
        applyTheme(windows.theme)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func applyTheme(_ theme: GhosttyTheme) {
        window?.backgroundColor = theme.backgroundNSColor
        window?.appearance = theme.nsAppearance
    }

    func windowWillClose(_ notification: Notification) {
        // Removing the hosted view invokes the representable's idempotent Quick Look teardown.
        window?.contentView = nil
        onClose()
    }
}

private struct FilePreviewWindowContent: View {
    @ObservedObject var model: FilePreviewWindowModel
    @ObservedObject var history: FilePreviewHistory
    @ObservedObject var windows: FilePreviewWindows
    let onClose: () -> Void
    @State private var catalog: [WorktreePreviewCollection] = []
    @State private var pendingCollection: WorktreePreviewCollection?
    @State private var error: String?

    private var navigation: FilePreviewNavigation {
        FilePreviewNavigation(worktreePath: model.entry.worktreePath, worktreePaths: windows.worktreePaths,
            entries: history.entries(for: model.entry.worktreePath, including: [model.entry]), catalog: catalog,
            canShowInTerminal: model.canShowInline,
            onSelectEntry: { pendingCollection = nil; model.entry = $0 }, onOpenCollection: { pendingCollection = $0 },
            onSelectWorktree: { windows.raise(worktreePath: $0) }, onShowInTerminal: { model.showInline() })
    }

    var body: some View {
        FilePreviewTray(preview: model.entry.preview, onDismiss: onClose,
                        onInteraction: { _ in }, isWindowed: true, theme: windows.theme, navigation: navigation)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .task(id: model.entry.worktreePath) {
                while !Task.isCancelled {
                    do {
                        if case .offers(let offers) = try await request(.list) {
                            try Task.checkCancellation()
                            catalog = RemoteOpenOffer.previewCollections(in: offers)
                        }
                    } catch { if Task.isCancelled { return } }
                    do { try await Task.sleep(for: .seconds(5)) } catch { return }
                }
            }
            .task(id: pendingCollection?.id) {
                guard let collection = pendingCollection else { return }
                defer { if pendingCollection?.id == collection.id { pendingCollection = nil } }
                do {
                    try await model.open(collection, history: history, request: request)
                } catch is CancellationError {} catch { self.error = error.localizedDescription }
            }
            .onChange(of: model.entry.id) { _, _ in pendingCollection = nil }
            .alert("Could not open preview", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("OK") { error = nil }
            } message: { Text(error ?? "") }
    }

    private func request(_ request: RemoteOpenRequest) async throws -> RemoteOpenResponse {
        if let catalogRequest = model.catalogRequest { return try await catalogRequest(request) }
        switch request {
        case .list: return .offers(await RemoteOpenStore.shared.list(worktree: model.entry.worktreePath))
        case let .read(id, offset): return .chunk(try await RemoteOpenStore.shared.read(id: id, worktree: model.entry.worktreePath, offset: offset))
        default: throw RemoteOpenStore.Failure.invalidFile
        }
    }
}
