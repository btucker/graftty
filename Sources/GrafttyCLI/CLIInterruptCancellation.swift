import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Let an async CLI operation release subprocesses and streams on Ctrl-C.
func withCLIInterruptCancellation<T: Sendable>(_ body: @escaping @Sendable () async throws -> T) async throws -> T {
    let operation = Task { try await body() }
    let previousInterrupt = signal(SIGINT, SIG_IGN)
    let previousTerminate = signal(SIGTERM, SIG_IGN)
    let signals = [SIGINT, SIGTERM].map { number in
        let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
        source.setEventHandler { operation.cancel() }
        source.resume()
        return source
    }
    defer {
        signals.forEach { $0.cancel() }
        signal(SIGINT, previousInterrupt)
        signal(SIGTERM, previousTerminate)
    }
    return try await withTaskCancellationHandler {
        try await operation.value
    } onCancel: { operation.cancel() }
}
