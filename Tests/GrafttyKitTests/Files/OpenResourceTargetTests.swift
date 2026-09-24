import Foundation
import Testing
@testable import GrafttyKit

struct OpenResourceTargetTests {
    @Test("@spec IOS-12.4: When graftty open receives an HTTP or HTTPS URL on a directly paired host, the application shall preserve its origin, offer it to mobile, and carry its browser connections through the authenticated host connection so localhost and DNS resolve on the host.", arguments: ["http://localhost:3000", "http://example.com", "https://example.com/path?q=test#part"])
    func preservesURLs(text: String) async throws {
        let url = try OpenResourceTarget.resolve(text)
        #expect(url.absoluteString == text)
        let store = RemoteOpenStore()
        let now = Date()
        let offer = try await store.offer(file: url, worktree: "/project", now: now)
        #expect(offer.url == url)
        #expect(await store.list(worktree: "/project") == [offer])
        #expect(BrowserTunnelApprovalStore.shared.isApproved(now: now.addingTimeInterval(899)))
    }

    @Test(arguments: ["ftp://example.com", "http://user:password@example.com", "https://"])
    func rejectsUnsupportedURLs(text: String) {
        #expect(throws: (any Error).self) { try OpenResourceTarget.resolve(text) }
    }
}
