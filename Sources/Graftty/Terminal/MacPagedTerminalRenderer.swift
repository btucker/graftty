import Foundation
import GhosttyKit
import GrafttyProtocol
import GrafttyRemoteClient

/// Drains native calls before SurfaceHandle frees the borrowed surface.
final class MacPagedSurface: @unchecked Sendable {
    private let lock = NSRecursiveLock()
    private var surface: ghostty_surface_t?

    init(_ surface: ghostty_surface_t) { self.surface = surface }

    func withSurface<T>(_ body: (ghostty_surface_t) throws -> T) rethrows -> T? {
        try lock.withLock {
            guard let surface else { return nil }
            return try body(surface)
        }
    }

    func close() { lock.withLock { surface = nil } }

    func write(_ data: Data) {
        withSurface { surface in
            data.withUnsafeBytes { bytes in
                guard let base = bytes.baseAddress else { return }
                ghostty_surface_write_buffer(surface, base.assumingMemoryBound(to: UInt8.self), UInt(bytes.count))
            }
        }
    }
}

@MainActor
final class MacPagedTerminalRenderer: PagedTerminalRenderer {
    nonisolated static var isSupported: Bool {
        #if GRAFTTY_PAGED_HISTORY
        true
        #else
        false
        #endif
    }

    private let surface: MacPagedSurface
    private let prepareGrid: (DisplayGrid?) -> Void

    init(surface: MacPagedSurface, prepareGrid: @escaping (DisplayGrid?) -> Void) {
        self.surface = surface
        self.prepareGrid = prepareGrid
    }

    func install(_ checkpoint: PagedTerminalCheckpoint, generation: UInt64) async throws {
        #if GRAFTTY_PAGED_HISTORY
        try await resize(cols: checkpoint.cols, rows: checkpoint.rows)
        let installed = surface.withSurface { surface in
            checkpoint.ready.withUnsafeBytes { bytes in
                ghostty_surface_snapshot_ready(surface, generation,
                    bytes.baseAddress!.assumingMemoryBound(to: UInt8.self), bytes.count)
            }
        }
        guard installed == true else { throw Error.invalidSnapshot }
        #else
        throw Error.invalidSnapshot
        #endif
    }

    func resize(cols: UInt16, rows: UInt16) async throws {
        #if GRAFTTY_PAGED_HISTORY
        try Task.checkCancellation()
        prepareGrid(try DisplayGrid(cols: cols, rows: rows))
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while surface.withSurface({ ghostty_surface_grid_matches($0, cols, rows) }) != true {
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
        let result = surface.withSurface { surface in
            data.withUnsafeBytes { bytes in
                var rows = 0
                return ghostty_surface_snapshot_page(surface, generation, screen,
                    bytes.baseAddress!.assumingMemoryBound(to: UInt8.self), bytes.count, &rows)
            }
        }
        switch result {
        case 1: return .applied
        case 2: return .requiresRecovery
        case 3: return .limit
        case 4: return .stale
        default: return .failed
        }
        #else
        return .failed
        #endif
    }

    func isNearHistoryTop(screen: UInt16, generation: UInt64) -> Bool {
        #if GRAFTTY_PAGED_HISTORY
        surface.withSurface { ghostty_surface_snapshot_near_top($0, generation, screen, 20) } == true
        #else
        false
        #endif
    }

    enum Error: Swift.Error { case invalidSnapshot, gridUnavailable }
}

/// Both Mac transports use the same screen-first import and bounded backfill.
@MainActor
final class MacPagedAttachment {
    let coordinator: PagedTerminalCoordinator
    private var poll: Task<Void, Never>?
    private let finishGrid: () -> Void
    private var restoringGrid = false

    init(renderer: any PagedTerminalRenderer, finishGrid: @escaping () -> Void,
         send: @escaping @MainActor (PagedTerminalRequest) async throws -> Void) {
        coordinator = PagedTerminalCoordinator(renderer: renderer, send: send)
        self.finishGrid = finishGrid
    }

    func handle(_ event: PagedTerminalEvent) async throws {
        if case .checkpoint = event { restoringGrid = true }
        try await coordinator.handle(event)
        // A later live resize borrows the authoritative grid only while its
        // resize is applied. It must not leave the pane in restore mode.
        if case .grid = event, !restoringGrid { finishGrid() }
        if poll == nil, coordinator.status == .available {
            poll = Task { [weak self] in
                while !Task.isCancelled {
                    // Let the current screen present before doing history work.
                    do { try await Task.sleep(for: .milliseconds(16)) } catch { return }
                    guard let self else { return }
                    await self.coordinator.loadIfNeeded(prefetch: true)
                    self.finishGridIfNeeded()
                }
            }
        }
        finishGridIfNeeded()
    }

    private func finishGridIfNeeded() {
        switch coordinator.status {
        case .complete, .limit, .requiresRecovery, .unavailable:
            poll?.cancel()
            poll = nil
            if restoringGrid { restoringGrid = false; finishGrid() }
        default: break
        }
    }

    func close() {
        poll?.cancel()
        poll = nil
        coordinator.disconnect()
    }

    deinit { poll?.cancel() }
}
