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
    var managementTransport: ((WorktreeManagementRequest, Host) async throws -> WorktreeManagementResponse)? = nil
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
    @State private var showingPreview = false
    @State private var cachedFile: URL?
    @State private var error: String?
    @State private var choosingResource = false
    let isPaneOwner: () -> Bool
    let canPresentAuthentication: () -> Bool
    @Binding var terminalRequest: TerminalBrowserRequest?
    @State private var operationID = UUID()
    @State var chromePresentation = ChromeOfferPresentation()

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

    static func floatingControl(availableCount: Int, isBusy: Bool,
                                action: @escaping () -> Void) -> some View {
        TerminalFloatingGlyphButton(systemName: "globe", accessibilityLabel: "Browser",
                                    isBusy: isBusy, action: action)
            .overlay(alignment: .topTrailing) {
                if availableCount > 0 {
                    Text("\(availableCount)").font(.caption2.monospacedDigit())
                        .padding(4).background(.tint, in: Circle()).foregroundStyle(.white)
                        .offset(x: 4, y: -4)
                        .accessibilityHidden(true)
                        .allowsHitTesting(false)
                }
            }
            .accessibilityValue("\(availableCount) available resources")
    }

    var body: some View {
        let actionID = operationID
        ZStack {
            Color.clear.frame(width: 44, height: 44)
                .allowsHitTesting(false).accessibilityHidden(true)
            if isActive, isPaneOwner() || !offers.isEmpty {
                Self.floatingControl(availableCount: offers.count, isBusy: isDownloading) {
                    if let offer = RemoteOpenPresentation.directBrowserOffer(in: offers) { open(offer, actionID: actionID) }
                    else if !offers.isEmpty { choosingResource = true }
                    else { openChromeTabs(actionID: actionID) }
                }
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
                cancelPresentation()
            }
        }
        .onChange(of: isActive) { _, active in
            if active { checkOwnership() } else {
                offerSnapshot = .init(); choosingResource = false; cancelOperation()
                if !chromePresentation.isMounted { cancelPresentation() }
            }
        }
        .onChange(of: ownerDeviceID) { _, _ in
            offerSnapshot = .init(); choosingResource = false; cancelOperation()
            if preview?.browser == true { cancelPresentation() }
            checkOwnership()
        }
        .onChange(of: hasOwnershipSnapshot) { _, _ in checkOwnership() }
        .onChange(of: isPaneFocused) { _, focused in
            if !focused, preview?.browser == true { cancelPresentation() }
        }
        .task(id: PollTaskScope(route: pollScope, ownerDeviceID: ownerDeviceID, active: isActive)) {
            guard isActive else { return }
            while !Task.isCancelled {
                do {
                    let response = try await sendWorktreeManagement(
                        .openResource(worktreeID: worktree, request: .list), to: host
                    )
                    guard !Task.isCancelled else { return }
                    if case .openResource(.offers(let value)) = response {
                        offerSnapshot.update(value, in: browserScope)
                        let authentication = coordinator.consumeAuthenticationOffer(value, sessionName: sessionName,
                                                                           ownerDeviceID: ownerDeviceID,
                                                                           canPresent: isPaneFocused && isPaneOwner() && preview == nil && chromePresentation.canPresent && !isDownloading && error == nil && canPresentAuthentication())
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
        .background {
            if let item = preview {
                ResourcePreviewSheet(isPresented: Binding(
                    get: { preview?.id == item.id && showingPreview },
                    set: { if preview?.id == item.id { showingPreview = $0 } }
                ), didMount: { markMounted(item) }, didDismiss: { finishPresentation(item.id) },
                   didDetach: { if chromePresentation.presentationID == item.id { cancelPresentation(abandon: true) } }) {
                    previewContent(item)
                }
                .id(item.id)
            }
        }
        .task(id: preview?.id) {
            guard let id = preview?.id else { return }
            do { try await Task.sleep(for: .seconds(3)) } catch { return }
            guard preview?.id == id, !chromePresentation.isMounted else { return }
            cancelPresentation()
            if isActive {
                error = "The resource could not be presented. Close any other dialog and tap Browser to try again."
            }
        }

        .alert("Could not open resource", isPresented: Binding(
            get: { error != nil }, set: { if !$0 { error = nil } }
        )) {
            Button("OK") { error = nil }
        } message: {
            Text(error ?? "")
        }
        .onAppear {
            if preview == nil, !chromePresentation.isMounted { apply(chromePresentation.cancelPending()) }
        }
        .onDisappear {
            cancelOperation()
            // SwiftUI also relays disappearance while the mounted sheet or a
            // system modal covers its source. Attachment owns mounted cleanup.
            if !chromePresentation.isMounted { cancelPresentation() }
        }
    }

    @ViewBuilder
    private func previewContent(_ preview: Preview) -> some View {
        if preview.browser {
            let originHost = preview.originHost ?? host
            let originWorktree = preview.originWorktree ?? worktree
            BrowserModeView(target: preview.originSession ?? sessionName, hostID: originHost.id,
                            connectionProvider: { await coordinator.connection(for: originHost) },
                            originalURL: preview.url, authenticate: { url in
                                try await WorktreePortClient.authenticate(url, in: originWorktree) { request in
                                    try await sendWorktreeManagement(request, to: originHost)
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


    private func sendWorktreeManagement(_ request: WorktreeManagementRequest, to host: Host) async throws -> WorktreeManagementResponse {
        if let managementTransport { return try await managementTransport(request, host) }
        return try await coordinator.sendWorktreeManagement(request, to: host)
    }

    private func openTerminalLink(_ request: TerminalBrowserRequest) {
        guard request.canPresent(in: browserScope, isActive: isActive && isPaneFocused, isOwner: isPaneOwner()) else {
            error = "Take control of the originating pane and try the link again."
            return
        }
        guard canBegin() else { return }
        cancelOperation()
        present(Preview(url: request.url, browser: true, originSession: request.scope.sessionName,
                        originWorktree: request.scope.worktree,
                        chromeLaunch: ChromeTabInitialLaunch(id: request.id, url: request.url.absoluteString), originHost: host), offerID: nil)
    }

    private func openChromeTabs(actionID: UUID? = nil) {
        guard canBegin(actionID: actionID) else { return }
        guard isPaneOwner() else {
            error = "Take control of this pane before opening its remote browser."
            return
        }
        present(Preview(url: nil, browser: true, originSession: sessionName, originWorktree: worktree, originHost: host), offerID: nil)
    }

    private func canBegin(actionID: UUID? = nil, automatically: Bool = false, offerID: UUID? = nil) -> Bool {
        let reason: String?
        if let actionID, actionID != operationID {
            reason = "This browser action changed. Tap Browser again to refresh it."
        } else if !isActive || !isPaneFocused || !browserConnectionReady || !canPresentAuthentication() {
            reason = "Reconnect and unlock the originating pane, then tap Browser again."
        } else if preview != nil || !chromePresentation.canPresent {
            reason = "A resource is opening or closing. Wait a moment and tap Browser again."
        } else { reason = nil }
        guard let reason else { return true }
        if let offerID { coordinator.deferAuthenticationOffer(offerID) }
        if !automatically { error = reason }
        return false
    }

    private func present(_ item: Preview, offerID: UUID?) {
        guard chromePresentation.begin(offerID, presentationID: item.id) else {
            error = "A resource is opening or closing. Wait a moment and tap Browser again."
            if let offerID { coordinator.deferAuthenticationOffer(offerID) }
            return
        }
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        preview = item
        showingPreview = true
    }

    private func markMounted(_ item: Preview) -> Bool {
        guard preview?.id == item.id else { return false }
        guard isActive || chromePresentation.isMounted, !item.browser || (isPaneFocused && isPaneOwner()) else {
            cancelPresentation()
            return false
        }
        return chromePresentation.markMounted(item.id)
    }

    private func finishPresentation(_ id: UUID) {
        guard chromePresentation.presentationID == id else { return }
        apply(chromePresentation.finishDismissal(id))
        preview = nil; showingPreview = false
        removeCachedFile()
    }

    private func cancelPresentation(abandon: Bool = false) {
        guard let id = chromePresentation.presentationID else { return }
        if let offerID = chromePresentation.deferCurrent() { coordinator.deferAuthenticationOffer(offerID) }
        showingPreview = false
        if abandon { apply(chromePresentation.finishDismissal(id)) }
        else { apply(chromePresentation.cancelPending()) }
        if chromePresentation.canPresent { preview = nil; removeCachedFile() }
    }

    private func apply(_ dismissal: ChromeOfferPresentation.Dismissal?) {
        switch dismissal {
        case .dismissed(let id): coordinator.dismissAuthenticationOffer(id)
        case .deferred(let id): coordinator.deferAuthenticationOffer(id)
        case nil: break
        }
    }

    private func checkOwnership() {
        if isActive, hasOwnershipSnapshot, !isPaneOwner(), preview?.browser == true {
            cancelPresentation()
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
        guard canBegin(actionID: actionID, automatically: automatically, offerID: offer.id) else { return }
        guard offers.contains(offer) else {
            coordinator.deferAuthenticationOffer(offer.id)
            if !automatically { error = "This resource is no longer available. Wait for the list to refresh and tap Browser again." }
            return
        }
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
                present(Preview(url: url, browser: true, originSession: sessionName, originWorktree: worktree,
                                chromeLaunch: ChromeTabInitialLaunch(offer: offer), originHost: host), offerID: offer.id)
                return
            }
            if isPaneOwner() {
                present(Preview(url: url, browser: true, originSession: sessionName, originWorktree: worktree,
                                chromeLaunch: ChromeTabInitialLaunch(offer: offer), originHost: host), offerID: offer.id)
            } else { present(Preview(url: url, originHost: host), offerID: offer.id) }
            return
        }
        isDownloading = true
        download = Task { @MainActor in
            defer { if operationID == currentOperation { isDownloading = false } }
            do {
                let file = try await FilePreviewDownload.download(offer) { offset in
                    let response = try await sendWorktreeManagement(
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
                guard chromePresentation.canPresent, preview == nil else {
                    FilePreviewDownload.remove(file)
                    self.error = "Another resource is opening. Tap Browser again after it closes."
                    return
                }
                removeCachedFile()
                cachedFile = file
                present(Preview(url: file), offerID: nil)
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

/// Each sheet owns immutable callbacks, even if a pending request is abandoned
/// and its replacement is reserved before SwiftUI delivers the old callbacks.
private struct ResourcePreviewSheet<Content: View>: View {
    @Binding var isPresented: Bool
    let didMount: () -> Bool
    let didDismiss: () -> Void
    let didDetach: () -> Void
    @ViewBuilder let content: () -> Content
    var body: some View {
        ResourcePreviewAttachment(didDetach: didDetach).frame(width: 0, height: 0)
            .sheet(isPresented: $isPresented, onDismiss: didDismiss) {
                MountedResourceContent(didMount: didMount, content: content())
            }
    }
}

/// Actual host removal ends a reservation. Covering the source with a system
/// modal or changing scene activity does not remove its hosting controller.
private struct ResourcePreviewAttachment: UIViewControllerRepresentable {
    let didDetach: () -> Void
    func makeUIViewController(context: Context) -> Anchor { Anchor() }
    func updateUIViewController(_ anchor: Anchor, context: Context) { anchor.didDetach = didDetach }
    static func dismantleUIViewController(_ anchor: Anchor, coordinator: ()) {
        let callback = anchor.didDetach
        anchor.didDetach = nil
        Task { @MainActor in callback?() }
    }

    final class Anchor: UIViewController {
        var didDetach: (() -> Void)?
        private weak var attachedWindow: UIWindow?
        private var wasAttached = false
        override func loadView() {
            let view = AttachmentView()
            view.windowChanged = { [weak self] in self?.windowChanged() }
            self.view = view
        }
        private func windowChanged() {
            if let window = view.window { attachedWindow = window; wasAttached = true; return }
            guard wasAttached else { return }
            // The parent chain finishes changing after didMoveToWindow(nil).
            Task { @MainActor [weak self] in
                guard let self, view.window == nil else { return }
                if let window = attachedWindow {
                    var root: UIViewController = self
                    while let parent = root.parent { root = parent }
                    guard root !== window.rootViewController else { return }
                }
                didDetach?()
            }
        }
    }
    private final class AttachmentView: UIView {
        var windowChanged: (() -> Void)?
        override func didMoveToWindow() { super.didMoveToWindow(); windowChanged?() }
    }
}

private struct MountedResourceContent<Content: View>: View {
    let didMount: () -> Bool
    let content: Content
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        content.onAppear { if !didMount() { dismiss() } }
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
