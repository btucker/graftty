#if canImport(UIKit)
import GrafttyProtocol
import QuickLook
import SwiftUI
import UIKit

/// Offers stay in a menu rather than stealing focus from the terminal.
struct RemoteOpenButton: View {
    let host: Host
    let worktree: String
    let coordinator: RemoteConnectionCoordinator
    @State private var offers: [RemoteOpenOffer] = []
    @State private var download: Task<Void, Never>?
    @State private var isDownloading = false
    @State private var preview: Preview?
    @State private var cachedFile: URL?
    @State private var error: String?

    private struct Preview: Identifiable {
        let id = UUID()
        let url: URL
    }

    var body: some View {
        Group {
            if isDownloading {
                ProgressView("Downloading file…")
                    .padding(12)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
            } else if !offers.isEmpty {
                Menu {
                    ForEach(offers) { offer in
                        Button(offer.filename) { open(offer) }
                    }
                } label: {
                    Label("Open (\(offers.count))", systemImage: "doc")
                        .padding(10)
                        .background(.regularMaterial, in: Capsule())
                }
            }
        }
        .task(id: worktree) {
            while !Task.isCancelled {
                do {
                    let response = try await coordinator.sendWorktreeManagement(
                        .openResource(worktreeID: worktree, request: .list), to: host
                    )
                    guard !Task.isCancelled else { return }
                    if case .openResource(.offers(let value)) = response { offers = value }
                    // Older hosts reject the new operation. Do not keep polling them.
                    if case .error = response { return }
                } catch {
                    if Task.isCancelled { return }
                }
                do { try await Task.sleep(for: .seconds(3)) } catch { return }
            }
        }
        .sheet(item: $preview, onDismiss: removeCachedFile) { preview in
            if preview.url.isFileURL {
                NativeFilePreview(url: preview.url)
            } else {
                HostBrowserView(url: preview.url, host: host, coordinator: coordinator)
            }
        }
        .alert("Could not open resource", isPresented: Binding(
            get: { error != nil }, set: { if !$0 { error = nil } }
        )) {
            Button("OK") { error = nil }
        } message: {
            Text(error ?? "")
        }
        .onDisappear {
            download?.cancel()
            download = nil
            preview = nil
            removeCachedFile()
        }
    }

    private func removeCachedFile() {
        if let cachedFile { FilePreviewDownload.remove(cachedFile) }
        cachedFile = nil
    }

    private func open(_ offer: RemoteOpenOffer) {
        if let url = offer.url {
            guard !worktree.hasPrefix("relay-worktree-") else {
                error = "Connect directly to this resource's host to browse its URLs."
                return
            }
            preview = Preview(url: url)
            return
        }
        isDownloading = true
        download = Task { @MainActor in
            defer { isDownloading = false }
            do {
                let file = try await FilePreviewDownload.download(offer) { offset in
                    let response = try await coordinator.sendWorktreeManagement(
                        .openResource(worktreeID: worktree, request: .read(id: offer.id, offset: offset)),
                        to: host
                    )
                    switch response {
                    case .openResource(.chunk(let data)): return data
                    case .error(_, let message, _, _): throw PreviewError(message: message)
                    default: throw FilePreviewDownload.Failure.invalidChunk
                    }
                }
                guard !Task.isCancelled else { FilePreviewDownload.remove(file); return }
                removeCachedFile()
                cachedFile = file
                preview = Preview(url: file)
            } catch {
                if !Task.isCancelled { self.error = error.localizedDescription }
            }
        }
    }

    private struct PreviewError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }
}

/// Apple owns rendering and the share/open-in UI, including for HTML and CSV.
struct NativeFilePreview: UIViewControllerRepresentable {
    let url: URL

    func makeCoordinator() -> Coordinator { Coordinator(url: url) }

    func makeUIViewController(context: Context) -> UIViewController {
        Self.makeController(url: url, dataSource: context.coordinator)
    }

    static func makeController(url: URL, dataSource: any QLPreviewControllerDataSource) -> UIViewController {
        if QLPreviewController.canPreview(url as NSURL) {
            let controller = QLPreviewController()
            controller.dataSource = dataSource
            return controller
        }
        let controller = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        controller.popoverPresentationController?.sourceView = controller.view
        return controller
    }

    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {}

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        let url: URL
        init(url: URL) { self.url = url }
        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }
        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> any QLPreviewItem {
            url as NSURL
        }
    }
}
#endif
