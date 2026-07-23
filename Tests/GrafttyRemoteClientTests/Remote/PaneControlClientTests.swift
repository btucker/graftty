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
