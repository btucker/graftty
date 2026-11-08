#if canImport(WebRTC)
import Foundation

/// Owns a native shutdown action until it has run and released its captures.
/// WebRTC close and proxy destruction synchronously marshal to signaling and
/// worker threads. Those threads can wait for event-log work on GCD. Blocking
/// Swift's cooperative pool here can prevent that GCD work from ever starting.
public final class WebRTCShutdown: @unchecked Sendable {
    private static let queue = DispatchQueue(label: "com.graftty.webrtc.shutdown")

    // After initialization, only the shutdown queue accesses this closure.
    // Its captures must contain detached resources, with no actor mutations.
    private var operation: (() -> Void)?

    public init(_ operation: @escaping () -> Void) {
        self.operation = operation
    }

    /// Concurrent callers join the same action. Cancellation does not abandon
    /// native cleanup. The action's captures are released before callers resume.
    public func run() async {
        await withCheckedContinuation { continuation in
            Self.queue.async {
                self.perform()
                continuation.resume()
            }
        }
    }

    /// Transfers a final native reference from a synchronous Swift deinit.
    internal func schedule() {
        Self.queue.async { self.perform() }
    }

    private func perform() {
        let operation = self.operation
        self.operation = nil
        operation?()
        // Returning releases the closure and native captures on this queue,
        // before run() resumes its continuation on the cooperative executor.
    }
}
#endif
