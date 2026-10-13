#if canImport(UIKit)
import GrafttyProtocol
import QuickLook
import SwiftUI
import UIKit

/// One browser resource opens directly; multiple resources retain a selection menu.
struct RemoteOpenButton: View {
    let host: Host
    let worktree: String
    let coordinator: RemoteConnectionCoordinator
    let sessionName: String
    let ownerDeviceID: RemoteDeviceID?
    @State private var offers: [RemoteOpenOffer] = []
    @State private var download: Task<Void, Never>?
    @State private var isDownloading = false
    @State private var preview: Preview?
    @State private var cachedFile: URL?
    @State private var error: String?
    let isPaneOwner: () -> Bool
    let canPresentAuthentication: () -> Bool
    @State private var operationID = UUID()

    private var pollScope: PollScope {
        PollScope(worktree: worktree, sessionName: sessionName, ownerDeviceID: ownerDeviceID)
    }

    private struct Preview: Identifiable {
        let id = UUID()
        let url: URL
        var callbackHost: String? = nil
        var isAutomatic = false
    }

    private struct PollScope: Equatable {
        let worktree: String
        let sessionName: String
        let ownerDeviceID: RemoteDeviceID?
    }

    var body: some View {
        ZStack {
            if isDownloading {
                ProgressView("Opening resource…")
                    .padding(12)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
            } else if let offer = RemoteOpenPresentation.directBrowserOffer(in: offers) {
                Button { open(offer) } label: {
                    Label("Open", systemImage: "globe")
                        .padding(10)
                        .background(.regularMaterial, in: Capsule())
                }
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
        .onChange(of: pollScope) { _, _ in
            cancelOperation()
            if !isPaneOwner(), preview?.isAutomatic == true { preview = nil }
        }
        .task(id: pollScope) {
            while !Task.isCancelled {
                do {
                    let response = try await coordinator.sendWorktreeManagement(
                        .openResource(worktreeID: worktree, request: .list), to: host
                    )
                    guard !Task.isCancelled else { return }
                    if case .openResource(.offers(let value)) = response {
                        offers = value
                        let authentication = coordinator.consumeAuthenticationOffer(value, sessionName: sessionName,
                                                                           ownerDeviceID: ownerDeviceID,
                                                                           canPresent: preview == nil && !isDownloading && canPresentAuthentication())
                        if let authentication { open(authentication, automatically: true) }
                    }
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
                HostBrowserView(url: preview.url, host: host, callbackHost: preview.callbackHost,
                                connectionProvider: { await coordinator.connection(for: host) })
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
            cancelOperation()
            preview = nil
            removeCachedFile()
        }
    }

    private func cancelOperation() {
        operationID = UUID()
        download?.cancel()
        download = nil
        isDownloading = false
    }

    private func removeCachedFile() {
        if let cachedFile { FilePreviewDownload.remove(cachedFile) }
        cachedFile = nil
    }

    private func open(_ offer: RemoteOpenOffer, automatically: Bool = false) {
        cancelOperation()
        let currentOperation = operationID
        if let url = offer.url {
            guard !worktree.hasPrefix("relay-worktree-") else {
                error = "Connect directly to this resource's host to browse its URLs."
                return
            }
            if !WorktreeAuthenticationURL.isLoopbackHost(url.host ?? ""), WorktreeAuthenticationURL(url: url) != nil {
                isDownloading = true
                download = Task { @MainActor in
                    defer { if operationID == currentOperation { isDownloading = false } }
                    do {
                        let authentication = try await WorktreePortClient.authenticate(url, in: worktree) { request in
                            try await coordinator.sendWorktreeManagement(request, to: host)
                        }
                        guard !Task.isCancelled, operationID == currentOperation,
                              !automatically || isPaneOwner() else { return }
                        if automatically && !canPresentAuthentication() {
                            coordinator.deferAuthenticationOffer(offer.id)
                            return
                        }
                        preview = Preview(url: authentication.url, callbackHost: authentication.callbackHost, isAutomatic: automatically)
                    } catch {
                        if !Task.isCancelled, operationID == currentOperation { self.error = error.localizedDescription }
                    }
                }
                return
            }
            preview = Preview(url: url)
            return
        }
        isDownloading = true
        download = Task { @MainActor in
            defer { if operationID == currentOperation { isDownloading = false } }
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
                guard !Task.isCancelled, operationID == currentOperation else { FilePreviewDownload.remove(file); return }
                removeCachedFile()
                cachedFile = file
                preview = Preview(url: file)
            } catch {
                if !Task.isCancelled, operationID == currentOperation { self.error = error.localizedDescription }
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
