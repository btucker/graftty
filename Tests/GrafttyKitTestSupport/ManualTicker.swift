import GrafttyKit

/// Test double for `PollingTickerLike`. Captures the tick closure but never
/// fires it on its own: the test drives ticks with `fire()`, or never fires
/// to keep a store's polling inert.
@MainActor
public final class ManualTicker: PollingTickerLike {
    private let clearsTickOnStop: Bool
    private var onTick: (@MainActor () async -> Void)?
    public private(set) var stopCallCount = 0
    public private(set) var pulseCallCount = 0

    /// - Parameter clearsTickOnStop: Pass `false` to keep the tick closure
    ///   after `stop()`, so a test can fire a stopped ticker and prove the
    ///   store itself ignores the stale tick.
    public init(clearsTickOnStop: Bool = true) {
        self.clearsTickOnStop = clearsTickOnStop
    }

    public func start(onTick: @MainActor @escaping () async -> Void) { self.onTick = onTick }

    public func stop() {
        stopCallCount += 1
        if clearsTickOnStop { onTick = nil }
    }

    public func pulse() { pulseCallCount += 1 }

    /// Invokes the captured tick handler, if any.
    public func fire() async { await onTick?() }
}
