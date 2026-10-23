#if canImport(UIKit)
import GrafttyRemoteClient
import Network
import SwiftUI
import WebKit

struct HostBrowserView: View {
    let url: URL
    let host: Host
    let connectionProvider: RemoteConnectionProvider
    let callbackHost: String?
    @Environment(\.dismiss) private var dismiss
    @StateObject private var browser = HostBrowserModel()

    init(url: URL, host: Host, coordinator: RemoteConnectionCoordinator) {
        self.init(url: url, host: host, connectionProvider: { await coordinator.connection(for: host) })
    }

    init(url: URL, host: Host, callbackHost: String? = nil, connectionProvider: @escaping RemoteConnectionProvider) {
        self.url = url
        self.host = host
        self.connectionProvider = connectionProvider
        self.callbackHost = callbackHost
    }

    var body: some View {
        NavigationStack {
            Group {
                if let view = browser.webView { HostWebView(view: view) }
                else { ProgressView("Connecting through host…") }
            }
            .overlay {
                if let error = browser.error {
                    ContentUnavailableView("Could not load page", systemImage: "network.slash", description: Text(error))
                }
            }
            .navigationTitle(browser.webView?.url?.host ?? url.host ?? "Browser")
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                HostBrowserControls(hostLabel: host.label,
                    canGoBack: browser.webView?.canGoBack == true,
                    canGoForward: browser.webView?.canGoForward == true,
                    onBack: { browser.webView?.goBack() },
                    onForward: { browser.webView?.goForward() },
                    onReload: { browser.error = nil; browser.webView?.reload() })
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }.font(.body)
                }
            }
        }
        .task { await browser.start(url: url, host: host, callbackHost: callbackHost, connectionProvider: connectionProvider) }
        .onDisappear { browser.stop() }
    }
}

struct HostBrowserControls: View {
    let hostLabel: String
    let canGoBack: Bool
    let canGoForward: Bool
    let onBack: () -> Void
    let onForward: () -> Void
    let onReload: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            button("Back", symbol: "chevron.left", action: onBack).disabled(!canGoBack)
            button("Forward", symbol: "chevron.right", action: onForward).disabled(!canGoForward)
            Text("Via \(hostLabel)").font(.caption).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.middle)
                .frame(maxWidth: .infinity)
            button("Reload", symbol: "arrow.clockwise", action: onReload)
        }
        .padding(.horizontal, 12).padding(.vertical, 4)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
        .frame(minWidth: 1000) // Temporary mutation: toolbar cannot fit compact widths.
    }

    private func button(_ label: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.body)
                .frame(width: 44, height: 44).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityLabel(label)
    }
}

private struct HostWebView: UIViewRepresentable {
    let view: WKWebView
    func makeUIView(context: Context) -> WKWebView { view }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

@MainActor
enum HostBrowserProxyConfiguration {
    static func make(
        proxy: BrowserProxy,
        port: UInt16,
        dataStoreIdentifier: UUID
    ) -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        // This is GrafttyMobile's own per-host browser state. It never imports
        // cookies or other storage from a browser on the Mac.
        let store = WKWebsiteDataStore(forIdentifier: dataStoreIdentifier)
        var settings = ProxyConfiguration(socksv5Proxy: .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!))
        settings.applyCredential(username: proxy.username, password: proxy.password)
        settings.allowFailover = false
        settings.matchDomains = ["", "localhost", "127.0.0.1", "::1"]
        settings.excludedDomains = []
        store.proxyConfigurations = [settings]
        configuration.websiteDataStore = store
        return configuration
    }
}

@MainActor
private final class HostBrowserModel: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate {
    @Published var webView: WKWebView?
    @Published var error: String?
    private let network = HostBrowserNetwork()
    private var operation: UUID?

    func start(url: URL, host: Host, callbackHost: String?, connectionProvider: RemoteConnectionProvider) async {
        stop()
        let operation = UUID()
        self.operation = operation
        error = nil
        do {
            guard ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
                error = "Only HTTP and HTTPS pages are supported."
                return
            }
            let connection = await connectionProvider()
            guard self.operation == operation, !Task.isCancelled else { return }
            guard let connection else {
                error = "The paired host is unavailable."
                return
            }
            let configuration = try await network.start(url: url, dataStoreIdentifier: host.id, callbackHost: callbackHost) { socket, host, port, reply in
                try await connection.openBrowserTunnel(socket, host: host, port: port, handshakeReply: reply)
            }
            guard self.operation == operation, !Task.isCancelled else { return }
            let view = WKWebView(frame: .zero, configuration: configuration)
            view.navigationDelegate = self
            view.uiDelegate = self
            webView = view
            view.load(URLRequest(url: url))
        } catch {
            guard self.operation == operation, !Task.isCancelled else { return }
            self.error = error.localizedDescription
        }
    }

    func stop() {
        operation = nil
        webView?.stopLoading()
        webView = nil
        network.stop()
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        error = nil
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        error = nil
        objectWillChange.send()
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        self.error = error.localizedDescription
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        self.error = error.localizedDescription
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        let scheme = navigationAction.request.url?.scheme?.lowercased()
        decisionHandler(scheme == "http" || scheme == "https" ? .allow : .cancel)
    }
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if navigationAction.targetFrame == nil,
           ["http", "https"].contains(navigationAction.request.url?.scheme?.lowercased() ?? "") {
            webView.load(navigationAction.request)
        }
        return nil
    }
}
#endif
