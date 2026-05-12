#if canImport(UIKit)
import Foundation

public protocol Clock: Sendable {
    var now: Date { get }
    func sleep(for duration: TimeInterval) async throws
}

public struct SystemClock: Clock {
    public init() {}
    public var now: Date { Date() }
    public func sleep(for duration: TimeInterval) async throws {
        guard duration > 0 else { return }
        try await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
    }
}
#endif
