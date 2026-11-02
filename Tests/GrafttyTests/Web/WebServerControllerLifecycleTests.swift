import Foundation
import Testing
@testable import GrafttyKit
@testable import Graftty

/// A one-shot gate. Deliberately ignores cancellation so tests can release an
/// obsolete dependency after a newer desired state has already taken effect.
final class WebLifecycleGate: @unchecked Sendable {
    private let lock = NSLock()
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    var isOpen: Bool { lock.withLock { opened } }

    func wait() async {
        await withCheckedContinuation { continuation in
            let ready = lock.withLock {
                if opened { return true }
                waiters.append(continuation)
                return false
            }
            if ready { continuation.resume() }
        }
    }

    func open() {
        let pending = lock.withLock {
            opened = true
            defer { waiters.removeAll() }
            return waiters
        }
        for waiter in pending { waiter.resume() }
    }
}

@Suite("@spec WEB-1.19: When Web Access is disabled or reconfigured during bring-up or shutdown, the application shall cancel obsolete work, await its listener cleanup before replacement startup, and publish only the latest settings generation.")
@MainActor
struct WebServerControllerLifecycleTests {
    private func certificate() throws -> (cert: Data, key: Data) {
        let fixtures = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("GrafttyKitTests/Web/Fixtures")
        return (
            try Data(contentsOf: fixtures.appendingPathComponent("test-tls-cert.pem")),
            try Data(contentsOf: fixtures.appendingPathComponent("test-tls-key.pem"))
        )
    }

    @Test func rapidToggleDuringCertificateFetchDiscardsObsoleteSuccess() async throws {
        let suite = "WebCertToggle-\(UUID())"
        let store = try #require(UserDefaults(suiteName: suite))
        defer { store.removePersistentDomain(forName: suite) }
        let settings = WebAccessSettings(store: store)
        settings.isEnabled = true
        settings.port = 0
        let entered = WebLifecycleGate()
        let release = WebLifecycleGate()
        let pair = try certificate()
        var starts = 0
        let controller = WebServerController(
            settings: settings,
            zmxExecutable: URL(fileURLWithPath: "/dev/null"), zmxDir: URL(fileURLWithPath: "/tmp"),
            fetchTailscaleStatus: {
                (TailscaleLocalAPI(socketPath: "/unused"), .init(loginName: "owner", tailscaleIPs: ["127.0.0.1"], dnsName: "host.ts.net"))
            },
            fetchCertificate: { _, _ in
                entered.open()
                await release.wait()
                return pair
            },
            startServer: { server in starts += 1; try await server.startAsync() }
        )
        defer { release.open(); controller.stop() }
        await entered.wait()
        #expect(controller.status == .provisioningCert)
        let oldAttempt = controller.reconcileTaskForTests
        settings.isEnabled = false
        controller.reconcileForTests()
        #expect(controller.status == .stopped)
        settings.isEnabled = true
        controller.reconcileForTests()
        let freshAttempt = controller.reconcileTaskForTests
        release.open()
        await oldAttempt?.value
        await freshAttempt?.value
        #expect(starts == 1)
        #expect(controller.serverHostname == "host.ts.net")
        controller.stop()
        await controller.cleanupTaskForTests?.value
    }

    @Test func obsoleteBindClosesBeforeReplacementAndStopReturnsWhileCleanupIsPending() async throws {
        let suite = "WebBindToggle-\(UUID())"
        let store = try #require(UserDefaults(suiteName: suite))
        defer { store.removePersistentDomain(forName: suite) }
        let settings = WebAccessSettings(store: store)
        settings.isEnabled = true
        settings.port = 0
        let binding = WebLifecycleGate()
        let releaseBind = WebLifecycleGate()
        let stopping = WebLifecycleGate()
        let releaseStop = WebLifecycleGate()
        let pair = try certificate()
        var starts = 0
        var stops = 0
        let controller = WebServerController(
            settings: settings,
            zmxExecutable: URL(fileURLWithPath: "/dev/null"), zmxDir: URL(fileURLWithPath: "/tmp"),
            fetchTailscaleStatus: {
                (TailscaleLocalAPI(socketPath: "/unused"), .init(loginName: "owner", tailscaleIPs: ["127.0.0.1"], dnsName: "host.ts.net"))
            },
            fetchCertificate: { _, _ in pair },
            startServer: { server in
                starts += 1
                binding.open()
                await releaseBind.wait()
                // Model a dependency that returns success despite cancellation.
                try server.start()
            },
            stopServer: { server in
                stops += 1
                stopping.open()
                await releaseStop.wait()
                await server.stopAsync()
            }
        )
        defer { releaseBind.open(); releaseStop.open(); controller.stop() }
        await binding.wait()
        controller.stop()
        #expect(controller.status == .stopped)
        #expect(controller.serverHostname == nil)
        settings.isEnabled = false
        controller.reconcileForTests()
        settings.isEnabled = true
        controller.reconcileForTests()
        let replacement = controller.reconcileTaskForTests
        releaseBind.open()
        await stopping.wait()
        #expect(starts == 1, "replacement started before obsolete listener cleanup")
        #expect(controller.serverHostname == nil, "obsolete bind published its hostname")
        releaseStop.open()
        await replacement?.value
        #expect(starts == 2)
        #expect(stops == 1)
        #expect(controller.serverHostname == "host.ts.net")
        controller.stop()
        await controller.cleanupTaskForTests?.value
        #expect(stops == 2)
    }

    @Test func providerChangeDuringBindRebuildsTheCapturedConfiguration() async throws {
        let suite = "WebProviderBind-\(UUID())"
        let store = try #require(UserDefaults(suiteName: suite))
        defer { store.removePersistentDomain(forName: suite) }
        let settings = WebAccessSettings(store: store)
        settings.isEnabled = true
        settings.port = 0
        let binding = WebLifecycleGate()
        let release = WebLifecycleGate()
        let providerUsed = WebLifecycleGate()
        let pair = try certificate()
        var starts = 0
        let controller = WebServerController(
            settings: settings,
            zmxExecutable: URL(fileURLWithPath: "/dev/null"), zmxDir: URL(fileURLWithPath: "/tmp"),
            fetchTailscaleStatus: {
                (TailscaleLocalAPI(socketPath: "/unused"), .init(loginName: "owner", tailscaleIPs: ["127.0.0.1"], dnsName: "host.ts.net"))
            },
            fetchCertificate: { _, _ in pair },
            startServer: { server in
                starts += 1
                binding.open()
                await release.wait()
                _ = await server.config.reposProvider()
                try await server.startAsync()
            }
        )
        defer { release.open(); controller.stop() }
        await binding.wait()
        controller.setReposProvider { providerUsed.open(); return [] }
        release.open()
        await controller.reconcileTaskForTests?.value
        #expect(starts == 2, "provider injection left the pending bind on its old configuration")
        #expect(providerUsed.isOpen)
        controller.stop()
        await controller.cleanupTaskForTests?.value
    }

    @Test func applicationShutdownRejectsSettingsChangesWhileCleanupIsPending() async throws {
        let suite = "WebQuitSettings-\(UUID())"
        let store = try #require(UserDefaults(suiteName: suite))
        defer { store.removePersistentDomain(forName: suite) }
        let settings = WebAccessSettings(store: store)
        settings.isEnabled = true
        settings.port = 0
        let stopping = WebLifecycleGate()
        let release = WebLifecycleGate()
        let pair = try certificate()
        var starts = 0
        let controller = WebServerController(
            settings: settings,
            zmxExecutable: URL(fileURLWithPath: "/dev/null"), zmxDir: URL(fileURLWithPath: "/tmp"),
            fetchTailscaleStatus: {
                (TailscaleLocalAPI(socketPath: "/unused"), .init(loginName: "owner", tailscaleIPs: ["127.0.0.1"], dnsName: "host.ts.net"))
            },
            fetchCertificate: { _, _ in pair },
            startServer: { server in starts += 1; try await server.startAsync() },
            stopServer: { server in
                stopping.open()
                await release.wait()
                await server.stopAsync()
            }
        )
        defer { release.open(); controller.stop() }
        await controller.reconcileTaskForTests?.value
        let shutdown = Task { await controller.shutdown() }
        await stopping.wait()
        settings.isEnabled = false
        controller.reconcileForTests()
        settings.isEnabled = true
        settings.port += 1
        controller.reconcileForTests()
        #expect(controller.reconcileTaskForTests == nil)
        #expect(controller.status == .stopped)
        #expect(starts == 1)
        release.open()
        await shutdown.value
        #expect(controller.serverHostname == nil)
    }
}
