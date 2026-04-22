import Foundation
import NIOSSL

/// Periodically re-fetches the TLS cert and swaps it into a
/// `WebTLSContextProvider` without restarting the listening socket.
/// WEB-8.3.
///
/// The fetch closure is the injection point — in production it's
/// `{ try await TailscaleLocalAPI.autoDetected().certPair(for: fqdn) }`
/// wrapped with `WebTLSCertFetcher.buildContext`; in tests it's a
/// canned context. Failures during renewal are logged and swallowed:
/// the existing context keeps serving until the next tick.
///
/// Logging uses `NSLog` deliberately — GrafttyKit has no logger
/// abstraction and we don't want to couple it to one just for this.
public final class WebCertRenewer: @unchecked Sendable {
    public typealias Fetch = @Sendable () async throws -> NIOSSLContext

    private let provider: WebTLSContextProvider
    private let interval: TimeInterval
    private let fetch: Fetch
    private let lock = NSLock()
    private var task: Task<Void, Never>?

    public init(provider: WebTLSContextProvider, interval: TimeInterval, fetch: @escaping Fetch) {
        self.provider = provider
        self.interval = interval
        self.fetch = fetch
    }

    public func start() {
        lock.lock(); defer { lock.unlock() }
        guard task == nil else { return }
        let provider = self.provider
        let interval = self.interval
        let fetch = self.fetch
        task = Task.detached { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                } catch {
                    return
                }
                guard self != nil else { return }
                do {
                    let new = try await fetch()
                    provider.swap(new)
                } catch {
                    NSLog("[WebCertRenewer] renewal fetch failed: \(error)")
                }
            }
        }
    }

    public func stop() {
        lock.lock(); defer { lock.unlock() }
        task?.cancel()
        task = nil
    }

    /// Testing seam — invoke the fetch closure immediately instead of
    /// waiting for the timer.
    public func renewNow() async {
        do {
            let new = try await fetch()
            provider.swap(new)
        } catch {
            NSLog("[WebCertRenewer] manual renewal failed: \(error)")
        }
    }
}
