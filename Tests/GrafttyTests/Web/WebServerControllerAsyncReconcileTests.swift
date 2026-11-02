import Foundation
import Testing
import GrafttyKit
@testable import Graftty

/// Holds a daemon response until explicitly released. Ignoring cancellation
/// here models an obsolete dependency that can still produce a late result.
private final class PendingTailscaleStatus: @unchecked Sendable {
    private let lock = NSLock()
    private let response = WebLifecycleGate()
    let started = WebLifecycleGate()
    private var finished = false
    private let error: any Error

    init(throwing error: any Error) { self.error = error }
    var hasFinished: Bool { lock.withLock { finished } }
    func release() { response.open() }

    func fetch() async throws -> (api: TailscaleLocalAPI, status: TailscaleLocalAPI.Status) {
        started.open()
        await response.wait()
        lock.withLock { finished = true }
        throw error
    }
}

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

@Suite("@spec WEB-1.15: While web access is enabled, the application shall query the Tailscale daemon off the main actor, so constructing the web server controller or applying a Web Access settings change returns without waiting for the daemon to respond.")
@MainActor
final class WebServerControllerAsyncReconcileTests {
    private let suiteName = "WebServerControllerAsyncReconcileTests-\(UUID().uuidString)"

    deinit { UserDefaults.standard.removePersistentDomain(forName: suiteName) }

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
            fetchTailscaleStatus: { try await daemon.fetch() },
            retrySleep: { _ in throw CancellationError() }
        )
    }

    @Test func initReturnsWhileTailscaleStatusIsPending() async {
        let daemon = PendingTailscaleStatus(throwing: TailscaleLocalAPI.Error.socketUnreachable)
        let controller = makeController(makeSettings(enabled: true), daemon)
        defer { daemon.release(); controller.stop() }
        #expect(!daemon.hasFinished, "init waited for the Tailscale status response")
        await daemon.started.wait()
        daemon.release()
        await controller.reconcileTaskForTests?.value
        #expect(controller.status == .tailscaleUnavailable)
        controller.stop()
        await controller.cleanupTaskForTests?.value
    }

    @Test func enablingWhileTailscaleStatusIsPendingReturnsImmediately() async {
        let daemon = PendingTailscaleStatus(throwing: TailscaleLocalAPI.Error.socketUnreachable)
        let settings = makeSettings(enabled: false)
        let controller = makeController(settings, daemon)
        defer { daemon.release(); controller.stop() }
        settings.isEnabled = true
        await daemon.started.wait()
        #expect(!daemon.hasFinished, "the settings-change reconcile waited for the Tailscale status response")
        daemon.release()
        await controller.reconcileTaskForTests?.value
        #expect(controller.status == .tailscaleUnavailable)
        controller.stop()
        await controller.cleanupTaskForTests?.value
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
            fetchTailscaleStatus: { try await daemons.next().fetch() },
            retrySleep: { _ in throw CancellationError() }
        )
        defer { pending.release(); controller.stop() }
        await controller.reconcileTaskForTests?.value
        #expect(controller.status == .tailscaleUnavailable)
        // A settings-triggered retry uses the same reconcile path as the
        // injected-clock automatic retry covered by the recovery suite.
        settings.port += 1
        await pending.started.wait()
        #expect(daemons.handedOut == 2)
        #expect(controller.status == .tailscaleUnavailable)
        pending.release()
        await controller.reconcileTaskForTests?.value
        controller.stop()
        await controller.cleanupTaskForTests?.value
    }

    @Test func disablingWhileStatusIsPendingDiscardsTheStaleResult() async throws {
        let daemon = PendingTailscaleStatus(throwing: TailscaleLocalAPI.Error.httpError(500))
        let settings = makeSettings(enabled: true)
        let controller = makeController(settings, daemon)
        defer { daemon.release(); controller.stop() }
        let superseded = try #require(controller.reconcileTaskForTests)
        await daemon.started.wait()
        settings.isEnabled = false
        controller.reconcileForTests()
        #expect(controller.reconcileTaskForTests == nil)
        daemon.release()
        await superseded.value
        await controller.cleanupTaskForTests?.value
        #expect(controller.status == .stopped)
    }
}
