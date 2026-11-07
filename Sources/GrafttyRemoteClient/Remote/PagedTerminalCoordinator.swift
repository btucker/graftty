import Foundation
import GrafttyProtocol
import Observation

public enum PagedTerminalPageResult: Equatable, Sendable {
    case applied, requiresRecovery, limit, stale, failed
}

@MainActor
public protocol PagedTerminalRenderer: AnyObject {
    func install(_ checkpoint: PagedTerminalCheckpoint, generation: UInt64) async throws
    func flushOutput() async throws
    func resize(cols: UInt16, rows: UInt16) async throws
    func setSourceGrid(cols: UInt16, rows: UInt16) async throws
    func releaseSourceGrid() async throws
    func appendHistory(_ data: Data, screen: UInt16, generation: UInt64) async -> PagedTerminalPageResult
    func isNearHistoryTop(screen: UInt16, generation: UInt64) -> Bool
}

public extension PagedTerminalRenderer {
    func flushOutput() async throws { }
    func resize(cols: UInt16, rows: UInt16) async throws { }
    func setSourceGrid(cols: UInt16, rows: UInt16) async throws { try await resize(cols: cols, rows: rows) }
    func releaseSourceGrid() async throws { }
}

/// Shares paging order and lifecycle across native clients. The renderer owns
/// imported pages; this coordinator retains only the next request's identity.
@Observable
@MainActor
public final class PagedTerminalCoordinator {
    private var hasViewportHistoryDemand = false
    public enum RestoreError: Error, Equatable, Sendable { case timedOut }
    /// @spec TERM-12.55
    /// When a checkpoint installation completes or fails in the current attachment, the application shall retain only its latest elapsed installation duration and outcome for diagnosis without retaining snapshot contents.
    public struct RestoreDiagnostic: Codable, Equatable, Sendable {
        public enum Outcome: String, Codable, Sendable { case installed, failed, timedOut, cancelled }
        public let elapsedNanoseconds: UInt64
        public let outcome: Outcome
        public var elapsedMilliseconds: Double { Double(elapsedNanoseconds) / 1_000_000 }
    }
    @ObservationIgnored public private(set) var lastRestoreDiagnostic: RestoreDiagnostic?
    private let diagnosticNow: @MainActor () -> UInt64
    public enum Status: Equatable, Sendable {
        case inactive, installing, available, loading, complete, requiresRecovery, unavailable, limit, pageTooLarge
    }
    public private(set) var status: Status = .inactive {
        didSet { if oldValue != status { onStatusChange?(status) } }
    }
    /// Includes changes caused by a timeout when no further frame arrives.
    @ObservationIgnored public var onStatusChange: (@MainActor (Status) -> Void)?
    private let renderer: any PagedTerminalRenderer
    private let send: @MainActor (PagedTerminalRequest) async throws -> Void
    private let requestTimeout: Duration
    private var checkpoint: PagedTerminalCheckpoint?
    private var generation: UInt64 = 0
    private var nextRequestID: UInt64 = 0
    private var nextOrdinal: [UInt64] = [0, 0]
    private var remaining = [false, false]
    private var pending: PagedTerminalHistoryRequest?
    private var retryRequest: PagedTerminalHistoryRequest?
    private var timeout: Task<Void, Never>?
    private struct RendererOperation {
        let id: UUID
        let deadline: Task<Void, Never>
        let cancel: () -> Void
    }
    // Renderer waits and network page requests can overlap. Keep their
    // deadlines separate so a grid update cannot disable a page timeout.
    private var rendererOperation: RendererOperation?

#if DEBUG
    /// Read-only evidence for gesture-driven request/import correlation.
    public var historyDiagnosticsForTesting: (generation: UInt64, requests: UInt64, imports: UInt64) {
        (generation, nextRequestID, nextOrdinal.reduce(0, &+))
    }

    /// Lets tests await timeout completion or cancellation without fixed sleeps.
    var timeoutTaskForTesting: Task<Void, Never>? { rendererOperation?.deadline ?? timeout }
#endif

    public init(renderer: any PagedTerminalRenderer, requestTimeout: Duration = .seconds(15),
                diagnosticNow: @escaping @MainActor () -> UInt64 = { DispatchTime.now().uptimeNanoseconds },
                send: @escaping @MainActor (PagedTerminalRequest) async throws -> Void) {
        self.renderer = renderer
        self.requestTimeout = requestTimeout
        self.diagnosticNow = diagnosticNow
        self.send = send
    }

    /// Returns a grid only when this event committed source dimensions.
    /// Duplicate checkpoints and stale work do not publish another grid.
    @discardableResult
    public func handle(_ event: PagedTerminalEvent) async throws -> DisplayGrid? {
        switch event {
        case .grid(let cols, let rows):
            let resizingGeneration = generation
            try await performRendererOperation { [renderer] in
                try await renderer.setSourceGrid(cols: cols, rows: rows)
            }
            guard resizingGeneration == generation else { return nil }
            return try DisplayGrid(cols: cols, rows: rows)
        case .checkpoint(let value):
            guard value.codec == PagedTerminalLimits.codec,
                  !value.ready.isEmpty, value.ready.count <= PagedTerminalLimits.readyBytes else {
                throw PagedTerminalEnvelope.Error.invalid
            }
            if checkpoint?.incarnation == value.incarnation, checkpoint?.id == value.id { return nil }
            hasViewportHistoryDemand = false
            cancelPending()
            retryRequest = nil
            generation &+= 1
            let installingGeneration = generation
            status = .installing
            let started = diagnosticNow()
            do {
                try await performRendererOperation { [renderer] in
                    try await renderer.install(value, generation: installingGeneration)
                }
            } catch {
                // TERM-12.51: an unmounted or cancelled restore must not leave
                // the banner spinning; offer recovery from the live screen.
                if generation == installingGeneration {
                    status = .requiresRecovery
                    let outcome: RestoreDiagnostic.Outcome = error is CancellationError ? .cancelled
                        : error as? RestoreError == .timedOut ? .timedOut : .failed
                    lastRestoreDiagnostic = RestoreDiagnostic(elapsedNanoseconds: diagnosticNow() &- started, outcome: outcome)
                }
                throw error
            }
            guard generation == installingGeneration else { return nil }
            lastRestoreDiagnostic = RestoreDiagnostic(elapsedNanoseconds: diagnosticNow() &- started, outcome: .installed)
            // Do not retain the READY bytes after the renderer has imported them.
            checkpoint = .init(incarnation: value.incarnation, id: value.id, codec: value.codec,
                               cols: value.cols, rows: value.rows, ready: Data(),
                               hasPrimaryHistory: value.hasPrimaryHistory,
                               hasAlternateHistory: value.hasAlternateHistory)
            nextOrdinal = [0, 0]
            remaining = [value.hasPrimaryHistory, value.hasAlternateHistory]
            status = remaining.contains(true) ? .available : .complete
            return try DisplayGrid(cols: value.cols, rows: value.rows)

        case .page(let page):
            guard pending == page.request, page.data.count <= PagedTerminalLimits.pageBytes else { return nil }
            // The network request has completed. Import can wait behind live
            // output; timing it out now would lose the committed page ordinal.
            timeout?.cancel()
            timeout = nil
            let applyingGeneration = generation
            let result: PagedTerminalPageResult
            if page.data.isEmpty {
                result = page.complete ? .applied : .failed
            } else {
                result = await renderer.appendHistory(page.data, screen: page.screen, generation: generation)
            }
            guard generation == applyingGeneration, pending == page.request else { return nil }
            cancelPending()
            switch result {
            case .applied:
                nextOrdinal[Int(page.screen)] &+= 1
                remaining[Int(page.screen)] = !page.complete
                status = remaining.contains(true) ? .available : .complete
            case .requiresRecovery, .stale:
                status = .requiresRecovery
            case .limit:
                status = .limit
            case .failed:
                retryRequest = page.request
                status = .unavailable
            }

        case .unavailable(let failure):
            guard pending == failure.request else { return nil }
            cancelPending()
            switch failure.reason {
            case .expired, .incompatible: status = .requiresRecovery
            // The host's limit is an encoded PAGE budget. Native retention
            // refusals arrive separately from renderer.appendHistory above.
            case .limit: status = .pageTooLarge
            case .unavailable:
                retryRequest = failure.request
                status = .unavailable
            }

        case .output, .ended:
            break
        }
        await continueViewportHistory()
        return nil
    }

    /// Only a user scroll starts history loading. Native viewport updates and
    /// completed pages can then continue it while the viewport remains near top.
    public func viewportDidChange(requestHistory: Bool = true) async {
        if requestHistory { hasViewportHistoryDemand = true }
        await continueViewportHistory()
    }

    private func continueViewportHistory() async {
        guard hasViewportHistoryDemand else { return }
        await loadIfNeeded()
    }

    /// Called from scroll demand or a modest viewport poll. There is at most
    /// one outstanding page, and live output never waits for this operation.
    public func loadIfNeeded(prefetch: Bool = false) async {
        guard status == .available, pending == nil, let checkpoint else { return }
        guard let screen = (0..<2).first(where: {
            remaining[$0] && (prefetch || renderer.isNearHistoryTop(screen: UInt16($0), generation: generation))
        }) else { return }
        let request: PagedTerminalHistoryRequest
        if let retryRequest, retryRequest.screen == UInt16(screen) {
            request = retryRequest
        } else {
            nextRequestID &+= 1
            request = PagedTerminalHistoryRequest(
                incarnation: checkpoint.incarnation, checkpointID: checkpoint.id,
                requestID: nextRequestID, ordinal: nextOrdinal[screen], screen: UInt16(screen)
            )
        }
        retryRequest = nil
        pending = request
        status = .loading
        timeout = Task { [weak self] in
            do { try await Task.sleep(for: self?.requestTimeout ?? .seconds(15)) } catch { return }
            guard let self, self.pending == request else { return }
            self.retryRequest = request
            self.cancelPending()
            self.status = .unavailable
        }
        do { try await send(.history(request)) }
        catch {
            guard pending == request else { return }
            retryRequest = request
            cancelPending()
            status = .unavailable
        }
    }

    public func retry() async {
        guard status == .unavailable else { return }
        status = .available
        await loadIfNeeded()
    }

    /// A replacement changes the reading position. Call only after explicit
    /// recovery or an initial layout resize before history interaction. Loaded content remains until READY.
    public func recover() async {
        guard status != .installing, checkpoint != nil || status == .requiresRecovery else { return }
        cancelPending()
        // Fence a prior send that can finish after its timeout and a retry.
        generation &+= 1
        // Explicit recovery must accept READY even when the host returns the
        // same identity. The renderer retains loaded content until it arrives.
        checkpoint = nil
        status = .installing
        let recoveringGeneration = generation
        timeout = Task { [weak self] in
            do { try await Task.sleep(for: self?.requestTimeout ?? .seconds(15)) } catch { return }
            guard let self, self.generation == recoveringGeneration, self.status == .installing else { return }
            self.status = .requiresRecovery
        }
        do { try await send(.checkpoint) }
        catch {
            guard generation == recoveringGeneration else { return }
            status = .requiresRecovery
        }
    }

    /// Keep the live terminal visible while offering a fresh history snapshot.
    public func invalidateHistory() {
        cancelPending()
        hasViewportHistoryDemand = false
        status = .requiresRecovery
    }

    public func disconnect() {
        hasViewportHistoryDemand = false
        generation &+= 1
        cancelPending()
        rendererOperation?.cancel()
        rendererOperation?.deadline.cancel()
        rendererOperation = nil
        checkpoint = nil
        retryRequest = nil
        remaining = [false, false]
        status = .inactive
    }

    private func cancelPending() {
        timeout?.cancel()
        timeout = nil
        pending = nil
    }

    /// Native output queues may park in a continuation that ignores Swift
    /// cancellation. Bound the caller's wait without joining that parked task;
    /// a failure reaches the attachment's existing close/reconnect path.
    private func performRendererOperation(_ operation: @escaping @MainActor () async throws -> Void) async throws {
        rendererOperation?.cancel()
        rendererOperation?.deadline.cancel()
        let id = UUID()
        let result = AsyncStream<Result<Void, any Error>>.makeStream(bufferingPolicy: .bufferingOldest(1))
        let work = Task {
            do {
                try Task.checkCancellation()
                try await operation()
                result.continuation.yield(.success(()))
            } catch {
                result.continuation.yield(.failure(error))
            }
            result.continuation.finish()
        }
        let deadline = Task { [requestTimeout] in
            do { try await Task.sleep(for: requestTimeout) } catch { return }
            result.continuation.yield(.failure(RestoreError.timedOut))
            result.continuation.finish()
        }
        rendererOperation = RendererOperation(id: id, deadline: deadline, cancel: {
            work.cancel()
            result.continuation.finish()
        })
        defer {
            work.cancel()
            deadline.cancel()
            result.continuation.finish()
            if rendererOperation?.id == id { rendererOperation = nil }
        }
        for await completion in result.stream {
            try Task.checkCancellation()
            try completion.get()
            return
        }
        throw CancellationError()
    }
}
