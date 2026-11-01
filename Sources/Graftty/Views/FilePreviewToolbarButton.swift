import SwiftUI
import GrafttyKit
import GrafttyProtocol

@MainActor
struct FilePreviewToolbarButton: View {
    let worktreePath: String
    let inlinePane: PaneSlotID?
    let resolveInlineWorktree: ((PaneSlotID) -> String?)?
    private let catalogRequest: ((RemoteOpenRequest) async throws -> RemoteOpenResponse)?
    @State private var catalog: [WorktreePreviewCollection] = []
    @State private var loading = false
    @State private var error: String?
    @State private var download: Task<Void, Never>?
    @State private var downloadID: UUID?
    @ObservedObject private var history: FilePreviewHistory
    @ObservedObject private var windows: FilePreviewWindows
    @ObservedObject private var inline: ImagePreviewStore

    init(worktreePath: String, inlinePane: PaneSlotID?, resolveInlineWorktree: ((PaneSlotID) -> String?)? = nil,
         catalogRequest: ((RemoteOpenRequest) async throws -> RemoteOpenResponse)? = nil) {
        self.init(worktreePath: worktreePath, inlinePane: inlinePane, resolveInlineWorktree: resolveInlineWorktree,
                  history: .shared, windows: .shared, inline: .shared, catalogRequest: catalogRequest)
    }

    init(worktreePath: String, inlinePane: PaneSlotID?, resolveInlineWorktree: ((PaneSlotID) -> String?)? = nil,
         history: FilePreviewHistory, windows: FilePreviewWindows, inline: ImagePreviewStore,
         catalogRequest: ((RemoteOpenRequest) async throws -> RemoteOpenResponse)? = nil) {
        self.catalogRequest = catalogRequest
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
            ?? windows.hiddenEntry(for: worktreePath)?.title ?? entries.first?.title ?? catalog.first?.title ?? "Preview"
    }
    func togglePreview() {
        if let activeInline {
            windows.hide(.init(preview: activeInline.value, pane: activeInline.key, worktreePath: worktreePath), inlinePane: activeInline.key)
        } else if let entry = windows.selectedEntry(for: worktreePath) {
            windows.hide(entry, inlinePane: nil)
        } else if windows.restoreHidden(for: worktreePath, inlinePane: inlinePane, resolveWorktree: resolveInlineWorktree) {
            return
        } else if let latest = entries.first { show(latest) }
        else if let latest = catalog.first { openCollection(latest) }
    }

    var body: some View {
        Group {
        if !entries.isEmpty || !catalog.isEmpty {
            Menu {
                ForEach(catalog.filter { collection in !entries.contains { $0.id == collection.id } }) { collection in
                    Button(collection.title) { openCollection(collection) }
                }
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
            .fixedSize(horizontal: true, vertical: true)
            .help("\(displayTitle). Click to toggle; use the menu for recent previews.")
            .accessibilityLabel("Preview")
            .accessibilityValue("Worktree preview history")
            .disabled(loading)
        } else {
            // Keep the catalog task mounted before this client has any history.
            Color.clear.frame(width: 0, height: 0)
        }
        }
        .task(id: worktreePath) {
            catalog = []
            while !Task.isCancelled {
                do {
                    if case .offers(let offers) = try await request(.list) {
                        guard !Task.isCancelled else { return }
                        catalog = RemoteOpenOffer.previewCollections(in: offers)
                    }
                } catch { if Task.isCancelled { return } }
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
            }
        }
        .onChange(of: worktreePath) { _, _ in cancelDownload() }
        .onDisappear { cancelDownload() }
        .alert("Could not open preview", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK") { error = nil }
        } message: { Text(error ?? "") }
    }

    private func request(_ request: RemoteOpenRequest) async throws -> RemoteOpenResponse {
        if let catalogRequest { return try await catalogRequest(request) }
        switch request {
        case .list: return .offers(await RemoteOpenStore.shared.list(worktree: worktreePath))
        case let .read(id, offset): return .chunk(try await RemoteOpenStore.shared.read(id: id, worktree: worktreePath, offset: offset))
        default: throw RemoteOpenStore.Failure.invalidFile
        }
    }

    private func openCollection(_ collection: WorktreePreviewCollection) {
        guard !loading else { return }
        loading = true
        let id = UUID()
        downloadID = id
        download = Task { @MainActor in
            defer { if downloadID == id { loading = false; download = nil; downloadID = nil } }
            do {
                var files: [FilePreviewFile] = []
                guard (1...20).contains(collection.offers.count),
                      collection.offers.allSatisfy({ (0...RemoteOpenOffer.maxBytes).contains($0.byteCount) }),
                      collection.offers.reduce(0, { $0 + $1.byteCount }) <= FilePreviewLoader.maximumTotalBytes else { throw FilePreviewLoader.Failure.tooLarge }
                for offer in collection.offers {
                    var bytes = Data()
                    while bytes.count < offer.byteCount {
                        try Task.checkCancellation()
                        guard case .chunk(let chunk) = try await request(.read(id: offer.id, offset: bytes.count)),
                              !chunk.isEmpty, chunk.count <= RemoteOpenOffer.chunkBytes,
                              chunk.count <= offer.byteCount - bytes.count else { throw RemoteOpenStore.Failure.invalidFile }
                        bytes.append(chunk)
                    }
                    let snapshot = FilePreviewLoader.Snapshot(filename: offer.filename, bytes: bytes)
                    files.append(try await Task.detached { try FilePreviewFile(snapshot) }.value)
                }
                try Task.checkCancellation()
                let entry = history.record(files: files, pane: inlinePane ?? PaneSlotID(), worktreePath: worktreePath, id: collection.id)
                show(entry)
            } catch is CancellationError {} catch { if downloadID == id { self.error = error.localizedDescription } }
        }
    }

    private func cancelDownload() {
        download?.cancel(); download = nil; downloadID = nil; loading = false; error = nil
    }

    private func show(_ entry: FilePreviewHistory.Entry) {
        windows.show(entry, inlinePane: inlinePane, resolveInlineWorktree: resolveInlineWorktree)
    }
}
