#if canImport(UIKit)
import GrafttyRemoteClient
import Network
import SwiftUI
import WebKit

struct HostBrowserView: View {
    let url: URL
    let host: Host
    let coordinator: RemoteConnectionCoordinator
    @Environment(\.dismiss) private var dismiss
    @StateObject private var browser = HostBrowserModel()

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
            .toolbar {
                ToolbarItemGroup(placement: .bottomBar) {
                    Button("Back", systemImage: "chevron.left") { browser.webView?.goBack() }
                        .disabled(browser.webView?.canGoBack != true)
                    Button("Forward", systemImage: "chevron.right") { browser.webView?.goForward() }
                        .disabled(browser.webView?.canGoForward != true)
                    Spacer()
                    Text("Via \(host.label)").font(.caption)
                    Button("Reload", systemImage: "arrow.clockwise") {
                        browser.error = nil
                        browser.webView?.reload()
                    }
                }
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .task { await browser.start(url: url, host: host, coordinator: coordinator) }
        .onDisappear { browser.stop() }
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
    private var proxy: BrowserProxy?

    func start(url: URL, host: Host, coordinator: RemoteConnectionCoordinator) async {
        do {
            guard ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
                  let connection = await coordinator.connection(for: host) else {
                error = "The paired host is unavailable."
                return
            }
            let proxy = try BrowserProxy { socket, host, port in
                try await connection.openBrowserTunnel(socket, host: host, port: port)
            }
            self.proxy = proxy
            let port = try await proxy.start()
            guard !Task.isCancelled else { proxy.stop(); return }
            let configuration = HostBrowserProxyConfiguration.make(
                proxy: proxy,
                port: port,
                dataStoreIdentifier: host.id
            )
            let view = WKWebView(frame: .zero, configuration: configuration)
            view.navigationDelegate = self
            view.uiDelegate = self
            webView = view
            view.load(URLRequest(url: url))
        } catch {
            self.error = error.localizedDescription
            proxy?.stop()
        }
    }

    func stop() {
        webView?.stopLoading()
        webView = nil
        proxy?.stop()
        proxy = nil
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
