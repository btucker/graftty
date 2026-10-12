import Foundation
import Testing
@testable import GrafttyKit
import GrafttyProtocol

private actor ChromeFixture: ChromeTabBackend {
    var calls = 0
    var stops = 0
    var tabs = [ChromeTab(id: "a", title: "Sign in", url: "https://example.com")]
    func perform(_ action: ChromeTabAction, authorize: @escaping @Sendable () async -> Bool) async throws -> ChromeTabState {
        calls += 1
        if case .launch(let url) = action { tabs.append(.init(id: "b", title: "New", url: url)) }
        return ChromeTabState(tabs: tabs, selectedTabID: tabs.first?.id)
    }
    func stopCapture() async { stops += 1 }
    func stopCount() -> Int { stops }
    func count() -> Int { calls }
}

struct ChromeTabBrokerTests {
    @Test("@spec CHROME-1.1: If a Chrome request lacks live pane ownership for its authenticated peer, then the application shall reject it before accessing a dedicated profile.")
    func rejectsUnauthorized() async {
        let fixture = ChromeFixture()
        let broker = ChromeTabBroker(authorize: { _, _ in nil }, makeBackend: { _ in fixture })
        let response = await broker.handle(.init(target: "pane", action: .launch(url: "https://example.com")), peerID: "spoof", viewerID: UUID())
        #expect(response.error != nil)
        #expect(await fixture.count() == 0)
        let suffix = UUID().uuidString
        #expect(ChromeTabBroker.ownsDisplay(clientID: "ssh-peer-\(suffix)", peerID: "peer"))
        #expect(!ChromeTabBroker.ownsDisplay(clientID: "ssh-peer-extra-\(suffix)", peerID: "peer"))
        #expect(!ChromeTabBroker.ownsDisplay(clientID: "ssh-peer-not-a-channel", peerID: "peer"))
    }

    @Test("@spec CHROME-1.2: When an authorized viewer reconnects, the application shall list the persistent host tabs without relaunching Chrome.")
    func persistsAcrossViewers() async {
        let fixture = ChromeFixture()
        let broker = ChromeTabBroker(authorize: { _, peer in peer == "trusted" ? "/worktree" : nil }, makeBackend: { _ in fixture })
        let viewer = UUID()
        _ = await broker.handle(.init(target: "pane", action: .launch(url: "https://example.com/new")), peerID: "trusted", viewerID: viewer)
        await broker.disconnect(viewerID: viewer)
        let attached = await broker.handle(.init(target: "pane", action: .list), peerID: "trusted", viewerID: UUID())
        #expect(attached.state?.tabs.count == 2)
        #expect(await fixture.count() == 2)
    }

    @Test("@spec CHROME-1.3: If a viewer sends an unsupported launch URL or oversized input, then the application shall reject it before calling Chrome.")
    func boundsInput() async {
        let fixture = ChromeFixture()
        let broker = ChromeTabBroker(authorize: { _, _ in "/worktree" }, makeBackend: { _ in fixture })
        let actions: [ChromeTabAction] = [.launch(url: "file:///etc/passwd"), .launch(url: "javascript:alert(1)"), .text(tabID: "a", text: String(repeating: "x", count: 4097)), .tap(tabID: "a", x: 1.1, y: 0)]
        for action in actions {
            #expect(await broker.handle(.init(target: "pane", action: action), peerID: "trusted", viewerID: UUID()).error != nil)
        }
        #expect(await fixture.count() == 0)
    }
    @Test("@spec CHROME-1.5: When a viewer loses pane ownership, the application shall stop its screencast and release its Chrome viewer lease before another owner attaches.")
    func releasesOnOwnershipLoss() async {
        let fixture = ChromeFixture()
        let permission = ChromePermission()
        let broker = ChromeTabBroker(authorize: { _, peer in if peer == "other" { return "/worktree" }; return await permission.isAllowed() ? "/worktree" : nil }, makeBackend: { _ in fixture })
        let viewer = UUID()
        _ = await broker.handle(.init(target: "pane", action: .launch(url: "https://example.com")), peerID: "trusted", viewerID: viewer)
        await permission.revoke()
        // The old viewer stays idle with its SSH channel still open.
        #expect(await broker.handle(.init(target: "pane", action: .list), peerID: "other", viewerID: UUID()).error == nil)
        #expect(await broker.handle(.init(target: "pane", action: .list), peerID: "trusted", viewerID: viewer).error != nil)
        #expect(await fixture.stopCount() == 1)
    }

}

private actor ChromePermission {
    var allowed = true
    func revoke() { allowed = false }
    func isAllowed() -> Bool { allowed }
}
