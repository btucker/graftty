import Foundation
import NIOConcurrencyHelpers

/// Coordinates the reply to an SSH subsystem request.
///
/// Cancellation may run before the async operation registers its continuation.
/// Keeping an explicit terminal state lets the later registration observe that
/// cancellation (or a child-channel close) and resume immediately instead of
/// leaving an unchecked continuation suspended forever.
final class SSHSubsystemReplyWaiter: @unchecked Sendable {
    typealias ScheduleTimeout = @Sendable (
        @escaping @Sendable () -> Void
    ) -> @Sendable () -> Void

    private enum State {
        case idle
        case waiting(CheckedContinuation<Void, Error>)
        case finished(Result<Void, Error>)
    }

    private let lock = NIOLock()
    private var state: State = .idle
    private var cancelTimeout: (@Sendable () -> Void)?

    func wait(
        scheduleTimeout: @escaping ScheduleTimeout,
        timeoutError: any Error,
        onAbort: @escaping @Sendable () -> Void,
        start: @escaping @Sendable () -> Void
    ) async throws {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { continuation in
                let completedResult: Result<Void, Error>? = lock.withLock {
                    switch state {
                    case .idle:
                        state = .waiting(continuation)
                        return nil
                    case .waiting:
                        return Result<Void, Error>.failure(
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
                    guard self?.finish(.failure(timeoutError)) == true else {
                        return
                    }
                    onAbort()
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
            guard self?.finish(.failure(CancellationError())) == true else {
                return
            }
            onAbort()
        }
    }

    @discardableResult
    func finish(_ result: Result<Void, Error>) -> Bool {
        let completion: (
            continuation: CheckedContinuation<Void, Error>?,
            cancelTimeout: (@Sendable () -> Void)?,
            didFinish: Bool
        ) = lock.withLock {
            let continuation: CheckedContinuation<Void, Error>?
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
        completion.cancelTimeout?()
        completion.continuation?.resume(with: result)
        return true
    }
}
