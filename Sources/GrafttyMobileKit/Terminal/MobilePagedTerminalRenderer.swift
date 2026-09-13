#if canImport(UIKit)
import Foundation
import GhosttyTerminal
import GrafttyProtocol
import GrafttyRemoteClient

@MainActor
final class MobilePagedTerminalRenderer: PagedTerminalRenderer {
    nonisolated static var isSupported: Bool {
        #if GRAFTTY_PAGED_HISTORY
        true
        #else
        false
        #endif
    }
    private let session: InMemoryTerminalSession
    private let additionalHistoryRows: () -> UInt32
    private let prepareGrid: (UInt16, UInt16) -> Void

    init(session: InMemoryTerminalSession, additionalHistoryRows: @escaping () -> UInt32 = { 0 }, prepareGrid: @escaping (UInt16, UInt16) -> Void) {
        self.session = session
        self.additionalHistoryRows = additionalHistoryRows
        self.prepareGrid = prepareGrid
    }

    func install(_ checkpoint: PagedTerminalCheckpoint, generation: UInt64) async throws {
        #if GRAFTTY_PAGED_HISTORY
        try await resize(cols: checkpoint.cols, rows: checkpoint.rows)
        guard await session.installSnapshot(checkpoint.ready, generation: generation) else {
            throw Error.invalidSnapshot
        }
        #else
        throw Error.invalidSnapshot
        #endif
    }

    func resize(cols: UInt16, rows: UInt16) async throws {
        #if GRAFTTY_PAGED_HISTORY
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        // receive() queues VT bytes. Drain them before layout can change the
        // native grid, otherwise the resize could overtake older output.
        while !(await session.flushOutput()) {
            guard ContinuousClock.now < deadline else { throw Error.gridUnavailable }
            try await Task.sleep(for: .milliseconds(10))
        }
        prepareGrid(cols, rows)
        // Layout owns the local grid. Wait outside Ghostty's renderer lock
        // until SwiftUI has fitted the mounted view to the authoritative grid.
        while !session.gridMatches(columns: cols, rows: rows) {
            guard ContinuousClock.now < deadline else { throw Error.gridUnavailable }
            try await Task.sleep(for: .milliseconds(10))
        }
        try Task.checkCancellation()
        #else
        throw Error.invalidSnapshot
        #endif
    }

    func appendHistory(_ data: Data, screen: UInt16, generation: UInt64) async -> PagedTerminalPageResult {
        #if GRAFTTY_PAGED_HISTORY
        switch await session.appendHistory(data, generation: generation, screen: screen) {
        case .applied: return .applied
        case .requiresRecovery: return .requiresRecovery
        case .limitReached: return .limit
        case .stale: return .stale
        case .failed: return .failed
        }
        #else
        return .failed
        #endif
    }

    func isNearHistoryTop(screen: UInt16, generation: UInt64) -> Bool {
        #if GRAFTTY_PAGED_HISTORY
        // The fitted follower can display rows above the native viewport.
        // Treat those visible rows as demand even while the live grid stays
        // at the bottom. The native check still gates screen and generation.
        session.nearHistoryTop(generation: generation, screen: screen,
                               thresholdRows: max(20, additionalHistoryRows()))
        #else
        false
        #endif
    }

    enum Error: Swift.Error { case gridUnavailable, invalidSnapshot }
}
#endif
