import Foundation
import GhosttyKit
import os
import GrafttyProtocol
import GrafttyRemoteClient

/// Borrows the SurfaceHandle's surface. Parsing runs off main; retirement
/// joins only admitted C calls while main drains the mailbox.
final class MacPagedSurface: @unchecked Sendable {
    typealias WriteBuffer = (ghostty_surface_t, Data) -> Void
    typealias MainScheduler = @Sendable (@escaping @Sendable () -> Void) -> Void
    private let calls = NSRecursiveLock()
    private let condition = NSCondition()
    private let queue = DispatchQueue(label: "com.graftty.paged-output", qos: .userInitiated)
    private var surface: ghostty_surface_t?
    private var retiringSurface: ghostty_surface_t?
    private var activeCalls = 0
    private let writeBuffer: WriteBuffer
    private let scheduleOnMain: MainScheduler

    init(_ surface: ghostty_surface_t, writeBuffer: @escaping WriteBuffer = { surface, data in
        data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            ghostty_surface_write_buffer(surface, base.assumingMemoryBound(to: UInt8.self), UInt(bytes.count))
        }
    }, scheduleOnMain: @escaping MainScheduler = { DispatchQueue.main.async(execute: $0) }) {
        self.surface = surface
        self.writeBuffer = writeBuffer
        self.scheduleOnMain = scheduleOnMain
    }

    private func withSurface<T>(_ body: (ghostty_surface_t) -> T) -> T? {
        calls.lock()
        defer { calls.unlock() }
        condition.lock()
        guard let surface else { condition.unlock(); return nil }
        activeCalls += 1
        condition.unlock()
        defer {
            condition.lock()
            activeCalls -= 1
            condition.broadcast()
            condition.unlock()
        }
        return body(surface)
    }

    var isOpen: Bool { condition.withLock { surface != nil } }

    /// Polls never wait on the writer's Swift lock or native renderer mutex.
    /// A later viewport poll retries when the current operation has finished.
    func withIdleSurface<T>(_ body: (ghostty_surface_t) -> T) -> T? {
        guard calls.try() else { return nil }
        defer { calls.unlock() }
        return withSurface(body)
    }

    private final class Cancellation: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false
        func cancel() { lock.withLock { cancelled = true } }
        var isCancelled: Bool { lock.withLock { cancelled } }
    }

    func perform<T: Sendable>(onMainThread: Bool = false,
                             _ body: @escaping @Sendable (ghostty_surface_t) -> T) async -> T? {
        let cancellation = Cancellation()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                queue.async { [self] in
                    let run = { @Sendable in
                        let result = cancellation.isCancelled ? nil : self.withSurface(body)
                        continuation.resume(returning: result)
                    }
                    if onMainThread {
                        // Grid and READY APIs also update the native view.
                        // Acquire the lease on main, so close never joins a
                        // worker that is waiting for a queued main block.
                        let finished = DispatchSemaphore(value: 0)
                        scheduleOnMain { run(); finished.signal() }
                        finished.wait()
                    } else { run() }
                }
            }
        } onCancel: {
            cancellation.cancel()
        }
    }

    /// Await each live frame before reading the next event. This bounds the
    /// writer to one frame and fences checkpoint, grid, page and exit events.
    func writeAndWait(_ data: Data) async throws {
        try Task.checkCancellation()
        guard await perform({ [writeBuffer] in writeBuffer($0, data) }) != nil else {
            throw CancellationError()
        }
        try Task.checkCancellation()
    }

    /// The legacy PTY reader already supplies ordering and backpressure.
    func write(_ data: Data) {
        precondition(!Thread.isMainThread)
        withSurface { writeBuffer($0, data) }
    }

    /// Stop admission before joining C calls. Queued work checks admission
    /// when it runs and never captures the borrowed pointer. No Swift lock
    /// spans a tick, and no tick runs inside a native parser callback.
    func close() {
        condition.lock()
        if let surface {
            retiringSurface = surface
            self.surface = nil
        }
        while activeCalls > 0 {
            if Thread.isMainThread, let retiringSurface {
                let app = ghostty_surface_app(retiringSurface)
                condition.unlock()
                ghostty_app_tick(app)
                condition.lock()
                if activeCalls > 0 {
                    _ = condition.wait(until: Date(timeIntervalSinceNow: 0.001))
                }
            } else { condition.wait() }
        }
        retiringSurface = nil
        condition.unlock()
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
        let installed = await surface.perform(onMainThread: true) { surface in
            checkpoint.ready.withUnsafeBytes { bytes in
                ghostty_surface_snapshot_ready(surface, generation,
                    bytes.baseAddress!.assumingMemoryBound(to: UInt8.self), bytes.count)
            }
        }
        try checkActive()
        guard installed == true else { throw Error.invalidSnapshot }
        #else
        throw Error.invalidSnapshot
        #endif
    }

    func resize(cols: UInt16, rows: UInt16) async throws {
        try await setSourceGrid(cols: cols, rows: rows)
        try checkActive()
        prepareGrid(try DisplayGrid(cols: cols, rows: rows))
        try Task.checkCancellation()
    }

    func setSourceGrid(cols: UInt16, rows: UInt16) async throws {
        #if GRAFTTY_PAGED_HISTORY
        try Task.checkCancellation()
        guard await surface.perform(onMainThread: true, { ghostty_surface_set_source_grid($0, cols, rows) }) == true else {
            throw Error.gridUnavailable
        }
        // Live acknowledgments update parser dimensions only. Preparing a restore
        // grid here briefly gives an owner the follower's fitted frame and shadow,
        // then removes them again when MacPagedAttachment finishes the grid event.
        try checkActive()
        #else
        throw Error.invalidSnapshot
        #endif
    }

    func releaseSourceGrid() async throws {
        #if GRAFTTY_PAGED_HISTORY
        guard await surface.perform(onMainThread: true, { ghostty_surface_clear_source_grid($0) }) == true else {
            throw Error.gridUnavailable
        }
        #endif
        try checkActive()
    }

    func appendHistory(_ data: Data, screen: UInt16, generation: UInt64) async -> PagedTerminalPageResult {
        #if GRAFTTY_PAGED_HISTORY
        let result = await surface.perform { surface in
            data.withUnsafeBytes { bytes in
                var rows = 0
                return ghostty_surface_snapshot_page(surface, generation, screen,
                    bytes.baseAddress!.assumingMemoryBound(to: UInt8.self), bytes.count, &rows)
            }
        }
        guard !Task.isCancelled, surface.isOpen else { return .stale }
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
        surface.withIdleSurface { ghostty_surface_snapshot_near_top($0, generation, screen, 20) } == true
        #else
        false
        #endif
    }

    private func checkActive() throws {
        try Task.checkCancellation()
        guard surface.isOpen else { throw CancellationError() }
    }

    enum Error: Swift.Error { case invalidSnapshot, gridUnavailable }
}

/// Both Mac transports use the same screen-first import and bounded backfill.
@MainActor
final class MacPagedAttachment {
    let coordinator: PagedTerminalCoordinator
    private var poll: Task<Void, Never>?
    private let finishGrid: () -> Void
    private let sourceGrid: (DisplayGrid?) -> Void
    private var restoringGrid = false
    private var closed = false

    init(renderer: any PagedTerminalRenderer, sourceGrid: @escaping (DisplayGrid?) -> Void = { _ in }, finishGrid: @escaping () -> Void,
         send: @escaping @MainActor (PagedTerminalRequest) async throws -> Void) {
        coordinator = PagedTerminalCoordinator(renderer: renderer, send: send)
        self.finishGrid = finishGrid
        self.sourceGrid = sourceGrid
    }

    private static let trace = Logger(subsystem: "com.graftty.app", category: "paged-trace")

    func handle(_ event: PagedTerminalEvent) async throws {
        try Task.checkCancellation()
        guard !closed else { throw CancellationError() }
        let appliedGrid = try await coordinator.handle(event)
        try Task.checkCancellation()
        guard !closed else { throw CancellationError() }
        if let appliedGrid {
            if case .checkpoint = event { restoringGrid = true }
            sourceGrid(appliedGrid)
        }
        if let summary = event.traceSummary {
            Self.trace.notice("mac \(summary, privacy: .public) restoring=\(self.restoringGrid) status=\(String(describing: self.coordinator.status), privacy: .public)")
        }
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
        guard !closed else { return }
        switch coordinator.status {
        case .complete, .limit, .pageTooLarge, .requiresRecovery, .unavailable:
            poll?.cancel()
            poll = nil
            if restoringGrid { restoringGrid = false; finishGrid() }
        default: break
        }
    }

    func close() {
        closed = true
        poll?.cancel()
        poll = nil
        coordinator.disconnect()
    }

    deinit { poll?.cancel() }
}
