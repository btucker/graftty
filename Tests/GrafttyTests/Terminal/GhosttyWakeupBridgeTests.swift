import Foundation
import Testing
@testable import Graftty

@Suite("@spec TERM-11.19: When libghostty posts a wakeup notification, the application shall defer its tick to the main queue without running it inline or waiting for the main queue on the posting thread.")
struct GhosttyWakeupBridgeTests {
    @MainActor
    @Test func mainThreadWakeupRunsAfterPostingScopeReleasesLock() async {
        let center = NotificationCenter()
        let rendererLock = NSLock()
        var ticks = 0
        let observer = GhosttyWakeupBridge.observe(center: center) {
            #expect(Thread.isMainThread)
            let acquired = rendererLock.try()
            #expect(acquired, "tick must not reenter the renderer while the posting scope holds its lock")
            if acquired { rendererLock.unlock() }
            ticks += 1
        }
        defer { center.removeObserver(observer) }

        // Model ghostty_surface_write_buffer posting a wakeup while holding
        // renderer_state.mutex, without blocking forever on a regression.
        rendererLock.withLock {
            center.post(name: .ghosttyWakeup, object: nil)
            #expect(ticks == 0, "posting on main must not tick inline")
        }
        await drainMainQueue()
        #expect(ticks == 1)

        center.post(name: .ghosttyWakeup, object: nil)
        #expect(ticks == 1)
        await drainMainQueue()
        #expect(ticks == 2, "later wakeups must still be delivered")
    }

    @MainActor
    @Test func backgroundWakeupReturnsWithoutWaitingForMainAndDeliversOnMain() async {
        let center = NotificationCenter()
        let posted = DispatchSemaphore(value: 0)
        var ticks = 0
        let observer = GhosttyWakeupBridge.observe(center: center) {
            #expect(Thread.isMainThread)
            ticks += 1
        }
        defer { center.removeObserver(observer) }

        DispatchQueue.global().async {
            center.post(name: .ghosttyWakeup, object: nil)
            posted.signal()
        }
        // Keep main occupied until the background post returns. A queue: .main
        // observer would synchronously wait for main and fail this bounded check.
        #expect(waitForPost(posted))
        #expect(ticks == 0)
        await drainMainQueue()
        #expect(ticks == 1)
    }

    private func waitForPost(_ posted: DispatchSemaphore) -> Bool {
        posted.wait(timeout: .now() + 2) == .success
    }

    private func drainMainQueue() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }
}
