import Foundation
import Testing
import GrafttyKit
@testable import Graftty

/// Stands in for the Tailscale daemon: `fetch()` stays pending until the test
/// calls `release()`. The wait is bounded so a regression that blocks the main
/// actor on the fetch fails the test instead of deadlocking it.
private final class PendingTailscaleStatus: @unchecked Sendable {
    private let lock = NSLock()
    private var released = false
    private var finished = false
    private let error: any Error

    init(throwing error: any Error) {
        self.error = error
    }

    var hasFinished: Bool { lock.withLock { finished } }

    func release() { lock.withLock { released = true } }

    func fetch() async throws -> (api: TailscaleLocalAPI, status: TailscaleLocalAPI.Status) {
        // Detached so cancelling the reconcile neither cuts the wait short
        // (the real LocalAPI `recv` ignores cancellation too) nor turns the
        // sleep below into a busy spin.
        await Task.detached { [self] in
            let deadline = ContinuousClock.now + .seconds(2)
            while !lock.withLock({ released }), ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(5))
            }
        }.value
        lock.withLock { finished = true }
        throw error
    }
}

/// Hands out one stand-in daemon per reconcile attempt, repeating the last.
private final class DaemonSequence: @unchecked Sendable {
    private let lock = NSLock()
    private let daemons: [PendingTailscaleStatus]
    private var count = 0

    init(_ daemons: [PendingTailscaleStatus]) { self.daemons = daemons }

    var handedOut: Int { lock.withLock { count } }

    func next() -> PendingTailscaleStatus {
        lock.withLock {
            defer { count += 1 }
            return daemons[min(count, daemons.count - 1)]
        }
    }
}

/// Polls on the main actor until `condition` holds or two seconds pass.
@MainActor
private func waitUntil(_ condition: () -> Bool) async {
    let deadline = ContinuousClock.now + .seconds(2)
    while !condition(), ContinuousClock.now < deadline {
        try? await Task.sleep(for: .milliseconds(5))
    }
}

@Suite("@spec WEB-1.15: While web access is enabled, the application shall query the Tailscale daemon off the main actor, so constructing the web server controller or applying a Web Access settings change returns without waiting for the daemon to respond.")
@MainActor
final class WebServerControllerAsyncReconcileTests {
    /// Each test gets a throwaway defaults suite so toggling Web Access never
    /// leaks into the test runner's `UserDefaults.standard`.
    private let suiteName = "WebServerControllerAsyncReconcileTests-\(UUID().uuidString)"

    deinit {
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
    }

    private func makeSettings(enabled: Bool) -> WebAccessSettings {
        let settings = WebAccessSettings(store: UserDefaults(suiteName: suiteName)!)
        settings.isEnabled = enabled
        return settings
    }

    private func makeController(
        _ settings: WebAccessSettings,
        _ daemon: PendingTailscaleStatus
    ) -> WebServerController {
        WebServerController(
            settings: settings,
            zmxExecutable: URL(fileURLWithPath: "/dev/null"),
            zmxDir: URL(fileURLWithPath: "/tmp"),
            fetchTailscaleStatus: { try await daemon.fetch() }
        )
    }

    @Test func initReturnsWhileTailscaleStatusIsPending() async {
        let daemon = PendingTailscaleStatus(throwing: TailscaleLocalAPI.Error.socketUnreachable)
        let controller = makeController(makeSettings(enabled: true), daemon)
        defer { controller.stop() }

        #expect(!daemon.hasFinished, "init waited for the Tailscale status response")

        daemon.release()
        await waitUntil { controller.status == .tailscaleUnavailable }
        #expect(controller.status == .tailscaleUnavailable)
    }

    @Test func enablingWhileTailscaleStatusIsPendingReturnsImmediately() async {
        let daemon = PendingTailscaleStatus(throwing: TailscaleLocalAPI.Error.socketUnreachable)
        let settings = makeSettings(enabled: false)
        let controller = makeController(settings, daemon)
        defer { controller.stop() }

        settings.isEnabled = true
        // The settings sink hops through a main-actor Task before reconciling.
        await waitUntil { controller.reconcileTaskForTests != nil }

        #expect(!daemon.hasFinished, "the settings-change reconcile waited for the Tailscale status response")

        daemon.release()
        await waitUntil { controller.status == .tailscaleUnavailable }
        #expect(controller.status == .tailscaleUnavailable)
    }

    @Test func aRetryKeepsShowingTheTransientFailureWhileItsQueryIsPending() async {
        let failedFast = PendingTailscaleStatus(throwing: TailscaleLocalAPI.Error.socketUnreachable)
        failedFast.release()
        let pending = PendingTailscaleStatus(throwing: TailscaleLocalAPI.Error.socketUnreachable)
        let daemons = DaemonSequence([failedFast, pending])
        let settings = makeSettings(enabled: true)
        let controller = WebServerController(
            settings: settings,
            zmxExecutable: URL(fileURLWithPath: "/dev/null"),
            zmxDir: URL(fileURLWithPath: "/tmp"),
            fetchTailscaleStatus: { try await daemons.next().fetch() }
        )
        defer { controller.stop() }
        await waitUntil { controller.status == .tailscaleUnavailable }

        // Any re-reconcile (here a port change; WEB-1.14 retries take the same
        // path) must not flash "Stopped" while Tailscale is re-queried.
        settings.port += 1
        await waitUntil { daemons.handedOut == 2 }

        #expect(controller.status == .tailscaleUnavailable)
        pending.release()
    }

    @Test func disablingWhileStatusIsPendingDiscardsTheStaleResult() async throws {
        let daemon = PendingTailscaleStatus(throwing: TailscaleLocalAPI.Error.httpError(500))
        let settings = makeSettings(enabled: true)
        let controller = makeController(settings, daemon)
        defer { controller.stop() }

        let superseded = try #require(controller.reconcileTaskForTests)
        settings.isEnabled = false
        // The settings sink hops through a main-actor Task before reconciling.
        await waitUntil { controller.reconcileTaskForTests == nil }
        daemon.release()
        await superseded.value

        #expect(controller.status == .stopped)
    }
}
