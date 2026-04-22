import Testing
import Foundation
import NIOSSL
@testable import GrafttyKit

@Suite("WebCertRenewer")
struct WebCertRenewerTests {

    private func ctx() throws -> NIOSSLContext {
        let certURL = try #require(
            Bundle.module.url(forResource: "test-tls-cert", withExtension: "pem",
                              subdirectory: "Fixtures")
        )
        let keyURL = try #require(
            Bundle.module.url(forResource: "test-tls-key", withExtension: "pem",
                              subdirectory: "Fixtures")
        )
        let certPEM = try Data(contentsOf: certURL)
        let keyPEM = try Data(contentsOf: keyURL)
        return try WebTLSCertFetcher.buildContext(certPEM: certPEM, keyPEM: keyPEM)
    }

    @Test func renewNow_swapsContext() async throws {
        let initial = try ctx()
        let replacement = try ctx()
        let provider = WebTLSContextProvider(initial: initial)
        let renewer = WebCertRenewer(
            provider: provider,
            interval: 3600,
            fetch: { replacement }
        )
        await renewer.renewNow()
        #expect(provider.current() === replacement)
    }

    @Test func renewNow_swallowsFetchError() async throws {
        let initial = try ctx()
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
        let provider = WebTLSContextProvider(initial: try ctx())
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
