import AppKit
import Testing
@testable import Graftty

@Suite("@spec WEB-4.3: When the application quits, the application shall await Web Access listener and session teardown before completing normal termination, while keeping the main actor responsive.")
@MainActor
struct WebServerTerminationTests {
    @Test func delegateAdaptorConstructionUsesTheZeroArgumentInitializer() {
        func construct<T: NSObject>(_ type: T.Type) -> T { type.init() }
        let delegate = construct(WebAccessTerminationDelegate.self)
        #expect(delegate.applicationShouldTerminate(NSApplication.shared) == .terminateNow)
    }

    @Test func terminationWaitsForCleanupAndRepliesExactlyOnce() async {
        let entered = WebLifecycleGate()
        let release = WebLifecycleGate()
        let replied = WebLifecycleGate()
        var replies = 0
        let delegate = WebAccessTerminationDelegate(reply: { _, allowed in
            #expect(allowed)
            replies += 1
            replied.open()
        })
        delegate.shutdown = {
            entered.open()
            await release.wait()
        }
        defer { release.open() }
        let result = delegate.applicationShouldTerminate(NSApplication.shared)
        #expect(result == .terminateLater)
        guard result == .terminateLater else { return }
        await entered.wait()
        #expect(replies == 0)
        #expect(delegate.applicationShouldTerminate(NSApplication.shared) == .terminateLater)
        release.open()
        await replied.wait()
        #expect(replies == 1)
    }

    @Test func terminationBeforeWebControllerIsInstalledDoesNotDefer() {
        let delegate = WebAccessTerminationDelegate(reply: { _, _ in
            Issue.record("termination without a controller replied asynchronously")
        })
        #expect(delegate.applicationShouldTerminate(NSApplication.shared) == .terminateNow)
    }
}
