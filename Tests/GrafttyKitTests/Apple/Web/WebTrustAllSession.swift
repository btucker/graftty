// Test-only. Everything in this file trusts any server certificate
// and is meant exclusively for the bundled localhost fixture cert —
// do NOT reuse these helpers in production code paths.
//
// Under Apple/ because it needs Security's `serverTrust`, which
// swift-corelibs-foundation's URLSession does not support.

import Foundation

/// URLSession delegate that trusts any server cert. Used only in
/// the test suite to exercise the real TLS handshake against our
/// localhost-fixture cert.
final class TrustAllDelegate: NSObject, URLSessionDelegate {
    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        if let st = challenge.protectionSpace.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: st))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }
}

func trustAllSession() -> URLSession {
    URLSession(configuration: .ephemeral, delegate: TrustAllDelegate(), delegateQueue: nil)
}

func withTrustAllSession<T>(
    _ body: (URLSession) async throws -> T
) async throws -> T {
    let session = trustAllSession()
    defer { session.invalidateAndCancel() }
    return try await body(session)
}

func trustAllData(from url: URL) async throws -> (Data, URLResponse) {
    try await withTrustAllSession { session in
        try await session.data(from: url)
    }
}

func trustAllData(for request: URLRequest) async throws -> (Data, URLResponse) {
    try await withTrustAllSession { session in
        try await session.data(for: request)
    }
}
