import Foundation
import GrafttyProtocol
import Testing
@testable import GrafttyRemoteClient

@MainActor
struct PagedTerminalCoordinatorTests {
    @Test("Retry accepts a delayed response to the original timed-out page request")
    func retryPreservesRequestIdentity() async throws {
        let surface = Surface()
        surface.nearTop = true
        var requests: [PagedTerminalRequest] = []
        let coordinator = PagedTerminalCoordinator(renderer: surface, requestTimeout: .milliseconds(30)) {
            requests.append($0)
        }
        try await coordinator.handle(.checkpoint(checkpoint(1)))
        await coordinator.loadIfNeeded()
        guard case .history(let original) = try #require(requests.first) else { return }
        try await Task.sleep(for: .milliseconds(80))
        #expect(coordinator.status == .unavailable)
        await coordinator.retry()
        #expect(requests.last == .history(original))
        try await coordinator.handle(.page(page(original)))
        #expect(surface.pages == [0])
        #expect(coordinator.status == .available)
        coordinator.disconnect()
    }
    @Test("A received page cannot time out while the renderer is importing it")
    func importOutlivesNetworkTimeout() async throws {
        let surface = Surface()
        surface.nearTop = true
        surface.holdImport = true
        var requests: [PagedTerminalRequest] = []
        let coordinator = PagedTerminalCoordinator(renderer: surface, requestTimeout: .milliseconds(30)) {
            requests.append($0)
        }
        try await coordinator.handle(.checkpoint(checkpoint(1)))
        await coordinator.loadIfNeeded()
        guard case .history(let request) = try #require(requests.first) else { return }
        let importTask = Task { try await coordinator.handle(.page(page(request))) }
        while surface.importContinuation == nil { await Task.yield() }
        try await Task.sleep(for: .milliseconds(80))
        #expect(coordinator.status == .loading)
        surface.holdImport = false
        surface.importContinuation?.resume()
        try await importTask.value
        await coordinator.loadIfNeeded()
        guard case .history(let next) = try #require(requests.last) else { return }
        #expect(next.ordinal == 1)
        #expect(surface.pages.count == 1)
        coordinator.disconnect()
    }
    @Test("A checkpoint makes the screen usable without requesting any older page")
    func screenBeforeHistory() async throws {
        let surface = Surface()
        var requests: [PagedTerminalRequest] = []
        let coordinator = PagedTerminalCoordinator(renderer: surface) { requests.append($0) }
        try await coordinator.handle(.checkpoint(checkpoint(1)))
        #expect(surface.installed == [1])
        #expect(requests.isEmpty)
        #expect(coordinator.status == .available)
        surface.nearTop = true
        await coordinator.loadIfNeeded()
        #expect(requests.count == 1)
        await coordinator.loadIfNeeded()
        #expect(requests.count == 1)
    }

    @Test("@spec TERM-12.4: When a history page arrives, the application shall validate its session incarnation, checkpoint, screen, and page position before importing it, reject stale or duplicate pages, and preserve a contiguous history range without mixing content across checkpoints.")
    func rejectsStaleAndDuplicatePages() async throws {
        let surface = Surface()
        surface.nearTop = true
        var requests: [PagedTerminalRequest] = []
        let coordinator = PagedTerminalCoordinator(renderer: surface) { requests.append($0) }
        try await coordinator.handle(.checkpoint(checkpoint(1)))
        await coordinator.loadIfNeeded()
        guard case .history(let first) = try #require(requests.first) else {
            Issue.record("expected history request"); return
        }
        try await coordinator.handle(.checkpoint(checkpoint(2)))
        try await coordinator.handle(.page(page(first)))
        #expect(surface.pages.isEmpty)
        await coordinator.loadIfNeeded()
        guard case .history(let current) = try #require(requests.last) else { return }
        try await coordinator.handle(.page(page(current)))
        try await coordinator.handle(.page(page(current)))
        #expect(surface.pages == [0])
        await coordinator.loadIfNeeded()
        guard case .history(let next) = try #require(requests.last) else { return }
        #expect(next.ordinal == 1)
    }

    @Test("A width change keeps loaded content and requests a replacement only after explicit recovery")
    func resizeRequiresExplicitRecovery() async throws {
        let surface = Surface()
        surface.nearTop = true
        surface.result = .requiresRecovery
        var requests: [PagedTerminalRequest] = []
        let coordinator = PagedTerminalCoordinator(renderer: surface) { requests.append($0) }
        try await coordinator.handle(.checkpoint(checkpoint(1)))
        await coordinator.loadIfNeeded()
        guard case .history(let request) = try #require(requests.last) else { return }
        try await coordinator.handle(.page(page(request)))
        #expect(coordinator.status == .requiresRecovery)
        #expect(surface.installed == [1])
        await coordinator.loadIfNeeded()
        #expect(requests.count == 1)
        await coordinator.recover()
        #expect(requests.last == .checkpoint)
        #expect(surface.installed == [1])
    }

    @Test("Page failure and disconnect leave existing content intact")
    func failureAndDisconnect() async throws {
        let surface = Surface()
        surface.nearTop = true
        var requests: [PagedTerminalRequest] = []
        let coordinator = PagedTerminalCoordinator(renderer: surface) { requests.append($0) }
        try await coordinator.handle(.checkpoint(checkpoint(1)))
        await coordinator.loadIfNeeded()
        guard case .history(let request) = try #require(requests.last) else { return }
        try await coordinator.handle(.unavailable(.init(request: request, reason: .expired)))
        #expect(coordinator.status == .requiresRecovery)
        coordinator.disconnect()
        try await coordinator.handle(.page(page(request)))
        #expect(surface.pages.isEmpty)
        #expect(surface.installed == [1])
    }

    private func checkpoint(_ id: UInt64) -> PagedTerminalCheckpoint {
        .init(incarnation: 7, id: id, cols: 80, rows: 24, ready: Data([1]),
              hasPrimaryHistory: true, hasAlternateHistory: false)
    }
    private func page(_ request: PagedTerminalHistoryRequest) -> PagedTerminalPage {
        .init(incarnation: request.incarnation, checkpointID: request.checkpointID,
              requestID: request.requestID, ordinal: request.ordinal, screen: request.screen,
              data: Data([2]), complete: false)
    }
    private final class Surface: PagedTerminalRenderer {
        var holdImport = false
        var importContinuation: CheckedContinuation<Void, Never>?
        var installed: [UInt64] = []
        var pages: [UInt16] = []
        var nearTop = false
        var result: PagedTerminalPageResult = .applied
        func install(_ checkpoint: PagedTerminalCheckpoint, generation: UInt64) async throws {
            installed.append(checkpoint.id)
        }
        func appendHistory(_ data: Data, screen: UInt16, generation: UInt64) async -> PagedTerminalPageResult {
            if holdImport { await withCheckedContinuation { importContinuation = $0 } }
            if result == .applied { pages.append(screen) }
            return result
        }
        func isNearHistoryTop(screen: UInt16, generation: UInt64) -> Bool { nearTop && screen == 0 }
    }
}
