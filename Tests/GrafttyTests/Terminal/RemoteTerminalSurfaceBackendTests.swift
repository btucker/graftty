import Foundation
import GhosttyKit
import GrafttyRemoteClient
import NIOConcurrencyHelpers
import Testing
@testable import Graftty

@Suite("RemoteTerminalSurfaceBackend — Ghostty host-managed adapter", .serialized)
struct RemoteTerminalSurfaceBackendTests {
    @Test func configureSetsHostManagedBackendAndReceiveCallbacks() {
        let client = FakeRemoteTerminalWebSocketClient()
        let backend = RemoteTerminalSurfaceBackend(client: client)
        defer { backend.surfaceWasFreed() }

        var config = ghostty_surface_config_new()
        backend.configure(&config)

        #expect(config.backend == GHOSTTY_SURFACE_IO_BACKEND_HOST_MANAGED)
        #expect(config.receive_userdata != nil)
        #expect(config.receive_buffer != nil)
        #expect(config.receive_resize != nil)
    }

    @Test func receiveBufferCallbackSendsBinaryFrameToWebSocketClient() async throws {
        let client = FakeRemoteTerminalWebSocketClient()
        let backend = RemoteTerminalSurfaceBackend(client: client)
        defer {
            backend.close()
            backend.surfaceWasFreed()
        }

        let bytes = Array("abc".utf8)
        bytes.withUnsafeBufferPointer { ptr in
            RemoteTerminalSurfaceBackend.receiveBufferCallback(
                backend.userdataForTesting,
                ptr.baseAddress,
                ptr.count
            )
        }

        try await client.waitForSentFrames(count: 1)
        #expect(client.sentFrames() == [.binary(Data("abc".utf8))])
    }

    @Test func receiveLoopWritesIncomingBinaryBytesAndRequestsRefresh() async throws {
        let client = FakeRemoteTerminalWebSocketClient()
        let recorder = RemoteSurfaceRecorder()
        let backend = RemoteTerminalSurfaceBackend(
            client: client,
            writeBuffer: recorder.writeBuffer,
            requestRefresh: recorder.requestRefresh
        )
        defer {
            backend.close()
            backend.surfaceWasFreed()
        }

        try backend.start(surface: fakeSurface())
        client.deliver(.binary(Data("remote".utf8)))

        try await recorder.waitForWrites(count: 1)
        #expect(recorder.writes() == [Data("remote".utf8)])
        #expect(recorder.refreshCount() == 1)
    }

    @Test func receiveResizeCallbackForwardsGridSizeToWebSocketClient() async throws {
        let client = FakeRemoteTerminalWebSocketClient()
        let backend = RemoteTerminalSurfaceBackend(client: client)
        defer {
            backend.close()
            backend.surfaceWasFreed()
        }

        RemoteTerminalSurfaceBackend.receiveResizeCallback(
            backend.userdataForTesting,
            132,
            43,
            2112,
            1032
        )

        try await client.waitForResizeCount(1)
        #expect(client.resizes() == [RemoteResize(cols: 132, rows: 43)])
    }

    @Test func closeCancelsReceiveLoopAndClosesWebSocketClient() throws {
        let client = FakeRemoteTerminalWebSocketClient()
        let backend = RemoteTerminalSurfaceBackend(client: client)
        defer { backend.surfaceWasFreed() }

        try backend.start(surface: fakeSurface())
        backend.close()
        backend.close()

        #expect(client.closeCount() == 1)
    }
}

private final class RemoteSurfaceRecorder: @unchecked Sendable {
    private let lock = NIOLock()
    private var recordedWrites: [Data] = []
    private var recordedRefreshCount = 0
    private var writeWaiters: [(Int, CheckedContinuation<Void, Error>)] = []

    var writeBuffer: @Sendable (Data) -> Void {
        { [weak self] data in
            self?.recordWrite(data)
        }
    }

    var requestRefresh: @Sendable () -> Void {
        { [weak self] in
            self?.recordRefresh()
        }
    }

    func waitForWrites(count: Int) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await withCheckedThrowingContinuation { continuation in
                    let isReady = self.lock.withLock { () -> Bool in
                        if self.recordedWrites.count >= count {
                            return true
                        }
                        self.writeWaiters.append((count, continuation))
                        return false
                    }
                    if isReady {
                        continuation.resume()
                    }
                }
            }
            group.addTask {
                try await Task.sleep(nanoseconds: 2_000_000_000)
                throw TestTimeout()
            }
            try await group.next()
            group.cancelAll()
        }
    }

    func writes() -> [Data] {
        lock.withLock { recordedWrites }
    }

    func refreshCount() -> Int {
        lock.withLock { recordedRefreshCount }
    }

    private func recordWrite(_ data: Data) {
        let ready: [CheckedContinuation<Void, Error>]
        ready = lock.withLock {
            recordedWrites.append(data)
            let matching = writeWaiters.partitioned { recordedWrites.count >= $0.0 }
            writeWaiters = matching.remaining
            return matching.matches.map(\.1)
        }
        for waiter in ready {
            waiter.resume()
        }
    }

    private func recordRefresh() {
        lock.withLock {
            recordedRefreshCount += 1
        }
    }
}

private struct RemoteResize: Equatable {
    let cols: Int
    let rows: Int
}

private final class FakeRemoteTerminalWebSocketClient: WebSocketClient, @unchecked Sendable {
    private let lock = NIOLock()
    private var recordedSentFrames: [WebSocketFrame] = []
    private var recordedResizes: [RemoteResize] = []
    private var recordedCloseCount = 0
    private var receivedFrames: [WebSocketFrame] = []
    private var receiveWaiters: [CheckedContinuation<WebSocketFrame, Error>] = []
    private var sentWaiters: [(Int, CheckedContinuation<Void, Error>)] = []
    private var resizeWaiters: [(Int, CheckedContinuation<Void, Error>)] = []

    func send(_ frame: WebSocketFrame) async throws {
        let ready: [CheckedContinuation<Void, Error>]
        ready = lock.withLock {
            recordedSentFrames.append(frame)
            let matching = sentWaiters.partitioned { recordedSentFrames.count >= $0.0 }
            sentWaiters = matching.remaining
            return matching.matches.map(\.1)
        }
        for waiter in ready {
            waiter.resume()
        }
    }

    func receive() async throws -> WebSocketFrame {
        try await withCheckedThrowingContinuation { continuation in
            let frame: WebSocketFrame? = lock.withLock {
                if !receivedFrames.isEmpty {
                    return receivedFrames.removeFirst()
                }
                receiveWaiters.append(continuation)
                return nil
            }
            if let frame {
                continuation.resume(returning: frame)
                return
            }
        }
    }

    func close() {
        let waiters: [CheckedContinuation<WebSocketFrame, Error>]
        waiters = lock.withLock {
            recordedCloseCount += 1
            let waiters = receiveWaiters
            receiveWaiters = []
            return waiters
        }
        for waiter in waiters {
            waiter.resume(throwing: CancellationError())
        }
    }

    func resize(cols: Int, rows: Int) async {
        let ready: [CheckedContinuation<Void, Error>]
        ready = lock.withLock {
            recordedResizes.append(RemoteResize(cols: cols, rows: rows))
            let matching = resizeWaiters.partitioned { recordedResizes.count >= $0.0 }
            resizeWaiters = matching.remaining
            return matching.matches.map(\.1)
        }
        for waiter in ready {
            waiter.resume()
        }
    }

    func deliver(_ frame: WebSocketFrame) {
        let waiter: CheckedContinuation<WebSocketFrame, Error>?
        waiter = lock.withLock {
            if receiveWaiters.isEmpty {
                receivedFrames.append(frame)
                return nil
            } else {
                return receiveWaiters.removeFirst()
            }
        }
        waiter?.resume(returning: frame)
    }

    func waitForSentFrames(count: Int) async throws {
        try await waitFor(count: count, keyPath: \.recordedSentFrames, waiters: \.sentWaiters)
    }

    func waitForResizeCount(_ count: Int) async throws {
        try await waitFor(count: count, keyPath: \.recordedResizes, waiters: \.resizeWaiters)
    }

    func sentFrames() -> [WebSocketFrame] {
        lock.withLock { recordedSentFrames }
    }

    func resizes() -> [RemoteResize] {
        lock.withLock { recordedResizes }
    }

    func closeCount() -> Int {
        lock.withLock { recordedCloseCount }
    }

    private func waitFor<Value>(
        count: Int,
        keyPath: ReferenceWritableKeyPath<FakeRemoteTerminalWebSocketClient, [Value]>,
        waiters: ReferenceWritableKeyPath<FakeRemoteTerminalWebSocketClient, [(Int, CheckedContinuation<Void, Error>)]>
    ) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await withCheckedThrowingContinuation { continuation in
                    let isReady = self.lock.withLock { () -> Bool in
                        if self[keyPath: keyPath].count >= count {
                            return true
                        } else {
                            self[keyPath: waiters].append((count, continuation))
                            return false
                        }
                    }
                    if isReady {
                        continuation.resume()
                    }
                }
            }
            group.addTask {
                try await Task.sleep(nanoseconds: 2_000_000_000)
                throw TestTimeout()
            }
            try await group.next()
            group.cancelAll()
        }
    }
}

private struct TestTimeout: Error {}

private extension Array {
    func partitioned(_ isMatch: (Element) -> Bool) -> (matches: [Element], remaining: [Element]) {
        var matches: [Element] = []
        var remaining: [Element] = []
        for element in self {
            if isMatch(element) {
                matches.append(element)
            } else {
                remaining.append(element)
            }
        }
        return (matches, remaining)
    }
}
