#if canImport(UIKit)
import GrafttyProtocol
import GrafttyRemoteClient
import SafariServices
import SwiftUI
import UIKit

/// Remote state stays on the Mac. Local Safari starts its own page and cookie state.
@MainActor
struct BrowserModeView: View {
    let target: String
    let hostID: UUID
    let connectionProvider: RemoteConnectionProvider
    let originalURL: URL?
    let authenticate: (URL) async throws -> WorktreePortClient.AuthenticationPreview
    let isPaneOwner: () -> Bool
    var initialLaunch: ChromeTabInitialLaunch? = nil
    var paneReady = true
    var onLaunch: () -> Void = {}
    @State private var local: LocalBrowserController

    init(target: String, hostID: UUID, connectionProvider: @escaping RemoteConnectionProvider,
         originalURL: URL?, authenticate: @escaping (URL) async throws -> WorktreePortClient.AuthenticationPreview,
         isPaneOwner: @escaping () -> Bool, initialLaunch: ChromeTabInitialLaunch? = nil,
         paneReady: Bool = true, onLaunch: @escaping () -> Void = {},
         local: LocalBrowserController? = nil) {
        self.target = target; self.hostID = hostID; self.connectionProvider = connectionProvider
        self.originalURL = originalURL; self.authenticate = authenticate; self.isPaneOwner = isPaneOwner
        self.initialLaunch = initialLaunch; self.paneReady = paneReady; self.onLaunch = onLaunch
        self._local = State(initialValue: local ?? LocalBrowserController())
    }
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.biometricGate) private var gate
    private var ready: Bool {
        paneReady && !LiveSessionReadiness.shouldSuspendTransport(scene: scenePhase) && gate.isUnlocked
    }

    var body: some View {
        let provider = connectionProvider
        ChromeTabViewer(target: target, connectionProvider: provider, initialLaunch: initialLaunch,
                        paneReady: paneReady, onLaunch: onLaunch,
                        onChooseLocal: { selectedURL in
                            do {
                                let url = try LocalBrowserSelection.url(originalOffer: originalURL, selectedPage: selectedURL)
                                local.open(url: url, hostID: hostID, makeTunnel: {
                                    guard let connection = await provider() else { return nil }
                                    return LocalBrowserTunnel(isConnected: { await connection.state == .connected },
                                                              connect: { socket, host, port, reply in
                                        try await connection.openBrowserTunnel(socket, host: host, port: port, handshakeReply: reply)
                                    })
                                }, authenticate: authenticate, isPaneOwner: isPaneOwner)
                            } catch {
                                local.stop(reason: (error as? LocalBrowserSession.Failure)?.message ?? "Local mode is unavailable for this page.")
                            }
                        }, localPreparing: local.session.preparing, localError: local.session.error)
            .background {
                SafariModalPresenter(url: local.session.url,
                                     onFinish: { local.stop() },
                                     onExternalBrowser: { local.stop(reason: "Local browsing paused. Return here and select Local again to reconnect the callback.") },
                                     onFailure: { local.stop(reason: "Safari could not be presented. Select Local to try again.") })
                    .frame(width: 0, height: 0)
            }
            .onChange(of: ready, initial: true) { _, value in
                local.allowed = value
                if !value {
                    local.stop(reason: local.session.url != nil || local.session.preparing
                               ? "Local browsing paused. Reconnect with pane control to continue." : local.session.error)
                }
            }
    }
}

struct LocalBrowserTunnel: Sendable {
    let isConnected: @Sendable () async -> Bool
    let connect: HostBrowserNetwork.Connector
}

@MainActor @Observable
final class LocalBrowserController {
    let network: HostBrowserNetwork
    let session: LocalBrowserSession
    var allowed = false
    private var owner: () -> Bool = { false }
    private var attempt: UUID?
    private var task: Task<Void, Never>?
    private var connectionWatch: Task<Void, Never>?

    init() {
        let network = HostBrowserNetwork()
        self.network = network
        session = LocalBrowserSession(release: { network.stop() })
    }

    func open(url: URL, hostID: UUID, makeTunnel: @escaping () async -> LocalBrowserTunnel?,
              authenticate: @escaping (URL) async throws -> WorktreePortClient.AuthenticationPreview,
              isPaneOwner: @escaping () -> Bool) {
        guard allowed, isPaneOwner(), !session.preparing, session.url == nil else { return }
        stop()
        owner = isPaneOwner
        let attempt = UUID()
        self.attempt = attempt
        task = Task { [weak self] in
            guard let self else { return }
            var callbackHost: String?
            var tunnel: LocalBrowserTunnel?
            await session.open(originalURL: url, isAllowed: { self.allowed && self.owner() }, authorize: {
                guard ["https", "http"].contains(url.scheme?.lowercased() ?? "") else {
                    throw LocalBrowserSession.Failure(message: "Local browsing supports HTTP and HTTPS pages.")
                }
                let redirects = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.filter { $0.name == "redirect_uri" } ?? []
                let hasLoopbackRedirect = redirects.contains { item in
                    guard let value = item.value, let redirect = URL(string: value) else { return false }
                    return WorktreeAuthenticationURL.isLoopbackHost(redirect.host ?? "")
                }
                if hasLoopbackRedirect, WorktreeAuthenticationURL(url: url) == nil {
                    throw LocalBrowserSession.Failure(message: "This page has an unsupported local callback. Continue in Remote mode.")
                }
                if WorktreeAuthenticationURL(url: url) != nil {
                    let approval = try await authenticate(url)
                    callbackHost = approval.callbackHost
                    return approval.url
                }
                return url
            }, prepare: { approved in
                let needsTunnel = callbackHost != nil || WorktreeAuthenticationURL.isLoopbackHost(approved.host ?? "")
                if needsTunnel {
                    tunnel = await makeTunnel()
                    try self.checkCurrent(attempt)
                    guard let tunnel, await tunnel.isConnected() else {
                        throw LocalBrowserSession.Failure(message: "The originating Mac is disconnected.")
                    }
                    try self.checkCurrent(attempt)
                    do {
                        try await self.network.startLocalPage(url: approved, hostID: hostID, callbackHost: callbackHost) { [weak self] socket, host, port, reply in
                            guard let self, await self.callbackAllowed(attempt) else { throw CancellationError() }
                            do {
                                try await tunnel.connect(socket, host, port, reply)
                            } catch {
                                await self.callbackFailed(attempt)
                                throw error
                            }
                        }
                    } catch {
                        throw LocalBrowserSession.Failure(message: "The callback port could not open. Close any browser using that phone port and try Local again.")
                    }
                }
            })
            if let tunnel, session.url != nil, self.attempt == attempt {
                connectionWatch = Task { [weak self] in
                    while !Task.isCancelled {
                        guard let self, self.attempt == attempt else { return }
                        let connected = await tunnel.isConnected()
                        guard !Task.isCancelled, self.attempt == attempt else { return }
                        if !connected {
                            self.stop(reason: "Local browsing paused because the Mac disconnected. Select Local after reconnecting.")
                            return
                        }
                        do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
                    }
                }
            }
        }
    }

    private func checkCurrent(_ attempt: UUID) throws {
        try Task.checkCancellation()
        guard callbackAllowed(attempt) else { throw CancellationError() }
    }
    private func callbackAllowed(_ attempt: UUID) -> Bool {
        self.attempt == attempt && allowed && owner()
    }
    private func callbackFailed(_ attempt: UUID) {
        guard self.attempt == attempt else { return }
        stop(reason: "The host callback connection failed. Reconnect and select Local to try again.")
    }
    func stop(reason: String? = nil) {
        attempt = nil
        task?.cancel(); task = nil
        connectionWatch?.cancel(); connectionWatch = nil
        session.stop(reason: reason)
    }
}

/// UIKit presents Safari modally, without embedding or overlaying its system chrome.
struct SafariModalPresenter: UIViewControllerRepresentable {
    let url: URL?
    let onFinish: () -> Void
    let onExternalBrowser: () -> Void
    let onFailure: () -> Void

    func makeUIViewController(context: Context) -> Anchor { Anchor() }
    func updateUIViewController(_ anchor: Anchor, context: Context) {
        anchor.onFinish = onFinish
        anchor.onExternalBrowser = onExternalBrowser
        anchor.onFailure = onFailure
        anchor.url = url
        anchor.presentIfReady()
    }
    static func dismantleUIViewController(_ anchor: Anchor, coordinator: ()) {
        anchor.close()
        anchor.onFinish?()
    }

    final class Anchor: UIViewController, SFSafariViewControllerDelegate {
        var url: URL?
        var onFinish: (() -> Void)?
        var onExternalBrowser: (() -> Void)?
        var onFailure: (() -> Void)?
        private var safari: SFSafariViewController?
        override func viewDidAppear(_ animated: Bool) { super.viewDidAppear(animated); presentIfReady() }
        func presentIfReady() {
            guard let url else { close(); return }
            guard safari == nil, view.window != nil, presentedViewController == nil else { return }
            let safari = SFSafariViewController(url: url)
            safari.delegate = self
            safari.dismissButtonStyle = .done
            safari.modalPresentationStyle = .fullScreen
            self.safari = safari
            present(safari, animated: true)
            Task { @MainActor [weak self, weak safari] in
                try? await Task.sleep(for: .seconds(2))
                guard let self, let safari, self.safari === safari else { return }
                if safari.presentingViewController == nil { self.onFailure?(); self.close() }
            }
        }
        func close() {
            url = nil
            safari?.delegate = nil
            safari?.dismiss(animated: false)
            safari = nil
        }
        func safariViewControllerDidFinish(_ controller: SFSafariViewController) { onFinish?(); close() }
        func safariViewControllerWillOpenInBrowser(_ controller: SFSafariViewController) { onExternalBrowser?(); close() }
    }
}
#endif
