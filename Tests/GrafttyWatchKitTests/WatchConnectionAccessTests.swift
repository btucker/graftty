import Foundation
import Testing
@testable import GrafttyWatchKit

@MainActor
struct WatchConnectionAccessTests {
    let foreground = UUID()
    @Test("@spec WATCH-2.5: While the phone foreground or any enabled watch request needs a host connection, the application shall share its connection coordinator and keep access until the final consumer releases it.")
    func overlappingRequestsRetainTheSharedConnection() throws {
        var changes: [Bool] = []
        let access = WatchConnectionAccess(watchEnabled: true) { changes.append($0) }
        access.setForegroundAllowed(true, consumer: foreground)
        let first = try #require(access.beginWatchRequest())
        let second = try #require(access.beginWatchRequest())
        access.setForegroundAllowed(false, consumer: foreground)
        access.endWatchRequest(first)
        #expect(access.isAllowed)
        #expect(access.isActive(second))
        #expect(changes == [true])
        access.endWatchRequest(second)
        #expect(!access.isAllowed)
        #expect(changes == [true, false])
        access.setForegroundAllowed(true, consumer: foreground)
        let borrowed = try #require(access.beginWatchRequest())
        access.endWatchRequest(borrowed)
        #expect(access.isAllowed)
        #expect(changes == [true, false, true])
        let anotherWindow = UUID()
        access.setForegroundAllowed(true, consumer: anotherWindow)
        access.setForegroundAllowed(false, consumer: foreground)
        #expect(access.isAllowed)
        access.setForegroundAllowed(false, consumer: anotherWindow)
        #expect(!access.isAllowed)
    }

    @Test("@spec WATCH-2.6: When watch access is disabled or a watch request expires, the application shall release that request's connection lease without closing connections still needed by the foreground or another request, and shall refuse disabled or cancelled requests.")
    func expirationAndRevocationAreScoped() async throws {
        let access = WatchConnectionAccess(watchEnabled: true) { _ in }
        let first = try #require(access.beginWatchRequest())
        let second = try #require(access.beginWatchRequest())
        access.endWatchRequest(first)
        access.endWatchRequest(first)
        #expect(access.isAllowed)
        #expect(!access.isActive(first))
        #expect(access.isActive(second))
        access.setForegroundAllowed(true, consumer: foreground)
        access.setWatchEnabled(false)
        #expect(access.isAllowed)
        #expect(!access.isActive(second))
        #expect(access.beginWatchRequest() == nil)
        access.setForegroundAllowed(false, consumer: foreground)
        #expect(!access.isAllowed)
        access.setWatchEnabled(true)
        #expect(!access.isActive(second))
        let cancelled = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            return access.beginWatchRequest()
        }
        #expect(await cancelled.value == nil)
        #expect(!access.isAllowed)
        #expect(access.beginWatchRequest() != nil)
    }
}
