#if canImport(UIKit)
import Foundation
import GrafttyRemoteClient
import Network
import SafariServices
import SwiftUI
import Testing
import UIKit
import WebKit
@testable import GrafttyMobileKit

@MainActor
@Suite(.serialized)
struct HostBrowserProxyTests {
    @Test("@spec PORTS-5.13: When the host browser loads a worktree URL, the application shall send WebKit's HTTP request through the paired host's authenticated tunnel and render the host's response.", .timeLimit(.minutes(1)), arguments: ["127.0.0.1", "localhost", "[::1]", "example.invalid"])
    func webKitLoadsLoopbackPageThroughProxy(targetHost: String) async throws {
        let url = URL(string: "http://\(targetHost):32123/")!
        let network = HostBrowserNetwork()
        defer { network.stop() }
        let configuration = try await network.start(url: url, dataStoreIdentifier: UUID()) { socket, host, port, reply in
            #expect(host == targetHost.trimmingCharacters(in: CharacterSet(charactersIn: "[]")))
            #expect(port == 32123)
            try await Self.servePage("graftty-tunneled-page", socket: socket, reply: reply)
        }
        try await expectPage("graftty-tunneled-page", url: url, configuration: configuration)
    }

    @Test("@spec PORTS-5.14: When a host browser sign-in page redirects to its loopback OAuth callback, the application shall forward the unchanged callback path and query through the same paired Mac.", .timeLimit(.minutes(1)))
    func authRedirectReachesTheHostCallback() async throws {
        let callback = URL(string: "http://127.0.0.1:32135/callback/mcp?code=test-code&state=test-state")!
        var authorization = URLComponents(string: "http://example.invalid:32134/authorize")!
        authorization.queryItems = [URLQueryItem(name: "redirect_uri", value: "http://127.0.0.1:32135/callback/mcp")]
        let network = HostBrowserNetwork()
        defer { network.stop() }
        let configuration = try await network.start(url: authorization.url!, dataStoreIdentifier: UUID()) { socket, host, port, reply in
            if !reply.isEmpty { try await BrowserProxy.send(reply, to: socket) }
            let request: Data = try await withCheckedThrowingContinuation { continuation in
                socket.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { data, _, _, error in
                    if let error { continuation.resume(throwing: error) }
                    else { continuation.resume(returning: data ?? Data()) }
                }
            }
            let text = String(decoding: request, as: UTF8.self)
            if host == "example.invalid" {
                #expect(port == 32134)
                let redirect = "HTTP/1.1 302 Found\r\nLocation: \(callback.absoluteString)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
                try await BrowserProxy.send(Data(redirect.utf8), to: socket)
            } else {
                #expect(host == "127.0.0.1" && port == 32135)
                #expect(text.hasPrefix("GET /callback/mcp?code=test-code&state=test-state HTTP/1.1"))
                let body = "mcp-sign-in-complete"
                let response = "HTTP/1.1 200 OK\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
                try await BrowserProxy.send(Data(response.utf8), to: socket)
            }
            socket.cancel()
        }
        try await expectPage("mcp-sign-in-complete", url: authorization.url!, configuration: configuration)
    }

    @Test func signInUsesPhoneNetworkingAndOnlyTunnelsItsCallback() async throws {
        let provider = try NWListener(using: .tcp, on: 32136)
        let callback = URL(string: "http://localhost:32137/callback?code=test&state=unchanged")!
        let queue = DispatchQueue(label: "graftty.auth.phone-provider.test")
        provider.newConnectionHandler = { socket in
            socket.start(queue: queue)
            Task {
                _ = try await Self.readRequest(from: socket)
                let response = "HTTP/1.1 302 Found\r\nLocation: \(callback.absoluteString)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
                try await BrowserProxy.send(Data(response.utf8), to: socket)
                socket.cancel()
            }
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            provider.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    provider.stateUpdateHandler = nil
                    continuation.resume()
                case .failed(let error):
                    provider.stateUpdateHandler = nil
                    continuation.resume(throwing: error)
                default: break
                }
            }
            provider.start(queue: queue)
        }
        defer { provider.cancel() }
        // This fixture serves the public provider locally on the simulated
        // phone. Production worktree auth rejects loopback provider origins.
        var authorization = URLComponents(string: "http://127.0.0.1:32136/authorize")!
        authorization.queryItems = [URLQueryItem(name: "redirect_uri", value: "http://localhost:32137/callback")]
        let network = HostBrowserNetwork()
        defer { network.stop() }
        let configuration = try await network.start(url: authorization.url!, dataStoreIdentifier: UUID(), callbackHost: "127.0.0.1") { socket, host, port, reply in
            #expect(host == "127.0.0.1" && port == 32137)
            #expect(reply.isEmpty)
            let request = try await Self.readRequest(from: socket)
            #expect(String(decoding: request, as: UTF8.self).hasPrefix("GET /callback?code=test&state=unchanged HTTP/1.1"))
            let body = "scoped-auth-complete"
            let response = "HTTP/1.1 200 OK\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
            try await BrowserProxy.send(Data(response.utf8), to: socket)
            socket.cancel()
        }
        #expect(configuration.websiteDataStore.proxyConfigurations.isEmpty)
        #expect(!configuration.websiteDataStore.isPersistent)
        try await expectPage("scoped-auth-complete", url: authorization.url!, configuration: configuration)
    }

    @Test("@spec CHROME-4.3: When a Local Safari sign-in redirects to the unchanged localhost callback, the application shall keep its foreground callback leases alive and forward the original request to the authorized host.", .timeLimit(.minutes(1)))
    func safariRedirectUsesOriginalLoopbackCallback() async throws {
        let provider = try NWListener(using: .tcp, on: 32181)
        let queue = DispatchQueue(label: "graftty.safari.fixture")
        let callback = URL(string: "http://localhost:32182/callback?code=fixture&state=unchanged")!
        provider.newConnectionHandler = { socket in
            socket.start(queue: queue)
            Task {
                do {
                    _ = try await Self.readRequest(from: socket)
                    let response = "HTTP/1.1 302 Found\r\nLocation: \(callback.absoluteString)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
                    try await BrowserProxy.send(Data(response.utf8), to: socket)
                } catch { }
                socket.cancel()
            }
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            provider.stateUpdateHandler = { state in
                switch state {
                case .ready: provider.stateUpdateHandler = nil; continuation.resume()
                case .failed(let error): provider.stateUpdateHandler = nil; continuation.resume(throwing: error)
                default: break
                }
            }
            provider.start(queue: queue)
        }
        defer { provider.cancel() }
        var authorization = URLComponents(string: "http://127.0.0.1:32181/authorize")!
        authorization.queryItems = [URLQueryItem(name: "redirect_uri", value: "http://localhost:32182/callback")]
        let local = LocalBrowserController()
        defer { local.stop() }
        let probe = SafariCallbackProbe()
        // Local provider is a simulator fixture. Production authentication
        // approves only an external provider and its original host callback.
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previous = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        let hostID = UUID()
        var parentDisappeared = false
        let anchor = UIHostingController(rootView: Color.clear
            .onDisappear { parentDisappeared = true }
            .sheet(isPresented: .constant(true)) {
            BrowserModeView(target: "fixture-pane", hostID: hostID, connectionProvider: { nil },
                            originalURL: authorization.url!, authenticate: { url in
                                .init(url: url, callbackHost: "127.0.0.1")
                            }, isPaneOwner: { true }, local: local)
        }.environment(\.scenePhase, .active))
        window.rootViewController = anchor
        window.makeKeyAndVisible()
        defer {
            anchor.dismiss(animated: false)
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKey()
        }
        let readyDeadline = ContinuousClock.now + .seconds(3)
        while !local.allowed, ContinuousClock.now < readyDeadline { try await Task.sleep(for: .milliseconds(20)) }
        try #require(local.allowed)
        local.open(url: authorization.url!, hostID: hostID, makeTunnel: {
            LocalBrowserTunnel(isConnected: { true }, connect: { socket, host, port, reply in
                #expect(host == "127.0.0.1" && port == 32182 && reply.isEmpty)
                let request = try await Self.readRequest(from: socket)
                await probe.record(request)
                try await Self.serveCallbackResponse(socket)
                socket.cancel()
            })
        }, authenticate: { url in .init(url: url, callbackHost: "127.0.0.1") }, isPaneOwner: { true })
        let deadline = ContinuousClock.now + .seconds(20)
        while await probe.request == nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        let request = await probe.request
        #expect(request?.hasPrefix("GET /callback?code=fixture&state=unchanged HTTP/1.1") == true)
        try await Task.sleep(for: .milliseconds(350))
        #expect(scene.activationState == .foregroundActive)
        #expect(!parentDisappeared)
        let browserSheet = try #require(anchor.presentedViewController)
        let safari = try #require(browserSheet.presentedViewController as? SFSafariViewController)
        // Done closes the production presenter and does not replay its URL when
        // its covered anchor becomes visible again.
        safari.delegate?.safariViewControllerDidFinish?(safari)
        try await Task.sleep(for: .milliseconds(150))
        #expect(browserSheet.presentedViewController == nil)
        #expect(anchor.presentedViewController === browserSheet)
        #expect(local.session.url == nil)

    }

    @Test("@spec CHROME-4.4: If a canceled Local attempt resumes after another explicit attempt opens its callback, then the application shall preserve the replacement listener and ignore the obsolete transport result.", .timeLimit(.minutes(1)))
    func staleLocalTransportCannotReleaseReplacementListener() async throws {
        let local = LocalBrowserController()
        local.allowed = true
        defer { local.stop() }
        let url = URL(string: "http://127.0.0.1:32183/")!
        let hostID = UUID()
        var held: CheckedContinuation<LocalBrowserTunnel?, Never>?
        let tunnel = LocalBrowserTunnel(isConnected: { true }, connect: { socket, _, _, _ in
            try await BrowserProxy.send(Data("alive".utf8), to: socket)
            socket.cancel()
        })
        local.open(url: url, hostID: hostID, makeTunnel: {
            await withCheckedContinuation { held = $0 }
        }, authenticate: { .init(url: $0, callbackHost: "127.0.0.1") }, isPaneOwner: { true })
        let heldDeadline = ContinuousClock.now + .seconds(2)
        while held == nil, ContinuousClock.now < heldDeadline { await Task.yield() }
        let pending = try #require(held)
        local.stop()
        local.open(url: url, hostID: hostID, makeTunnel: { tunnel },
                   authenticate: { .init(url: $0, callbackHost: "127.0.0.1") }, isPaneOwner: { true })
        let deadline = ContinuousClock.now + .seconds(2)
        while local.session.url == nil, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try #require(local.session.url == url)
        pending.resume(returning: tunnel)
        try await Task.sleep(for: .milliseconds(100))
        let socket = NWConnection(host: "127.0.0.1", port: 32183, using: .tcp)
        socket.start(queue: DispatchQueue(label: "graftty.safari.stale-transport.test"))
        defer { socket.cancel() }
        #expect(try await Self.receive(5, from: socket) == Data("alive".utf8))
        #expect(local.session.url == url)
    }

    @Test func cancelledListenerStartCannotReleaseActiveLocalPage() async throws {
        let network = HostBrowserNetwork()
        defer { network.stop() }
        let url = URL(string: "http://127.0.0.1:32184/")!, hostID = UUID()
        let connector: HostBrowserNetwork.Connector = { socket, _, _, _ in
            try await BrowserProxy.send(Data("alive".utf8), to: socket)
            socket.cancel()
        }
        try await network.startLocalPage(url: url, hostID: hostID, connect: connector)
        var held: CheckedContinuation<Void, Never>?
        let stale = Task {
            await withCheckedContinuation { held = $0 }
            do {
                try await network.startLocalPage(url: url, hostID: hostID, connect: connector)
                Issue.record("A canceled start must be rejected.")
            } catch is CancellationError { }
            catch { Issue.record("Expected cancellation before resource mutation.") }
        }
        while held == nil { await Task.yield() }
        stale.cancel()
        held?.resume()
        await stale.value
        let socket = NWConnection(host: "127.0.0.1", port: 32184, using: .tcp)
        socket.start(queue: DispatchQueue(label: "graftty.safari.cancelled-start.test"))
        defer { socket.cancel() }
        #expect(try await Self.receive(5, from: socket) == Data("alive".utf8))
    }

    @Test func obsoleteDisconnectedWatcherCannotStopReplacement() async throws {
        let local = LocalBrowserController()
        local.allowed = true
        defer { local.stop() }
        let gate = ConnectionStateGate()
        let url = URL(string: "http://127.0.0.1:32185/")!, hostID = UUID()
        let connect: HostBrowserNetwork.Connector = { socket, _, _, _ in
            try await BrowserProxy.send(Data("alive".utf8), to: socket)
            socket.cancel()
        }
        let oldTunnel = LocalBrowserTunnel(isConnected: { await gate.connected() }, connect: connect)
        local.open(url: url, hostID: hostID, makeTunnel: { oldTunnel },
                   authenticate: { .init(url: $0, callbackHost: "127.0.0.1") }, isPaneOwner: { true })
        let heldDeadline = ContinuousClock.now + .seconds(2)
        while !(await gate.isHeld), ContinuousClock.now < heldDeadline { await Task.yield() }
        try #require(await gate.isHeld)
        local.stop()
        let replacement = LocalBrowserTunnel(isConnected: { true }, connect: connect)
        local.open(url: url, hostID: hostID, makeTunnel: { replacement },
                   authenticate: { .init(url: $0, callbackHost: "127.0.0.1") }, isPaneOwner: { true })
        let deadline = ContinuousClock.now + .seconds(2)
        while local.session.url == nil, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try #require(local.session.url == url)
        await gate.resumeDisconnected()
        try await Task.sleep(for: .milliseconds(100))
        #expect(local.session.url == url)
        let socket = NWConnection(host: "127.0.0.1", port: 32185, using: .tcp)
        socket.start(queue: DispatchQueue(label: "graftty.safari.stale-watcher.test"))
        defer { socket.cancel() }
        #expect(try await Self.receive(5, from: socket) == Data("alive".utf8))
    }

    private actor ConnectionStateGate {
        var calls = 0
        var held: CheckedContinuation<Bool, Never>?
        var isHeld: Bool { held != nil }
        func connected() async -> Bool {
            calls += 1
            if calls == 2 { return await withCheckedContinuation { held = $0 } }
            return true
        }
        func resumeDisconnected() { held?.resume(returning: false); held = nil }
    }

    private actor SafariCallbackProbe {
        var request: String?
        func record(_ bytes: Data) { request = String(decoding: bytes, as: UTF8.self) }
    }

    private static func serveCallbackResponse(_ socket: NWConnection) async throws {
        let body = "Fixture callback received by the original host"
        try await BrowserProxy.send(Data("HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)".utf8), to: socket)
    }

    private static func readRequest(from socket: NWConnection) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            socket.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { data, _, _, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: data ?? Data()) }
            }
        }
    }

    private func expectPage(_ expected: String, url: URL, configuration: WKWebViewConfiguration) async throws {
        let view = WKWebView(frame: .zero, configuration: configuration)
        let navigation = NavigationProbe()
        view.navigationDelegate = navigation
        // iOS 26 can defer a detached WebKit view's first navigation. Mount it
        // as the browser sheet does, and tear down its load before the listener.
        let scene = try #require(UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }.first { $0.activationState == .foregroundActive })
        let previousKeyWindow = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 700)
        let controller = UIViewController()
        controller.view = view
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer {
            view.stopLoading()
            view.navigationDelegate = nil
            window.isHidden = true
            window.rootViewController = nil
            previousKeyWindow?.makeKey()
        }
        view.load(URLRequest(url: url))
        let deadline = ContinuousClock.now + .seconds(15)
        while !navigation.finished, navigation.failure == nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(navigation.failure == nil, "\(String(describing: navigation.failure))")
        try #require(navigation.finished)
        let body = try await view.evaluateJavaScript("document.body.textContent") as? String
        #expect(body == expected)
    }

    private static func servePage(_ body: String, socket: NWConnection, reply: Data) async throws {
        if !reply.isEmpty { try await BrowserProxy.send(reply, to: socket) }
        let request: Data = try await withCheckedThrowingContinuation { continuation in
            socket.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { data, _, _, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: data ?? Data()) }
            }
        }
        #expect(String(decoding: request, as: UTF8.self).hasPrefix("GET /"))
        let response = "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
        try await BrowserProxy.send(Data(response.utf8), to: socket)
        socket.cancel()
    }

    @Test func browserWindowsShareTheSameHostEndpoint() async throws {
        let first = HostBrowserNetwork(), second = HostBrowserNetwork()
        defer { first.stop(); second.stop() }
        let url = URL(string: "http://127.0.0.1:32124/")!
        let hostID = UUID()
        let connect: HostBrowserNetwork.Connector = { socket, _, _, reply in
            #expect(reply.isEmpty)
            try await BrowserProxy.send(Data("shared".utf8), to: socket)
            socket.cancel()
        }
        _ = try await first.start(url: url, dataStoreIdentifier: hostID) { _, _, _, _ in throw ExpectedFailure() }
        _ = try await second.start(url: url, dataStoreIdentifier: hostID, connect: connect)
        first.stop()
        let socket = NWConnection(host: "127.0.0.1", port: 32124, using: .tcp)
        socket.start(queue: DispatchQueue(label: "graftty.browser.shared.test"))
        defer { socket.cancel() }
        #expect(try await Self.receive(6, from: socket) == Data("shared".utf8))
    }

    @Test func closingSecondWindowPreservesFirstWindowsPublicHostProxy() async throws {
        let first = HostBrowserNetwork(), second = HostBrowserNetwork()
        defer { first.stop(); second.stop() }
        let url = URL(string: "http://example.invalid:32128/")!
        let hostID = UUID()
        let configuration = try await first.start(url: url, dataStoreIdentifier: hostID) { socket, _, _, reply in
            try await Self.servePage("surviving-window", socket: socket, reply: reply)
        }
        _ = try await second.start(url: url, dataStoreIdentifier: hostID) { _, _, _, _ in throw ExpectedFailure() }
        second.stop()
        try await expectPage("surviving-window", url: url, configuration: configuration)
    }

    @Test(arguments: ["127.0.0.1", "example.invalid"])
    func backgroundWindowsDisconnectedLeaseDoesNotBlockActiveWindow(targetHost: String) async throws {
        let first = HostBrowserNetwork(), second = HostBrowserNetwork()
        defer { first.stop(); second.stop() }
        let url = URL(string: "http://\(targetHost):32129/")!
        let hostID = UUID()
        let configuration = try await first.start(url: url, dataStoreIdentifier: hostID) { socket, _, _, reply in
            try await Self.servePage("active-window", socket: socket, reply: reply)
        }
        _ = try await second.start(url: url, dataStoreIdentifier: hostID) { _, _, _, _ in
            throw RemoteHostConnection.ConnectionError.notConnected
        }
        // A background scene can keep its browser view and lease while its
        // coordinator has closed. Do not stop the second browser here.
        try await expectPage("active-window", url: url, configuration: configuration)
    }

    @Test func conflictingMacCannotTakeOverAnotherHostsEndpoint() async throws {
        let first = HostBrowserNetwork(), second = HostBrowserNetwork()
        defer { first.stop(); second.stop() }
        let url = URL(string: "http://127.0.0.1:32126/")!
        _ = try await first.start(url: url, dataStoreIdentifier: UUID()) { socket, _, _, _ in
            try await BrowserProxy.send(Data("first".utf8), to: socket)
            socket.cancel()
        }
        do {
            _ = try await second.start(url: url, dataStoreIdentifier: UUID()) { socket, _, _, _ in socket.cancel() }
            Issue.record("A different Mac took over the active endpoint")
        } catch {
            #expect(error.localizedDescription.contains("another Mac"))
        }
        let socket = NWConnection(host: "127.0.0.1", port: 32126, using: .tcp)
        socket.start(queue: DispatchQueue(label: "graftty.browser.conflict.test"))
        defer { socket.cancel() }
        #expect(try await Self.receive(5, from: socket) == Data("first".utf8))
    }

    @Test func conflictingCallbackDestinationPreservesTheOpenBrowser() async throws {
        let first = HostBrowserNetwork(), second = HostBrowserNetwork()
        defer { first.stop(); second.stop() }
        let hostID = UUID()
        _ = try await first.start(url: URL(string: "http://localhost:32138/")!, dataStoreIdentifier: hostID) { socket, host, _, _ in
            #expect(host == "localhost")
            try await BrowserProxy.send(Data("first".utf8), to: socket)
            socket.cancel()
        }
        let authorization = URL(string: "https://example.invalid/authorize?redirect_uri=http%3A%2F%2Flocalhost%3A32138%2Fcallback")!
        do {
            _ = try await second.start(url: authorization, dataStoreIdentifier: hostID, callbackHost: "127.0.0.1") { socket, _, _, _ in socket.cancel() }
            Issue.record("A different destination took over the active endpoint")
        } catch {
            #expect(error.localizedDescription.contains("already open"))
        }
        let socket = NWConnection(host: "127.0.0.1", port: 32138, using: .tcp)
        socket.start(queue: DispatchQueue(label: "graftty.browser.callback.conflict.test"))
        defer { socket.cancel() }
        #expect(try await Self.receive(5, from: socket) == Data("first".utf8))
    }

    @Test func supersededStartCannotStopItsReplacement() async throws {
        let network = HostBrowserNetwork()
        defer { network.stop() }
        let url = URL(string: "http://127.0.0.1:32127/")!
        let hostID = UUID()
        let connect: HostBrowserNetwork.Connector = { socket, _, _, _ in
            try await BrowserProxy.send(Data("current".utf8), to: socket)
            socket.cancel()
        }
        let first = Task { try await network.start(url: url, dataStoreIdentifier: hostID, connect: connect) }
        await Task.yield()
        _ = try await network.start(url: url, dataStoreIdentifier: hostID, connect: connect)
        _ = try? await first.value
        let socket = NWConnection(host: "127.0.0.1", port: 32127, using: .tcp)
        socket.start(queue: DispatchQueue(label: "graftty.browser.replacement.test"))
        defer { socket.cancel() }
        #expect(try await Self.receive(7, from: socket) == Data("current".utf8))
    }

    @Test func loopbackDefaultPortIgnoresSchemeCase() throws {
        let endpoint = try #require(HostBrowserNetwork.LoopbackEndpoint(url: URL(string: "HTTPS://localhost/")!))
        #expect(endpoint.port == 443)
        #expect(HostBrowserNetwork.LoopbackEndpoint(url: URL(string: "HTTP://localhost/")!)?.port == 80)
    }

    @Test func rapidBrowserRestartReleasesItsPreviousEndpoint() async throws {
        let network = HostBrowserNetwork()
        defer { network.stop() }
        let url = URL(string: "http://127.0.0.1:32125/")!
        let hostID = UUID()
        for _ in 0..<20 {
            _ = try await network.start(url: url, dataStoreIdentifier: hostID) { socket, _, _, _ in socket.cancel() }
        }
    }

    @Test("WebKit uses the authenticated SOCKS proxy for every domain without failover")
    func webKitConfigurationUsesProxy() async throws {
        let proxy = try BrowserProxy { _, _, _ in }
        let port = try await proxy.start()
        defer { proxy.stop() }
        let dataStoreID = UUID(uuidString: "8B2C0D79-593D-43E0-84ED-65F34236DB14")!
        let config = HostBrowserProxyConfiguration.make(
            proxy: proxy,
            port: port,
            dataStoreIdentifier: dataStoreID
        )
        #expect(config.websiteDataStore.isPersistent)
        #expect(config.websiteDataStore.identifier == dataStoreID)
        let settings = try #require(config.websiteDataStore.proxyConfigurations.first)
        #expect(config.websiteDataStore.proxyConfigurations.count == 1)
        #expect(settings.allowFailover == false)
        #expect(settings.matchDomains == ["", "localhost", "127.0.0.1", "::1"])
    }

    @Test("The SOCKS proxy forwards localhost unchanged to the paired Mac")
    func localhostIsResolvedByHost() async throws {
        try await expectForwarded(host: "localhost", port: 3000)
    }

    @Test("The SOCKS proxy forwards public hostnames unchanged to the paired Mac")
    func publicHostnameIsResolvedByHost() async throws {
        try await expectForwarded(host: "example.invalid", port: 443)
    }

    private func expectForwarded(host: String, port: Int) async throws {
        let expectedHost = host
        let expectedPort = port
        let proxy = try BrowserProxy { socket, requestedHost, requestedPort in
            #expect(requestedHost == expectedHost)
            #expect(requestedPort == expectedPort)
            try await BrowserProxy.send(Data([5, 0, 0, 1, 0, 0, 0, 0, 0, 0]), to: socket)
            socket.cancel()
        }
        let proxyPort = try await proxy.start()
        defer { proxy.stop() }

        let socket = try await authenticatedConnection(to: proxy, port: proxyPort)
        defer { socket.cancel() }
        let hostname = Data(host.utf8)
        var request = Data([5, 1, 0, 3, UInt8(hostname.count)])
        request.append(hostname)
        request.append(contentsOf: [UInt8(port / 256), UInt8(port % 256)])
        try await BrowserProxy.send(request, to: socket)
        let reply = try await Self.receive(10, from: socket)
        #expect(reply[0] == 5)
        #expect(reply[1] == 0)
    }

    @Test("SOCKS CONNECT failures return an RFC 1928 failure reply", .timeLimit(.minutes(1)))
    func connectFailureReturnsProtocolReply() async throws {
        let proxy = try BrowserProxy { _, _, _ in throw ExpectedFailure() }
        let port = try await proxy.start()
        defer { proxy.stop() }

        let socket = try await authenticatedConnection(to: proxy, port: port)
        defer { socket.cancel() }

        let hostname = Data("example.invalid".utf8)
        var request = Data([5, 1, 0, 3, UInt8(hostname.count)])
        request.append(hostname)
        request.append(contentsOf: [0, 80])
        try await BrowserProxy.send(request, to: socket)
        let reply = try await Self.receive(10, from: socket)
        #expect(reply[0] == 5)
        #expect(reply[1] == 1)
    }

    private func authenticatedConnection(to proxy: BrowserProxy, port: UInt16) async throws -> NWConnection {
        let socket = NWConnection(
            host: "127.0.0.1",
            port: try #require(NWEndpoint.Port(rawValue: port)),
            using: .tcp
        )
        socket.start(queue: DispatchQueue(label: "graftty.browser.proxy.test-client"))

        try await BrowserProxy.send(Data([5, 1, 2]), to: socket)
        #expect(try await Self.receive(2, from: socket) == Data([5, 2]))

        let user = Data(proxy.username.utf8)
        let password = Data(proxy.password.utf8)
        var auth = Data([1, UInt8(user.count)])
        auth.append(user)
        auth.append(UInt8(password.count))
        auth.append(password)
        try await BrowserProxy.send(auth, to: socket)
        #expect(try await Self.receive(2, from: socket) == Data([1, 0]))
        return socket
    }

    private static func receive(_ count: Int, from connection: NWConnection) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: count, maximumLength: count) { data, _, _, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: data ?? Data()) }
            }
        }
    }

    private struct ExpectedFailure: Error {}
}

@MainActor
private final class NavigationProbe: NSObject, WKNavigationDelegate {
    var finished = false
    var failure: Error?
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finished = true }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { failure = error }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { failure = error }
}
#endif
