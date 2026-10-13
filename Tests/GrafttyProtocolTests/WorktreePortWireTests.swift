import Foundation
import Testing
@testable import GrafttyProtocol

struct WorktreePortWireTests {
    @Test("@spec PORTS-5.35: When worktree port metadata crosses a host connection, the application shall preserve both mobile listener addresses and session-scoped forwarding targets, including legacy bindings without a listener address.", arguments: ["127.0.0.2", "::1", "192.0.2.4"])
    func mobileAndDesktopPortMetadataCoexist(host: String) throws {
        let target: String? = host == "192.0.2.4" ? nil : host
        let scope: BindScope = target == nil ? .lan : .loopback
        let binding = PortBinding(port: 3000, scope: scope, processName: "node", pid: 12,
                                  host: host, targetHost: target)
        let port = WorktreePort(port: 3000, scope: target == nil ? .lan : .loopback,
                                processName: "node", host: host)
        let row = WorktreePanes(path: "/project", displayName: "main", repoDisplayName: "repo",
                               displayBranch: "main", state: .running, isMainCheckout: true,
                               prBadge: nil, stats: nil, attentionText: nil, layout: nil,
                               ports: [port], portBindings: ["session": [binding]])
        #expect(try JSONDecoder().decode(WorktreePanes.self, from: JSONEncoder().encode(row)) == row)
        var legacy = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(binding)) as? [String: Any])
        legacy.removeValue(forKey: "host")
        let decoded = try JSONDecoder().decode(PortBinding.self, from: JSONSerialization.data(withJSONObject: legacy))
        #expect(decoded.targetHost == target)
        #expect(decoded.host == (target ?? "localhost"))
    }

    @Test("@spec PORTS-5.2: When a worktree snapshot includes listening ports, the application shall preserve their process names, bind scopes, and listener addresses on the wire and treat absent ports from older hosts as an empty list.")
    func portsRoundTripAndLegacyDefaults() throws {
        let legacy = Data(#"{"path":"/project","displayName":"main","repoDisplayName":"repo"}"#.utf8)
        let old = try JSONDecoder().decode(WorktreePanes.self, from: legacy)
        #expect(old.ports.isEmpty)
        let row = WorktreePanes(path: "/project", displayName: "main", repoDisplayName: "repo",
            displayBranch: "main", state: .running, isMainCheckout: true, prBadge: nil,
            stats: nil, attentionText: nil, layout: nil,
            ports: [.init(port: 3000, scope: .loopback, processName: "vite", host: "::1")])
        #expect(try JSONDecoder().decode(WorktreePanes.self, from: JSONEncoder().encode(row)) == row)
    }

    @Test func portOpenRequestAndURLRoundTrip() throws {
        let request = WorktreeManagementRequest.openResource(worktreeID: "/project", request: .port(3000))
        #expect(try JSONDecoder().decode(WorktreeManagementRequest.self, from: JSONEncoder().encode(request)) == request)
        let response = WorktreeManagementResponse.openResource(.url(URL(string: "http://localhost:3000/")!))
        #expect(try JSONDecoder().decode(WorktreeManagementResponse.self, from: JSONEncoder().encode(response)) == response)
    }
    @Test("@spec PORTS-5.15: When a terminal offers an OAuth authorization URL with one HTTP(S) loopback redirect, the application shall preserve the authorization and callback URLs and reject ambiguous or non-loopback redirects.")
    func authenticationRequestRoundTrips() throws {
        let wire = Data(#"{"type":"open_resource","worktreeID":"/project","openResource":{"authenticate":{"_0":"https://example.com/authorize?redirect_uri=http%3A%2F%2F127.0.0.1%3A43210%2Fcallback&state=abc"}}}"#.utf8)
        let request = try JSONDecoder().decode(WorktreeManagementRequest.self, from: wire)
        #expect(try JSONDecoder().decode(WorktreeManagementRequest.self, from: JSONEncoder().encode(request)) == request)
        let url = URL(string: "https://example.com/authorize?redirect_uri=http%3A%2F%2F127.0.0.1%3A43210%2Fcallback&state=abc")!
        let authentication = try #require(WorktreeAuthenticationURL(url: url))
        #expect(authentication.authorizationURL == url)
        #expect(authentication.callbackURL.absoluteString == "http://127.0.0.1:43210/callback")
        #expect(authentication.callbackPort == 43210)
        for callback in ["https://example.org/callback", "ftp://localhost:43210/callback", "http://user:pass@127.0.0.1:43210/callback", "http://127.0.0.1:0/callback", "http://127.0.0.1:43210/callback#fragment"] {
            var components = URLComponents(string: "https://example.com/authorize")!
            components.queryItems = [URLQueryItem(name: "redirect_uri", value: callback)]
            #expect(WorktreeAuthenticationURL(url: components.url!) == nil)
            components.queryItems?.append(URLQueryItem(name: "redirect_uri", value: "http://localhost:43210/callback"))
            #expect(WorktreeAuthenticationURL(url: components.url!) == nil)
        }
    }

    @Test("@spec PORTS-5.16: When preparing a worktree sign-in browser, the host shall resolve its callback only from that worktree's live listeners and preserve the listener's address.")
    func callbackResolutionDoesNotCrossListenerAddresses() throws {
        let ipv4 = WorktreePort(port: 43210, scope: .loopback, processName: "codex", host: "127.0.0.1")
        let ipv6 = WorktreePort(port: 43210, scope: .loopback, processName: "other", host: "::1")
        let authorization = URL(string: "https://example.com/authorize?redirect_uri=http%3A%2F%2F127.0.0.1%3A43210%2Fcallback")!
        let authentication = try #require(WorktreeAuthenticationURL(url: authorization))
        #expect(authentication.resolveCallbackHost(in: [ipv6]) == nil)
        #expect(authentication.resolveCallbackHost(in: [ipv4]) == "127.0.0.1")
        #expect(authentication.resolveCallbackHost(in: []) == nil)
        #expect(authentication.resolveCallbackHost(in: [.init(port: 43211, scope: .loopback, processName: "codex", host: "127.0.0.1")]) == nil)
        let local = try #require(WorktreeAuthenticationURL(url: URL(string: "https://example.com/authorize?redirect_uri=http%3A%2F%2Flocalhost%3A43210%2Fcallback")!))
        #expect(local.resolveCallbackHost(in: [ipv4]) == "127.0.0.1")
        let response = WorktreeManagementResponse.openResource(.authentication(url: authorization, callbackHost: "127.0.0.1"))
        #expect(try JSONDecoder().decode(WorktreeManagementResponse.self, from: JSONEncoder().encode(response)) == response)
    }

}
