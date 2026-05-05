import Testing
import Foundation
import NIOSSL
@testable import GrafttyKit

@Suite("WebCertRenewer")
struct WebCertRenewerTests {

    @Test func renewNow_swapsContext() async throws {
        let initial = try makeTestTLSContext()
        let replacement = try makeTestTLSContext()
        let provider = WebTLSContextProvider(initial: initial)
        let renewer = WebCertRenewer(
            provider: provider,
            interval: 3600,
            fetch: { replacement }
        )
        await renewer.renewNow()
        #expect(provider.current() === replacement)
    }

    @Test("""
    @spec WEB-8.3: While the server is listening, the application shall re-fetch the cert every 24 hours. If the returned PEM bytes differ from the currently-serving material, the application shall construct a new `NIOSSLContext` and atomically swap the reference read by the per-channel `ChannelInitializer` via `WebTLSContextProvider.swap(_:)`. The application shall not close the listening socket and shall not disturb in-flight connections — existing WebSocket streams keep their prior context for their lifetime.
    """)
    func startRenewsAfterConfiguredIntervalAndSwapsContext() async throws {
        let initial = try makeTestTLSContext()
        let replacement = try makeTestTLSContext()
        let provider = WebTLSContextProvider(initial: initial)
        let renewer = WebCertRenewer(
            provider: provider,
            interval: 0.01,
            fetch: { replacement }
        )
        renewer.start()
        defer { renewer.stop() }

        for _ in 0..<20 {
            if provider.current() === replacement { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        Issue.record("renewal interval did not swap the TLS context")
    }

    @Test func renewNow_swallowsFetchError() async throws {
        let initial = try makeTestTLSContext()
        let provider = WebTLSContextProvider(initial: initial)
        struct FetchFailed: Error {}
        let renewer = WebCertRenewer(
            provider: provider,
            interval: 3600,
            fetch: { throw FetchFailed() }
        )
        await renewer.renewNow()
        // Provider still holds the original — renewer must not tear
        // down the server just because one fetch failed.
        #expect(provider.current() === initial)
    }

    @Test func startStop_doesNotLeakTask() async throws {
        let provider = WebTLSContextProvider(initial: try makeTestTLSContext())
        let renewer = WebCertRenewer(
            provider: provider,
            interval: 0.01,
            fetch: { throw NSError(domain: "noop", code: 0) }
        )
        renewer.start()
        try await Task.sleep(nanoseconds: 50_000_000)  // let timer fire >= once
        renewer.stop()
        // If stop() didn't cancel, the timer would keep firing and
        // eventually crash on destruction. The mere absence of crash
        // + clean exit is the pass signal. We assert the public state
        // by calling stop() twice — idempotency is the only
        // observable contract here.
        renewer.stop()
    }
}
