import Foundation
import os
import GrafttyProtocol
import Testing
@testable import GrafttyRemoteClient

@Suite("PaneControlClient — channel-driver-backed RPC façade.")
struct PaneControlClientTests {

    @Test func splitForwardsAndReturnsOk() async throws {
        let fake = FakeDriver(response: .ok)
        let client = PaneControlClient(driver: fake)
        try await client.open()
        let response = try await client.split(target: "s1", direction: .right)
        #expect(response == .ok)
        #expect(fake.lastRequest == .split(target: "s1", direction: .right))
    }

    @Test func splitLeftForwardsSemanticDirection() async throws {
        let fake = FakeDriver(response: .ok)
        let client = PaneControlClient(driver: fake)
        try await client.open()
        let response = try await client.split(target: "s-left", direction: .left)
        #expect(response == .ok)
        #expect(fake.lastRequest == .split(target: "s-left", direction: .left))
    }

    @Test func closeForwardsAndReturnsOk() async throws {
        let fake = FakeDriver(response: .ok)
        let client = PaneControlClient(driver: fake)
        try await client.open()
        let response = try await client.close(target: "s2")
        #expect(response == .ok)
        #expect(fake.lastRequest == .close(target: "s2"))
    }

    @Test func swapForwardsAndReturnsOk() async throws {
        let fake = FakeDriver(response: .ok)
        let client = PaneControlClient(driver: fake)
        try await client.open()
        let response = try await client.swap(source: "a", target: "b")
        #expect(response == .ok)
        #expect(fake.lastRequest == .swap(source: "a", target: "b"))
    }

    @Test func equalizeForwardsAndReturnsOk() async throws {
        let fake = FakeDriver(response: .ok)
        let client = PaneControlClient(driver: fake)
        try await client.open()
        let response = try await client.equalize(target: "s1")
        #expect(response == .ok)
        #expect(fake.lastRequest == .equalize(target: "s1"))
    }

    @Test func resizeForwardsAndReturnsOk() async throws {
        let fake = FakeDriver(response: .ok)
        let client = PaneControlClient(driver: fake)
        try await client.open()
        let response = try await client.resize(
            target: "s1",
            direction: .down,
            amount: 18,
            viewportExtent: 900
        )
        #expect(response == .ok)
        #expect(fake.lastRequest == .resize(
            target: "s1",
            direction: .down,
            amount: 18,
            viewportExtent: 900
        ))
    }

    @Test func errorResponsePassesThrough() async throws {
        let fake = FakeDriver(response: .error(code: "conflict", message: "busy"))
        let client = PaneControlClient(driver: fake)
        try await client.open()
        let response = try await client.split(target: "s3", direction: .right)
        guard case let .error(code, _) = response else {
            Issue.record("expected error response, got \(response)")
            return
        }
        #expect(code == "conflict")
    }

    @Test func clientCloseInvokesDriver() async throws {
        let fake = FakeDriver(response: .ok)
        let client = PaneControlClient(driver: fake)
        try await client.open()
        await client.close()
        #expect(fake.didClose)
    }

    @Test("a closed client rejects calls that enter after queue teardown")
    func closedClientRejectsLateCalls() async throws {
        let fake = FakeDriver(response: .ok)
        let client = PaneControlClient(driver: fake)
        try await client.open()
        await client.close()

        await #expect(throws: PaneControlClient.ClientError.notOpen) {
            try await client.equalize(target: "late")
        }
        #expect(fake.lastRequest == nil)
    }

    @Test("closing the client cancels every call queued behind an in-flight request")
    func serializesRapidCallsAndCancelsWholeQueueOnClose() async throws {
        let driver = SuspendingDriver()
        let client = PaneControlClient(driver: driver)
        try await client.open()

        let first = Task {
            try await client.split(target: "a", direction: .right)
        }
        await driver.waitUntilFirstRequestStarted()
        let second = Task {
            try await client.resize(
                target: "a",
                direction: .down,
                amount: 4
            )
        }
        let third = Task {
            try await client.equalize(target: "a")
        }
        await Task.yield()
        #expect(await driver.requests() == [
            .split(target: "a", direction: .right),
        ])

        await client.close()
        await driver.releaseFirstRequest()
        let firstFailed: Bool
        do {
            _ = try await first.value
            firstFailed = false
        } catch {
            firstFailed = true
        }
        _ = try? await second.value
        _ = try? await third.value

        #expect(firstFailed)
        #expect(await driver.requests() == [
            .split(target: "a", direction: .right),
        ])
    }
}

private final class FakeDriver: PaneControlChannelDriver, @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock(
        initialState: (opened: false, didClose: false, lastRequest: Optional<PaneControlRequest>.none)
    )
    private let response: PaneControlResponse

    init(response: PaneControlResponse) { self.response = response }

    var opened: Bool { lock.withLock { $0.opened } }
    var didClose: Bool { lock.withLock { $0.didClose } }
    var lastRequest: PaneControlRequest? { lock.withLock { $0.lastRequest } }

    func open() async throws {
        lock.withLock { $0.opened = true }
    }

    func close() {
        lock.withLock { $0.didClose = true }
    }

    func send(_ request: PaneControlRequest) async throws -> PaneControlResponse {
        lock.withLock { $0.lastRequest = request }
        return response
    }
}

private actor SuspendingDriver: PaneControlChannelDriver {
    private var recordedRequests: [PaneControlRequest] = []
    private var firstStarted = false
    private var firstReleased = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func open() async throws {}
    nonisolated func close() {}

    func send(
        _ request: PaneControlRequest
    ) async throws -> PaneControlResponse {
        recordedRequests.append(request)
        if recordedRequests.count == 1 {
            firstStarted = true
            startWaiters.forEach { $0.resume() }
            startWaiters.removeAll()
            if !firstReleased {
                await withCheckedContinuation {
                    releaseWaiters.append($0)
                }
            }
        }
        return .ok
    }

    func waitUntilFirstRequestStarted() async {
        guard !firstStarted else { return }
        await withCheckedContinuation {
            startWaiters.append($0)
        }
    }

    func releaseFirstRequest() {
        firstReleased = true
        releaseWaiters.forEach { $0.resume() }
        releaseWaiters.removeAll()
    }

    func requests() -> [PaneControlRequest] {
        recordedRequests
    }
}
