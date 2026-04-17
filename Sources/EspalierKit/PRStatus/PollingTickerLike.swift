import Foundation

/// Abstraction of `PollingTicker` for test injection and to break the
/// EspalierKit → AppKit dependency. Views wire the real `PollingTicker`
/// (which lives in the app target) via this protocol.
@MainActor
public protocol PollingTickerLike: AnyObject {
    func start(onTick: @MainActor @escaping () async -> Void)
    func stop()
    func pulse()
}
