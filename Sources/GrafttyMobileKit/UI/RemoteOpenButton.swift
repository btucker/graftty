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
    let isActive: Bool
    let browserConnectionReady: Bool
    let isPaneFocused: Bool
    let hasOwnershipSnapshot: Bool
    @State private var offerSnapshot = RemoteOpenPresentation.ScopedOffers()
    private var browserScope: TerminalBrowserRequest.Scope {
        .init(hostID: host.id, worktree: worktree, sessionName: sessionName, ownerDeviceID: ownerDeviceID)
    }
    private var offers: [RemoteOpenOffer] { offerSnapshot.offers(in: browserScope) }
    @State private var download: Task<Void, Never>?
    @State private var isDownloading = false
    @State private var preview: Preview?
    @State private var cachedFile: URL?
    @State private var error: String?
    @State private var choosingResource = false
    let isPaneOwner: () -> Bool
    let canPresentAuthentication: () -> Bool
    @Binding var terminalRequest: TerminalBrowserRequest?
    @State private var operationID = UUID()
    @State private var chromePresentation = ChromeOfferPresentation()

    private var pollScope: PollScope {
        PollScope(hostID: host.id, worktree: worktree, sessionName: sessionName)
    }

    private struct Preview: Identifiable {
        let id = UUID()
        let url: URL?
        var browser = false
        var originSession: String? = nil
        var originWorktree: String? = nil
        var chromeLaunch: ChromeTabInitialLaunch? = nil
        var originHost: Host? = nil
    }

    private struct PollScope: Equatable {
        let hostID: UUID
        let worktree: String
        let sessionName: String
    }

    private struct PollTaskScope: Equatable {
        let route: PollScope
        let ownerDeviceID: RemoteDeviceID?
        let active: Bool
    }

    var body: some View {
        let actionID = operationID
        Group {
            if isActive, isPaneOwner() || !offers.isEmpty {
                Button {
                    if let offer = RemoteOpenPresentation.directBrowserOffer(in: offers) { open(offer, actionID: actionID) }
                    else if !offers.isEmpty { choosingResource = true }
                    else { openChromeTabs(actionID: actionID) }
                } label: {
                    ZStack(alignment: .topTrailing) {
                        Group {
                            if isDownloading { ProgressView() }
                            else { Image(systemName: "globe") }
                        }
                        .frame(width: 44, height: 44)
                        .background(.regularMaterial, in: Circle())
                        if !offers.isEmpty {
                            Text("\(offers.count)").font(.caption2.monospacedDigit())
                                .padding(4).background(.tint, in: Circle()).foregroundStyle(.white)
                                .offset(x: 4, y: -4)
                        }
                    }
                }
                .accessibilityLabel("Browser")
                .accessibilityValue("\(offers.count) available resources")
                .accessibilityAction(named: "Remote Chrome tabs") { openChromeTabs(actionID: actionID) }
                .contextMenu {
                    Button("Remote Chrome tabs", systemImage: "rectangle.on.rectangle") { openChromeTabs(actionID: actionID) }
                        .disabled(!isPaneOwner())
                    ForEach(offers) { offer in Button(offer.filename) { open(offer, actionID: actionID) } }
                }
                .disabled(isDownloading)
            }
        }
        .confirmationDialog("Browser resources", isPresented: $choosingResource) {
            Button("Remote Chrome tabs") { openChromeTabs(actionID: actionID) }.disabled(!isPaneOwner())
            ForEach(offers) { offer in Button(offer.filename) { open(offer, actionID: actionID) } }
        }
        .onChange(of: terminalRequest?.id, initial: true) { _, _ in
            guard let request = terminalRequest else { return }
            terminalRequest = nil
            openTerminalLink(request)
        }
        .onChange(of: pollScope) { _, _ in
            offerSnapshot = .init()
            choosingResource = false
            cancelOperation()
            if preview?.browser == true {
                deferAuthenticationPresentation()
                preview = nil
            }
        }
        .onChange(of: isActive) { _, active in
            if active { checkOwnership() } else { offerSnapshot = .init(); choosingResource = false; cancelOperation() }
        }
        .onChange(of: ownerDeviceID) { _, _ in
            offerSnapshot = .init(); choosingResource = false; cancelOperation(); checkOwnership()
        }
        .onChange(of: hasOwnershipSnapshot) { _, _ in checkOwnership() }
        .onChange(of: isPaneFocused) { _, focused in
            if !focused, preview?.browser == true { deferAuthenticationPresentation(); preview = nil }
        }
        .task(id: PollTaskScope(route: pollScope, ownerDeviceID: ownerDeviceID, active: isActive)) {
            guard isActive else { return }
            while !Task.isCancelled {
                do {
                    let response = try await coordinator.sendWorktreeManagement(
                        .openResource(worktreeID: worktree, request: .list), to: host
                    )
                    guard !Task.isCancelled else { return }
                    if case .openResource(.offers(let value)) = response {
                        offerSnapshot.update(value, in: browserScope)
                        let authentication = coordinator.consumeAuthenticationOffer(value, sessionName: sessionName,
                                                                           ownerDeviceID: ownerDeviceID,
                                                                           canPresent: isPaneFocused && isPaneOwner() && preview == nil && chromePresentation.canPresent && !isDownloading && canPresentAuthentication())
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
        .sheet(item: $preview, onDismiss: {
            switch chromePresentation.finishDismissal() {
            case .dismissed(let id): coordinator.dismissAuthenticationOffer(id)
            case .deferred(let id): coordinator.deferAuthenticationOffer(id)
            case nil: break
            }
            removeCachedFile()
        }) { preview in
            if preview.browser {
                let originHost = preview.originHost ?? host
                let originWorktree = preview.originWorktree ?? worktree
                BrowserModeView(target: preview.originSession ?? sessionName, hostID: originHost.id,
                                connectionProvider: { await coordinator.connection(for: originHost) },
                                originalURL: preview.url, authenticate: { url in
                                    try await WorktreePortClient.authenticate(url, in: originWorktree) { request in
                                        try await coordinator.sendWorktreeManagement(request, to: originHost)
                                    }
                                }, isPaneOwner: isPaneOwner, initialLaunch: preview.chromeLaunch,
                                paneReady: browserConnectionReady && isPaneFocused && isPaneOwner(), onLaunch: {
                                    if let launch = preview.chromeLaunch { coordinator.completeAuthenticationOffer(launch.offerID) }
                                })
            } else if let url = preview.url, url.isFileURL {
                NativeFilePreview(url: url)
            } else if let url = preview.url {
                HostBrowserView(url: url, host: preview.originHost ?? host,
                                connectionProvider: { await coordinator.connection(for: preview.originHost ?? host) })
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
            deferAuthenticationPresentation()
            preview = nil
            removeCachedFile()
        }
    }

    private func openTerminalLink(_ request: TerminalBrowserRequest) {
        let scope = browserScope
        guard request.canPresent(in: scope, isActive: isActive && isPaneFocused, isOwner: isPaneOwner()),
              canPresentAuthentication(), preview == nil, chromePresentation.begin(nil) else {
            error = "Take control of the originating pane and try the link again."
            return
        }
        cancelOperation()
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        preview = Preview(url: request.url, browser: true, originSession: request.scope.sessionName,
                          originWorktree: request.scope.worktree,
                          chromeLaunch: ChromeTabInitialLaunch(id: request.id, url: request.url.absoluteString), originHost: host)
    }

    private func openChromeTabs(actionID: UUID? = nil) {
        guard actionID == nil || actionID == operationID else { return }
        guard isActive, isPaneOwner(), canPresentAuthentication(), chromePresentation.begin(nil) else { return }
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        preview = Preview(url: nil, browser: true, originSession: sessionName, originWorktree: worktree, originHost: host)
    }

    private func deferAuthenticationPresentation() {
        if let id = chromePresentation.deferCurrent() { coordinator.deferAuthenticationOffer(id) }
    }

    private func checkOwnership() {
        if isActive, hasOwnershipSnapshot, !isPaneOwner(), preview?.browser == true {
            deferAuthenticationPresentation(); preview = nil
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

    private func open(_ offer: RemoteOpenOffer, automatically: Bool = false, actionID: UUID? = nil) {
        guard actionID == nil || actionID == operationID,
              offers.contains(offer), isActive, chromePresentation.canPresent else { return }
        cancelOperation()
        let currentOperation = operationID
        if let url = offer.url {
            guard RemoteOpenPresentation.belongsToPane(offer, sessionName: sessionName, ownerDeviceID: ownerDeviceID) else {
                coordinator.deferAuthenticationOffer(offer.id)
                if !automatically { error = "Open this link from its originating pane after taking control." }
                return
            }
            guard !worktree.hasPrefix("relay-worktree-") else {
                coordinator.deferAuthenticationOffer(offer.id)
                error = "Connect directly to this resource's host to browse its URLs."
                return
            }
            if !WorktreeAuthenticationURL.isLoopbackHost(url.host ?? ""), WorktreeAuthenticationURL(url: url) != nil {
                guard isPaneOwner(), ownerDeviceID != nil,
                      offer.paneSessionName == sessionName, offer.browserOwnerDeviceID == ownerDeviceID,
                      canPresentAuthentication() else {
                    coordinator.deferAuthenticationOffer(offer.id)
                    if !automatically { error = "Take control of the originating pane before starting sign-in." }
                    return
                }
                guard chromePresentation.begin(offer.id) else { return }
                preview = Preview(url: url, browser: true, originSession: sessionName, originWorktree: worktree,
                                  chromeLaunch: ChromeTabInitialLaunch(offer: offer), originHost: host)
                return
            }
            guard chromePresentation.begin(offer.id) else { return }
            if isPaneOwner() {
                preview = Preview(url: url, browser: true, originSession: sessionName, originWorktree: worktree,
                                  chromeLaunch: ChromeTabInitialLaunch(offer: offer), originHost: host)
            } else { preview = Preview(url: url, originHost: host) }
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
                guard isActive, !Task.isCancelled, operationID == currentOperation else { FilePreviewDownload.remove(file); return }
                guard chromePresentation.begin(nil) else { FilePreviewDownload.remove(file); return }
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
