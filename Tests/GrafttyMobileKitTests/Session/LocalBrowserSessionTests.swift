import Foundation
import Testing
@testable import GrafttyMobileKit

@MainActor
struct LocalBrowserSessionTests {
    private let original = URL(string: "https://example.com/authorize?state=original&redirect_uri=http%3A%2F%2Flocalhost%3A32180%2Fcallback")!

    @Test("@spec CHROME-4.1: When Local browser mode is selected, the application shall authorize and prepare the retained original URL before presenting it and shall reject any changed URL.")
    func originalURLAndListenerReadiness() async {
        let session = LocalBrowserSession()
        var prepared = false
        await session.open(originalURL: original, isAllowed: { true }, authorize: { self.original }) { url in
            #expect(url == self.original)
            #expect(session.url == nil)
            prepared = true
        }
        #expect(prepared && session.url == original)
        session.stop()
        await session.open(originalURL: original, isAllowed: { true }, authorize: { URL(string: "https://example.com/changed")! }) { _ in
            Issue.record("A rewritten authorization must never prepare a listener.")
        }
        #expect(session.url == nil && session.error != nil)
    }

    @Test("@spec CHROME-4.2: If the originating browser scope loses ownership or is dismissed during authorization or listener preparation, then the application shall cancel Local presentation, release callback listeners and require another explicit selection.")
    func cancelledScopeCannotPublishOrReplay() async {
        var released = 0
        let session = LocalBrowserSession(release: { released += 1 })
        var owned = true
        await session.open(originalURL: original, isAllowed: { owned }, authorize: {
            owned = false
            return self.original
        }) { _ in Issue.record("Revoked ownership must prevent listener preparation.") }
        #expect(session.url == nil)
        owned = true
        await session.open(originalURL: original, isAllowed: { owned }, authorize: { self.original }) { _ in
            session.stop()
        }
        #expect(session.url == nil && !session.preparing)
        #expect(released > 0)
        // Returning to an allowed state does not reopen anything.
        owned = true
        #expect(session.url == nil)
    }

    @Test func staleAuthorizationCannotReplaceANewExplicitAttempt() async {
        let session = LocalBrowserSession()
        var pending: CheckedContinuation<URL, Never>?
        let old = Task {
            await session.open(originalURL: original, isAllowed: { true }, authorize: {
                await withCheckedContinuation { pending = $0 }
            }, prepare: { _ in Issue.record("The old scope must not bind a listener.") })
        }
        while pending == nil { await Task.yield() }
        session.stop()
        let replacement = URL(string: "https://example.com/replacement")!
        await session.open(originalURL: replacement, isAllowed: { true }, authorize: { replacement }, prepare: { _ in })
        pending?.resume(returning: original)
        await old.value
        #expect(session.url == replacement && session.error == nil)
    }

    @Test func initiallyRevokedScopeDoesNotAuthorize() async {
        let session = LocalBrowserSession()
        await session.open(originalURL: original, isAllowed: { false }, authorize: {
            Issue.record("A follower must not send authentication authorization.")
            return self.original
        }, prepare: { _ in Issue.record("A follower must not bind callback ports.") })
        #expect(session.url == nil && session.error != nil)
    }

    @Test("@spec CHROME-4.5: When Local browser mode is selected, the application shall use the retained original OAuth offer for sign-in, otherwise use the current selected HTTP(S) page, and reject an authorization page without its originating offer.")
    func localModeSelectsOriginalAuthOrCurrentOrdinaryPage() throws {
        let challenge = URL(string: "https://example.com/challenge")!
        #expect(try LocalBrowserSelection.url(originalOffer: original, selectedPage: challenge) == original)
        let ordinary = URL(string: "https://example.com/ordinary")!
        #expect(try LocalBrowserSelection.url(originalOffer: ordinary, selectedPage: challenge) == challenge)
        #expect(try LocalBrowserSelection.url(originalOffer: nil, selectedPage: ordinary) == ordinary)
        #expect(throws: (any Error).self) { try LocalBrowserSelection.url(originalOffer: nil, selectedPage: original) }
        #expect(throws: (any Error).self) { try LocalBrowserSelection.url(originalOffer: nil, selectedPage: URL(string: "file:///tmp/secret")) }
        #expect(throws: (any Error).self) { try LocalBrowserSelection.url(originalOffer: nil, selectedPage: nil) }
        #expect(throws: (any Error).self) { try LocalBrowserSelection.url(originalOffer: ordinary, selectedPage: nil) }
        let longURL = URL(string: "https://example.com/page?token=" + String(repeating: "a", count: 3000))!
        #expect(try LocalBrowserSelection.url(originalOffer: ordinary, selectedPage: longURL) == longURL)
    }

    @Test func preSendFailureRemainsRetryableAndMessagesDoNotContainURLs() async {
        struct Denied: Error { }
        let session = LocalBrowserSession()
        await session.open(originalURL: original, isAllowed: { true }, authorize: { throw Denied() }) { _ in
            Issue.record("Denied authorization must not bind callback listeners.")
        }
        #expect(session.url == nil && session.error != nil)
        #expect(session.error?.contains("state=") == false)
        await session.open(originalURL: original, isAllowed: { true }, authorize: { self.original }, prepare: { _ in })
        #expect(session.url == original && session.error == nil)
    }
}
