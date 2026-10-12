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
    @Test("@spec CHROME-1.6: If an OAuth offer launch reply is lost, then the application shall bind its identity to the original URL and host tab, return that tab on retry, and refuse an ambiguous launch replay.")
    func tracksOfferLaunchAtDispatchAndReply() throws {
        let directory = URL.temporaryDirectory.appendingPathComponent("graftty-offer-ledger-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storage = directory.appendingPathComponent("receipts.json")
        var ledger = ChromeOfferLaunchLedger(storageURL: storage)
        let id = UUID(), other = UUID()
        let raw = "https://example.com/authorize?state=A%2Bb&redirect_uri=http%3A%2F%2Flocalhost%3A4567%2Fcallback"
        #expect(try ledger.tab(for: id, url: raw) == nil)
        // Pre-dispatch failures do not register a receipt.
        #expect(try ledger.tab(for: id, url: raw) == nil)
        try ledger.dispatched(id, url: raw)
        #expect(throws: (any Error).self) { try ledger.tab(for: id, url: raw) }
        try ledger.created(id, tabID: "host-tab")
        #expect(try ledger.tab(for: id, url: raw) == "host-tab")
        #expect(throws: (any Error).self) { try ledger.tab(for: id, url: raw + "&changed=1") }
        #expect(try ledger.tab(for: other, url: raw) == nil)
        let restored = ChromeOfferLaunchLedger(storageURL: storage)
        #expect(try restored.tab(for: id, url: raw) == "host-tab")
        try ledger.dispatched(other, url: raw)
        let ambiguousRestart = ChromeOfferLaunchLedger(storageURL: storage)
        #expect(throws: (any Error).self) { try ambiguousRestart.tab(for: other, url: raw) }
        let mode = try FileManager.default.attributesOfItem(atPath: storage.path)[.posixPermissions] as? NSNumber
        #expect(mode?.intValue == 0o600)
        try ledger.abandonUnsent(other)
        #expect(try ChromeOfferLaunchLedger(storageURL: storage).tab(for: other, url: raw) == nil)
        try ledger.abandonUnsent(id)
        #expect(try ledger.tab(for: id, url: raw) == "host-tab")
    }

    @Test("@spec CHROME-1.9: While host Chrome retains OAuth launch receipts, the application shall persist and restore the maximum bounded history and reject new offers or unreadable history without evicting dispatched identities.")
    func boundsPersistentOfferHistory() throws {
        let directory = URL.temporaryDirectory.appendingPathComponent("graftty-offer-bound-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storage = directory.appendingPathComponent("receipts.json")
        var ledger = ChromeOfferLaunchLedger(storageURL: storage)
        let url = "https://example.com/" + String(repeating: "/", count: 8192 - 20)
        var identities: [UUID] = []
        for _ in 0..<128 {
            let id = UUID(); identities.append(id)
            try ledger.dispatched(id, url: url)
            try ledger.created(id, tabID: "host-tab")
        }
        let restored = ChromeOfferLaunchLedger(storageURL: storage)
        for id in identities { #expect(try restored.tab(for: id, url: url) == "host-tab") }
        #expect(throws: (any Error).self) { try ledger.dispatched(UUID(), url: url) }
        try Data("corrupt".utf8).write(to: storage)
        let corrupt = ChromeOfferLaunchLedger(storageURL: storage)
        #expect(throws: (any Error).self) { try corrupt.tab(for: identities[0], url: url) }
    }

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
