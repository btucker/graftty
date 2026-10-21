import Foundation
import NIOConcurrencyHelpers

typealias SSHSubsystemReplyWaiter = SSHReplyWaiter<Void>

/// Schedules a reply deadline's callback and returns its cancellation.
/// Tests inject a manual deadline; production uses `after(_:)`.
struct ReplyDeadline: Sendable {
    let schedule: @Sendable (@escaping @Sendable () -> Void) -> @Sendable () -> Void

    /// Fires after `duration` of elapsed time on Swift's clock.
    static func after(_ duration: Duration) -> ReplyDeadline {
        ReplyDeadline { callback in
            let task = Task {
                do { try await Task.sleep(for: duration) }
                catch { return }
                callback()
            }
            return { task.cancel() }
        }
    }
}

/// Coordinates an SSH reply or child-channel open.
///
/// Cancellation may run before the async operation registers its continuation.
/// Keeping an explicit terminal state lets the later registration observe that
/// cancellation (or a child-channel close) and resume immediately instead of
/// leaving an unchecked continuation suspended forever.
final class SSHReplyWaiter<Value: Sendable>: @unchecked Sendable {
    typealias ScheduleTimeout = @Sendable (
        @escaping @Sendable () -> Void
    ) -> @Sendable () -> Void

    private enum State {
        case idle
        case waiting(CheckedContinuation<Value, Error>)
        case finished(Result<Value, Error>)
    }

    private let lock = NIOLock()
    private var state: State = .idle
    private var cancelTimeout: (@Sendable () -> Void)?

    /// The WebRTC transport uses NIOAsyncTestingEventLoop, whose scheduled
    /// clock does not advance with elapsed time. Network deadlines must use
    /// Swift's clock instead of that event loop's scheduleTask.
    /// `onAbort` runs, before the caller resumes, when the deadline or (absent
    /// `onCancel`) cancellation wins.
    func wait(
        timeout: Duration,
        timeoutError: any Error,
        onAbort: @escaping @Sendable () -> Void,
        onCancel: (@Sendable () -> Void)? = nil,
        start: @escaping @Sendable () -> Void
    ) async throws -> Value {
        try await wait(
            scheduleTimeout: ReplyDeadline.after(timeout).schedule,
            timeoutError: timeoutError,
            onAbort: onAbort,
            onCancel: onCancel,
            start: start
        )
    }

    func wait(
        scheduleTimeout: @escaping ScheduleTimeout,
        timeoutError: any Error,
        onAbort: @escaping @Sendable () -> Void,
        onCancel: (@Sendable () -> Void)? = nil,
        start: @escaping @Sendable () -> Void
    ) async throws -> Value {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                let completedResult: Result<Value, Error>? = lock.withLock {
                    switch state {
                    case .idle:
                        state = .waiting(continuation)
                        return nil
                    case .waiting:
                        return Result<Value, Error>.failure(
                            CancellationError()
                        )
                    case .finished(let result):
                        return result
                    }
                }
                if let completedResult {
                    continuation.resume(with: completedResult)
                    return
                }

                let cancelTimeout = scheduleTimeout { [weak self] in
                    self?.finish(.failure(timeoutError), beforeResuming: onAbort)
                }
                let shouldStart = lock.withLock {
                    guard case .waiting = state else { return false }
                    self.cancelTimeout = cancelTimeout
                    return true
                }
                guard shouldStart else {
                    cancelTimeout()
                    return
                }
                start()
            }
        } onCancel: { [weak self] in
            self?.finish(.failure(CancellationError()), beforeResuming: onCancel ?? onAbort)
        }
    }

    /// Resolves the wait once; later calls return `false`. `beforeResuming`
    /// runs only for the call that wins, after the waiter is resolved but
    /// before the caller resumes, so teardown it performs is complete
    /// before the caller can act on the result.
    @discardableResult
    func finish(
        _ result: Result<Value, Error>,
        beforeResuming: (@Sendable () -> Void)? = nil
    ) -> Bool {
        let completion: (
            continuation: CheckedContinuation<Value, Error>?,
            cancelTimeout: (@Sendable () -> Void)?,
            didFinish: Bool
        ) = lock.withLock {
            let continuation: CheckedContinuation<Value, Error>?
            switch state {
            case .idle:
                continuation = nil
            case .waiting(let waiting):
                continuation = waiting
            case .finished:
                return (
                    continuation: nil,
                    cancelTimeout: nil,
                    didFinish: false
                )
            }
            state = .finished(result)
            let timeout = cancelTimeout
            cancelTimeout = nil
            return (
                continuation: continuation,
                cancelTimeout: timeout,
                didFinish: true
            )
        }
        guard completion.didFinish else { return false }
        beforeResuming?()
        completion.cancelTimeout?()
        completion.continuation?.resume(with: result)
        return true
    }
}
