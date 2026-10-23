// Test-only. The TLS context loads the bundled localhost fixture cert —
// do NOT reuse these helpers in production code paths. The trust-all
// URLSession client lives in Apple/Web/WebTrustAllSession.swift: it needs
// Security's `serverTrust`, which swift-corelibs-foundation does not offer.

import Foundation
import Testing
import NIOSSL
@testable import GrafttyKit

func makeTestTLSContext() throws -> NIOSSLContext {
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

func makeTestTLSProvider() throws -> WebTLSContextProvider {
    WebTLSContextProvider(initial: try makeTestTLSContext())
}

/// Returns `true` when running under CI (the `CI` env var is set).
/// Used by web-server integration tests that hang on GitHub Actions
/// runners and must be skipped there while still running locally.
/// Plain function rather than a computed property so call sites read
/// as `if skipInCI() { return }` — no `Self.` prefix needed.
func skipInCI() -> Bool {
    ProcessInfo.processInfo.environment["CI"] != nil
}
