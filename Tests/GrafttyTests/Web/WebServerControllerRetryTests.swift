import Foundation
import Testing
@testable import GrafttyKit
@testable import Graftty

/// Cold-boot regression: after a Mac restart, macOS relaunches Graftty during
/// session-restore *before* `tailscaled` has finished coming up, so the first
/// server bring-up attempt commonly lands on a transient dependency failure
/// (Tailscale daemon unreachable, MagicDNS name not yet published, or cert not
/// yet mintable). Before WEB-1.14 the reconcile path set a failure status and
/// returned with no retry, so the web server never came online until the user
/// manually toggled Web Access — which is exactly the "server didn't come back"
/// symptom this suite guards against.
@Suite("@spec WEB-1.14: While web access is enabled and the latest server bring-up attempt failed with a transient dependency error (Tailscale daemon unreachable or not answering status, MagicDNS name not yet published, or certificate not yet mintable), the application shall automatically retry bring-up with capped exponential backoff until it succeeds or web access is disabled.")
struct WebServerControllerRetryTests {

    @Test func transientColdBootFailuresAreRetryable() {
        #expect(WebServerController.isTransientStartupFailure(.tailscaleUnavailable))
        #expect(WebServerController.isTransientStartupFailure(.magicDNSDisabled))
        #expect(WebServerController.isTransientStartupFailure(.certFetchFailed("acme exchange timed out")))
    }

    @Test func terminalAndSuccessStatusesAreNotRetried() {
        #expect(!WebServerController.isTransientStartupFailure(.stopped))
        #expect(!WebServerController.isTransientStartupFailure(.listening(addresses: ["100.64.0.1"], port: 8799)))
        #expect(!WebServerController.isTransientStartupFailure(.httpsCertsNotEnabled))
        #expect(!WebServerController.isTransientStartupFailure(.provisioningCert))
        #expect(!WebServerController.isTransientStartupFailure(.portUnavailable))
        #expect(!WebServerController.isTransientStartupFailure(.error("NIOBindError")))
    }

    @Test func backoffIsExponentialThenCapped() {
        #expect(WebServerController.retryDelay(afterTransientFailure: .tailscaleUnavailable, attempt: 1) == .seconds(2))
        #expect(WebServerController.retryDelay(afterTransientFailure: .tailscaleUnavailable, attempt: 2) == .seconds(4))
        #expect(WebServerController.retryDelay(afterTransientFailure: .tailscaleUnavailable, attempt: 3) == .seconds(8))
        #expect(WebServerController.retryDelay(afterTransientFailure: .tailscaleUnavailable, attempt: 4) == .seconds(16))
        // Capped so a tailnet that never recovers re-probes every 30s rather
        // than backing off to hours.
        #expect(WebServerController.retryDelay(afterTransientFailure: .tailscaleUnavailable, attempt: 10) == .seconds(30))
    }

    @Test func terminalStatusYieldsNoRetryDelay() {
        #expect(WebServerController.retryDelay(afterTransientFailure: .portUnavailable, attempt: 1) == nil)
        #expect(WebServerController.retryDelay(afterTransientFailure: .error("boom"), attempt: 1) == nil)
        #expect(WebServerController.retryDelay(afterTransientFailure: .httpsCertsNotEnabled, attempt: 1) == nil)
    }
}

@Suite("@spec WEB-1.17: When a Tailscale status query fails with an unreachable socket, malformed response or invalid JSON, or HTTP 5xx, the application shall classify that attempt as transient; other HTTP errors and unrelated errors shall remain terminal.")
struct WebServerStatusFailureTests {
    @Test(arguments: [TailscaleLocalAPI.Error.socketUnreachable, .malformedResponse, .httpError(500), .httpError(503), .httpError(599)])
    func unavailableStatusIsRetryable(error: TailscaleLocalAPI.Error) {
        #expect(WebServerController.isTransientStatusError(error))
    }

    @Test(arguments: [TailscaleLocalAPI.Error.httpError(400), .httpError(401), .httpError(403), .httpError(404), .httpError(600), .httpsCertsDisabled])
    func otherErrorsAreTerminal(error: TailscaleLocalAPI.Error) {
        #expect(!WebServerController.isTransientStatusError(error))
    }
}

@Suite("Controller automatic status recovery")
@MainActor
struct WebServerControllerStatusRecoveryTests {
    @Test(arguments: [TailscaleLocalAPI.Error.malformedResponse, .httpError(503)])
    func retriesStatusFailureWithoutSettingsToggle(error: TailscaleLocalAPI.Error) async throws {
        try await verifyRecovery(error: error)
    }

    @Test func invalidStatusJSONRetriesWithoutSettingsToggle() async throws {
        do {
            _ = try TailscaleLocalAPI.parseStatus(Data("{\"Self\":".utf8))
            Issue.record("malformed status JSON decoded")
        } catch {
            try await verifyRecovery(error: error)
        }
    }

    private func verifyRecovery(error: any Error) async throws {
        let suite = "WebStatusRecovery-\(UUID())"
        let store = try #require(UserDefaults(suiteName: suite))
        defer { store.removePersistentDomain(forName: suite) }
        let settings = WebAccessSettings(store: store)
        settings.isEnabled = true
        settings.port = 0
        let ticks = AsyncStream<Void>.makeStream()
        let attempts = RecoveryAttempts(firstError: error)
        let fixtures = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("GrafttyKitTests/Web/Fixtures")
        let cert = try Data(contentsOf: fixtures.appendingPathComponent("test-tls-cert.pem"))
        let key = try Data(contentsOf: fixtures.appendingPathComponent("test-tls-key.pem"))
        let controller = WebServerController(
            settings: settings,
            zmxExecutable: URL(fileURLWithPath: "/dev/null"),
            zmxDir: URL(fileURLWithPath: "/tmp"),
            fetchTailscaleStatus: { try await attempts.fetch() },
            retrySleep: { delay in
                #expect(delay == .seconds(2))
                var iterator = ticks.stream.makeAsyncIterator()
                guard await iterator.next() != nil else { throw CancellationError() }
            },
            fetchCertificate: { _, _ in (cert, key) }
        )
        defer { controller.stop(); ticks.continuation.finish() }
        await controller.reconcileTaskForTests?.value
        #expect(controller.status == .tailscaleUnavailable)
        // A buffered clock tick advances only an already scheduled retry.
        ticks.continuation.yield(())
        if controller.status == .tailscaleUnavailable {
            await attempts.retried()
            await controller.reconcileTaskForTests?.value
            guard case .listening = controller.status else {
                Issue.record("automatic retry did not listen: \(controller.status)")
                return
            }
            #expect(controller.serverHostname == "host.ts.net")
        }
    }
}

private actor RecoveryAttempts {
    private let firstError: any Error
    private var count = 0
    private let retry = AsyncStream<Void>.makeStream()

    init(firstError: any Error) { self.firstError = firstError }

    func fetch() throws -> (api: TailscaleLocalAPI, status: TailscaleLocalAPI.Status) {
        count += 1
        if count == 1 { throw firstError }
        retry.continuation.yield(())
        return (TailscaleLocalAPI(socketPath: "/unused"), .init(
            loginName: "owner@example.com", tailscaleIPs: ["127.0.0.1"], dnsName: "host.ts.net"
        ))
    }

    func retried() async {
        var iterator = retry.stream.makeAsyncIterator()
        _ = await iterator.next()
    }
}

@Suite("Controller terminal status errors")
@MainActor
struct WebServerControllerTerminalStatusTests {
    @Test(arguments: [TailscaleLocalAPI.Error.httpError(400), .httpError(401), .httpError(403), .httpError(404), .httpError(600), .httpsCertsDisabled])
    func terminalStatusDoesNotScheduleRetry(error: TailscaleLocalAPI.Error) async throws {
        let suite = "WebStatusTerminal-\(UUID())"
        let store = try #require(UserDefaults(suiteName: suite))
        defer { store.removePersistentDomain(forName: suite) }
        let settings = WebAccessSettings(store: store)
        settings.isEnabled = true
        let controller = WebServerController(
            settings: settings,
            zmxExecutable: URL(fileURLWithPath: "/dev/null"), zmxDir: URL(fileURLWithPath: "/tmp"),
            fetchTailscaleStatus: { throw error },
            retrySleep: { _ in Issue.record("terminal status scheduled a retry") }
        )
        defer { controller.stop() }
        await controller.reconcileTaskForTests?.value
        #expect(controller.status == .error("\(error)"))
        #expect(controller.retryTaskForTests == nil)
    }
}
