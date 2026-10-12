import Foundation
import GrafttyProtocol
import Testing
@testable import GrafttyRemoteClient

private final class HeldChromeDriver: ChromeTabChannelDriver, @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [ChromeTabRequest] = []
    private var held: CheckedContinuation<ChromeTabResponse, Error>?
    func open() async throws {}
    func close() { release(error: CancellationError()) }
    func send(_ request: ChromeTabRequest) async throws -> ChromeTabResponse {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock(); requests.append(request)
            if requests.count == 1 { held = continuation; lock.unlock() }
            else { lock.unlock(); continuation.resume(returning: .init(state: .init())) }
        }
    }
    func snapshot() -> [ChromeTabRequest] { lock.lock(); defer { lock.unlock() }; return requests }
    func release(error: Error? = nil) {
        lock.lock(); let continuation = held; held = nil; lock.unlock()
        if let error { continuation?.resume(throwing: error) }
        else { continuation?.resume(returning: .init(state: .init())) }
    }
}

struct ChromeTabClientTests {
    @Test("@spec CHROME-2.2: When a phone tap and text arrive during a frame request, the application shall queue bounded input and dispatch the tap before text on the same tab.")
    func queuesInputBehindFrame() async throws {
        let driver = HeldChromeDriver()
        let client = ChromeTabClient(driver: driver)
        try await client.open()
        let frame = Task { try await client.send(.init(target: "pane", action: .frame(tabID: "a"))) }
        while driver.snapshot().isEmpty { await Task.yield() }
        let tap = Task { try await client.send(.init(target: "pane", action: .tap(tabID: "a", x: 0.5, y: 0.5))) }
        while await client.pendingRequestCount < 2 { await Task.yield() }
        let text = Task { try await client.send(.init(target: "pane", action: .text(tabID: "a", text: "phone"))) }
        while await client.pendingRequestCount < 3 { await Task.yield() }
        #expect(driver.snapshot().count == 1)
        driver.release()
        _ = try await frame.value; _ = try await tap.value; _ = try await text.value
        #expect(driver.snapshot().map(\.action) == [.frame(tabID: "a"), .tap(tabID: "a", x: 0.5, y: 0.5), .text(tabID: "a", text: "phone")])
        await client.close()
    }

    @Test("@spec CHROME-2.3: When a Chrome viewer closes, the application shall cancel queued input before it can reach a replacement connection.")
    func cancelsQueuedInput() async throws {
        let driver = HeldChromeDriver()
        let client = ChromeTabClient(driver: driver)
        try await client.open()
        let frame = Task { try await client.send(.init(target: "pane", action: .frame(tabID: "a"))) }
        while driver.snapshot().isEmpty { await Task.yield() }
        let tap = Task { try await client.send(.init(target: "pane", action: .tap(tabID: "a", x: 0.5, y: 0.5))) }
        while await client.pendingRequestCount < 2 { await Task.yield() }
        await client.close()
        await #expect(throws: (any Error).self) { try await frame.value }
        await #expect(throws: (any Error).self) { try await tap.value }
        #expect(driver.snapshot().count == 1)
    }
}
