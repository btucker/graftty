#if canImport(UIKit)
import SwiftUI
import GrafttyProtocol

/// Manual worktree library. Browsing a snapshot never takes terminal ownership.
struct WorktreePreviewMenu: View {
    let host: Host
    let worktree: String
    @Environment(\.remoteConnectionCoordinator) private var coordinator
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.biometricGate) private var gate
    @State private var offers: [RemoteOpenOffer] = []
    @State private var presented: DownloadedPreview?
    @State private var loading = false
    @State private var download: Task<Void, Never>?
    @State private var downloadID: UUID?
    @State private var error: String?

    private var collections: [WorktreePreviewCollection] { RemoteOpenOffer.previewCollections(in: offers) }
    private var ready: Bool { LiveSessionReadiness.isActive(scene: scenePhase, gateUnlocked: gate.isUnlocked) }
    private var scope: String { "\(host.id):\(worktree):\(ready)" }

    var body: some View {
        Menu {
            if collections.isEmpty { Text("No previews in this worktree") }
            ForEach(collections) { collection in
                Button(collection.title) {
                    open(collection.offers)
                }
            }
        } label: {
            Label("Worktree previews", systemImage: "doc.richtext").labelStyle(.iconOnly)
                .frame(minWidth: 44, minHeight: 44)
        }
        .disabled(loading || !ready)
        .overlay { if loading { ProgressView().controlSize(.mini) } }
        .task(id: scope) {
            offers = []
            guard ready, let coordinator else { return }
            while !Task.isCancelled {
                do {
                    let response = try await coordinator.sendWorktreeManagement(.openResource(worktreeID: worktree, request: .list), to: host)
                    guard !Task.isCancelled else { return }
                    if case .openResource(.offers(let incoming)) = response { offers = incoming }
                    if case .error = response { return }
                } catch { if Task.isCancelled { return } }
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
            }
        }
        .sheet(item: $presented) { item in
            NativeImagePreview(urls: item.files, dismiss: { presented = nil })
        }
        .onChange(of: scope) { _, _ in cancelDownload(); presented = nil }
        .onDisappear { cancelDownload() }
        .alert("Could not open preview", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK") { error = nil }
        } message: { Text(error ?? "") }
    }

    private func open(_ collection: [RemoteOpenOffer]) {
        guard !loading, ready, let coordinator else { return }
        loading = true
        let id = UUID()
        downloadID = id
        download = Task { @MainActor in
            defer { if downloadID == id { loading = false; download = nil; downloadID = nil } }
            do {
                let files = try await FilePreviewDownload.download(collection) { offer, offset in
                    let response = try await coordinator.sendWorktreeManagement(
                        .openResource(worktreeID: worktree, request: .read(id: offer.id, offset: offset)), to: host)
                    guard case .openResource(.chunk(let data)) = response else { throw FilePreviewDownload.Failure.invalidChunk }
                    return data
                }
                guard ready, !Task.isCancelled else { files.forEach(FilePreviewDownload.remove); return }
                presented = DownloadedPreview(files: files)
            } catch is CancellationError {} catch { if downloadID == id { self.error = error.localizedDescription } }
        }
    }

    private func cancelDownload() {
        download?.cancel(); download = nil; downloadID = nil; loading = false; error = nil
    }
}

private final class DownloadedPreview: Identifiable {
    let id = UUID()
    let files: [URL]
    init(files: [URL]) { self.files = files }
    deinit { files.forEach(FilePreviewDownload.remove) }
}
#endif
