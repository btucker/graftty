import Foundation
import GrafttyProtocol
import Observation

public enum PagedTerminalPageResult: Equatable, Sendable {
    case applied, requiresRecovery, limit, stale, failed
}

@MainActor
public protocol PagedTerminalRenderer: AnyObject {
    func install(_ checkpoint: PagedTerminalCheckpoint, generation: UInt64) async throws
    func resize(cols: UInt16, rows: UInt16) async throws
    func appendHistory(_ data: Data, screen: UInt16, generation: UInt64) async -> PagedTerminalPageResult
    func isNearHistoryTop(screen: UInt16, generation: UInt64) -> Bool
}

public extension PagedTerminalRenderer {
    func resize(cols: UInt16, rows: UInt16) async throws { }
}

/// Shares paging order and lifecycle across native clients. The renderer owns
/// imported pages; this coordinator retains only the next request's identity.
@Observable
@MainActor
public final class PagedTerminalCoordinator {
    public enum Status: Equatable, Sendable {
        case inactive, installing, available, loading, complete, requiresRecovery, unavailable, limit
    }
    public private(set) var status: Status = .inactive
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

#if DEBUG
    /// Lets tests await timeout completion or cancellation without fixed sleeps.
    var timeoutTaskForTesting: Task<Void, Never>? { timeout }
#endif

    public init(renderer: any PagedTerminalRenderer, requestTimeout: Duration = .seconds(15),
                send: @escaping @MainActor (PagedTerminalRequest) async throws -> Void) {
        self.renderer = renderer
        self.requestTimeout = requestTimeout
        self.send = send
    }

    public func handle(_ event: PagedTerminalEvent) async throws {
        switch event {
        case .grid(let cols, let rows):
            try await renderer.resize(cols: cols, rows: rows)
        case .checkpoint(let value):
            guard value.codec == PagedTerminalLimits.codec,
                  !value.ready.isEmpty, value.ready.count <= PagedTerminalLimits.readyBytes else {
                throw PagedTerminalEnvelope.Error.invalid
            }
            if checkpoint?.incarnation == value.incarnation, checkpoint?.id == value.id { return }
            cancelPending()
            retryRequest = nil
            generation &+= 1
            let installingGeneration = generation
            status = .installing
            try await renderer.install(value, generation: installingGeneration)
            guard generation == installingGeneration else { return }
            // Do not retain the READY bytes after the renderer has imported them.
            checkpoint = .init(incarnation: value.incarnation, id: value.id, codec: value.codec,
                               cols: value.cols, rows: value.rows, ready: Data(),
                               hasPrimaryHistory: value.hasPrimaryHistory,
                               hasAlternateHistory: value.hasAlternateHistory)
            nextOrdinal = [0, 0]
            remaining = [value.hasPrimaryHistory, value.hasAlternateHistory]
            status = remaining.contains(true) ? .available : .complete

        case .page(let page):
            guard pending == page.request, page.data.count <= PagedTerminalLimits.pageBytes else { return }
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
            guard generation == applyingGeneration, pending == page.request else { return }
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
            guard pending == failure.request else { return }
            cancelPending()
            switch failure.reason {
            case .expired, .incompatible: status = .requiresRecovery
            case .limit: status = .limit
            case .unavailable:
                retryRequest = failure.request
                status = .unavailable
            }

        case .output, .ended:
            break
        }
    }

    /// Called from scroll demand or a modest viewport poll. There is at most
    /// one outstanding page, and live output never waits for this operation.
    public func loadIfNeeded() async {
        guard status == .available, pending == nil, let checkpoint else { return }
        guard let screen = (0..<2).first(where: {
            remaining[$0] && renderer.isNearHistoryTop(screen: UInt16($0), generation: generation)
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

    /// A replacement changes the reading position, so the UI calls this only
    /// after an explicit recovery action. Loaded content remains until READY.
    public func recover() async {
        guard checkpoint != nil, status != .installing else { return }
        cancelPending()
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

    public func disconnect() {
        generation &+= 1
        cancelPending()
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
}
