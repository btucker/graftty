import Foundation
import GhosttyKit

/// Result of importing one older history page into a mounted surface.
public enum InMemoryTerminalHistoryResult: Equatable, Sendable {
    case applied(rows: UInt64)
    case requiresRecovery
    case limitReached
    case stale
    case failed

    init(status: Int32, appliedRows: Int) {
        switch status {
        case 1 where appliedRows > 0: self = .applied(rows: UInt64(appliedRows))
        case 2: self = .requiresRecovery
        case 3: self = .limitReached
        case 4: self = .stale
        default: self = .failed
        }
    }
}

public extension InMemoryTerminalSession {
    /// Waits for earlier live writes and snapshot operations before changing
    /// the surface layout. Returns false if canceled or the surface detaches.
    func flushOutput() async -> Bool {
        await performSnapshotOperation(canceledResult: false) { _ in true }
    }

    /// Installs a READY prefix after earlier output has finished. The native
    /// installation runs on main; later output waits for installation to finish.
    /// Generations must be nonzero and increase for each replacement checkpoint.
    func installSnapshot(_ data: Data, generation: UInt64) async -> Bool {
        guard !data.isEmpty, generation != 0 else { return false }
        return await performSnapshotOperation(onMainThread: true, canceledResult: false) { [snapshotOperations] surface in
            snapshotOperations.install(surface, data, generation)
        }
    }

    /// Prepends one complete PAGE record, serialized with live terminal output.
    /// Screen 0 is primary and screen 1 is alternate. A zero-row native result
    /// never counts as a successfully loaded page.
    func appendHistory(
        _ data: Data,
        generation: UInt64,
        screen: UInt16
    ) async -> InMemoryTerminalHistoryResult {
        guard !data.isEmpty, generation != 0, screen <= 1 else { return .failed }
        return await performSnapshotOperation(canceledResult: .stale) { [snapshotOperations] surface in
            snapshotOperations.append(surface, data, generation, screen)
        }
    }

    func nearHistoryTop(
        generation: UInt64,
        screen: UInt16,
        thresholdRows: UInt32 = 64
    ) -> Bool {
        guard generation != 0, screen <= 1 else { return false }
        return surfaceAccess.withCurrentSurface { surface in
            snapshotOperations.nearTop(surface, generation, screen, thresholdRows)
        } ?? false
    }

    func gridMatches(columns: UInt16, rows: UInt16) -> Bool {
        guard columns > 0, rows > 0 else { return false }
        return surfaceAccess.withCurrentSurface { surface in
            snapshotOperations.gridMatches(surface, columns, rows)
        } ?? false
    }

    /// Apply an in-band source grid after prior output, on the main thread.
    /// Later physical/font resizes report intent without changing parsing.
    func setSourceGrid(columns: UInt16, rows: UInt16) async -> Bool {
        guard columns > 0, rows > 0 else { return false }
        return await performSnapshotOperation(onMainThread: true, canceledResult: false) { surface in
            ghostty_surface_set_source_grid(surface, columns, rows)
        }
    }

    /// Release source-controlled parsing before a legacy stream resumes.
    func clearSourceGrid() async -> Bool {
        await performSnapshotOperation(onMainThread: true, canceledResult: false) { surface in
            ghostty_surface_clear_source_grid(surface)
        }
    }

    private func performSnapshotOperation<Result: Sendable>(
        onMainThread: Bool = false,
        canceledResult: Result,
        operation: @escaping @Sendable (ghostty_surface_t) -> Result
    ) async -> Result {
        let cancellation = SnapshotOperationCancellation()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                surfaceAccess.enqueueOperation(onMainThread: onMainThread, operation: { surface in
                    guard !cancellation.isCanceled else { return canceledResult }
                    return operation(surface)
                }, completion: { result in
                    continuation.resume(returning: result ?? canceledResult)
                })
            }
        } onCancel: {
            cancellation.cancel()
        }
    }
}

struct InMemoryTerminalSnapshotOperations: Sendable {
    var install: @Sendable (ghostty_surface_t, Data, UInt64) -> Bool
    var append: @Sendable (ghostty_surface_t, Data, UInt64, UInt16) -> InMemoryTerminalHistoryResult
    var nearTop: @Sendable (ghostty_surface_t, UInt64, UInt16, UInt32) -> Bool
    var gridMatches: @Sendable (ghostty_surface_t, UInt16, UInt16) -> Bool

    static let live = InMemoryTerminalSnapshotOperations(
        install: { surface, data, generation in
            precondition(Thread.isMainThread)
            return data.withUnsafeBytes { bytes in
                ghostty_surface_snapshot_ready(
                    surface, generation, bytes.baseAddress?.assumingMemoryBound(to: UInt8.self), bytes.count
                )
            }
        },
        append: { surface, data, generation, screen in
            var rows = 0
            let status = data.withUnsafeBytes { bytes in
                ghostty_surface_snapshot_page(
                    surface, generation, screen,
                    bytes.baseAddress?.assumingMemoryBound(to: UInt8.self), bytes.count, &rows
                )
            }
            return InMemoryTerminalHistoryResult(status: status, appliedRows: rows)
        },
        nearTop: { ghostty_surface_snapshot_near_top($0, $1, $2, $3) },
        gridMatches: { ghostty_surface_grid_matches($0, $1, $2) }
    )
}

private final class SnapshotOperationCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var canceled = false
    var isCanceled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return canceled
    }
    func cancel() {
        lock.lock()
        canceled = true
        lock.unlock()
    }
}
