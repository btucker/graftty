import Foundation
import GhosttyKit
import GrafttyProtocol
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

    @Test func closeWaitsForClaimedSurfaceWriteBeforeReturning() async throws {
        let client = FakeRemoteTerminalWebSocketClient()
        let blocker = BlockingRemoteSurfaceWrite()
        let closeFinished = LockedBoolean()
        let backend = RemoteTerminalSurfaceBackend(
            client: client,
            writeBuffer: blocker.write
        )
        defer { backend.surfaceWasFreed() }

        try backend.start(surface: fakeSurface())
        client.deliver(.binary(Data("racing frame".utf8)))
        try await blocker.waitUntilEntered()

        let closeTask = Task.detached {
            backend.close()
            closeFinished.setTrue()
        }
        try await Task.sleep(for: .milliseconds(50))
        #expect(!closeFinished.value)

        blocker.release()
        await closeTask.value
        #expect(closeFinished.value)
    }

    @Test func ownerAwareTransportQueuesInputUntilMacOwnsDisplay() async throws {
        let client = FakeRemoteTerminalWebSocketClient(
            supportsWebControlTextFrames: true
        )
        let backend = RemoteTerminalSurfaceBackend(client: client)
        defer {
            backend.close()
            backend.surfaceWasFreed()
        }
        backend.bindSurfaceSync(
            currentGridSize: { (cols: 120, rows: 40) },
            requestRefresh: {}
        )
        try backend.start(surface: fakeSurface())
        try await client.waitForControlCounts(hello: 1)
        let hello = try #require(client.hellos().first)

        let follower = try DisplayOwnershipSnapshot(
            sessionName: "main",
            ownerClientID: DisplayClientID("other-client"),
            ownerKind: .ios,
            grid: DisplayGrid(cols: 80, rows: 24),
            epoch: 1,
            revision: 1
        )
        client.deliver(.text(WebControlEnvelope.ownership(follower).encoded()))
        try backend.write(Data("queued".utf8), claimEngagement: true)
        try await client.waitForControlCounts(hello: 1, takeControl: 1)
        #expect(client.sentFrames().isEmpty)

        let owner = try DisplayOwnershipSnapshot(
            sessionName: "main",
            ownerClientID: hello.clientID,
            ownerKind: .mac,
            grid: DisplayGrid(cols: 120, rows: 40),
            epoch: 2,
            revision: 2
        )
        client.deliver(.text(WebControlEnvelope.ownership(owner).encoded()))
        try await client.waitForControlCounts(
            hello: 1,
            takeControl: 1,
            ownerResize: 1
        )
        try await client.waitForSentFrames(count: 1)

        #expect(client.sentFrames() == [.binary(Data("queued".utf8))])
        #expect(client.ownerResizes().first?.epoch == 2)
        #expect(client.ownerResizes().first?.cols == 120)
        #expect(client.ownerResizes().first?.rows == 40)
    }
}

private final class BlockingRemoteSurfaceWrite: @unchecked Sendable {
    private let condition = NSCondition()
    private var entered = false
    private var released = false

    var write: @Sendable (Data) -> Void {
        { [weak self] _ in
            guard let self else { return }
            condition.lock()
            entered = true
            condition.broadcast()
            while !released {
                condition.wait()
            }
            condition.unlock()
        }
    }

    func waitUntilEntered() async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                while true {
                    let isEntered = self.condition.withLock { self.entered }
                    if isEntered { return }
                    try await Task.sleep(for: .milliseconds(5))
                }
            }
            group.addTask {
                try await Task.sleep(for: .seconds(2))
                throw TestTimeout()
            }
            try await group.next()
            group.cancelAll()
        }
    }

    func release() {
        condition.withLock {
            released = true
            condition.broadcast()
        }
    }
}

private final class LockedBoolean: @unchecked Sendable {
    private let lock = NIOLock()
    private var storage = false

    var value: Bool {
        lock.withLock { storage }
    }

    func setTrue() {
        lock.withLock {
            storage = true
        }
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

private struct RecordedHello: Equatable {
    let clientID: DisplayClientID
    let kind: DisplayClientKind
    let role: DisplayClientRole
    let visible: Bool
    let cols: Int
    let rows: Int
}

private struct RecordedTakeControl: Equatable {
    let clientID: DisplayClientID
    let kind: DisplayClientKind
    let cols: Int
    let rows: Int
}

private struct RecordedOwnerResize: Equatable {
    let clientID: DisplayClientID
    let epoch: UInt64
    let cols: Int
    let rows: Int
}

private final class FakeRemoteTerminalWebSocketClient: WebSocketClient, @unchecked Sendable {
    private let lock = NIOLock()
    let supportsWebControlTextFrames: Bool
    private var recordedSentFrames: [WebSocketFrame] = []
    private var recordedResizes: [RemoteResize] = []
    private var recordedHellos: [RecordedHello] = []
    private var recordedTakeControls: [RecordedTakeControl] = []
    private var recordedOwnerResizes: [RecordedOwnerResize] = []
    private var recordedCloseCount = 0
    private var receivedFrames: [WebSocketFrame] = []
    private var receiveWaiters: [CheckedContinuation<WebSocketFrame, Error>] = []
    private var sentWaiters: [(Int, CheckedContinuation<Void, Error>)] = []
    private var resizeWaiters: [(Int, CheckedContinuation<Void, Error>)] = []

    init(supportsWebControlTextFrames: Bool = false) {
        self.supportsWebControlTextFrames = supportsWebControlTextFrames
    }

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

    func sendHello(
        clientID: DisplayClientID,
        kind: DisplayClientKind,
        role: DisplayClientRole,
        visible: Bool,
        cols: Int,
        rows: Int
    ) async {
        lock.withLock {
            recordedHellos.append(RecordedHello(
                clientID: clientID,
                kind: kind,
                role: role,
                visible: visible,
                cols: cols,
                rows: rows
            ))
        }
    }

    func takeControl(
        clientID: DisplayClientID,
        kind: DisplayClientKind,
        cols: Int,
        rows: Int
    ) async {
        lock.withLock {
            recordedTakeControls.append(RecordedTakeControl(
                clientID: clientID,
                kind: kind,
                cols: cols,
                rows: rows
            ))
        }
    }

    func ownerResize(
        clientID: DisplayClientID,
        epoch: UInt64,
        cols: Int,
        rows: Int
    ) async {
        lock.withLock {
            recordedOwnerResizes.append(RecordedOwnerResize(
                clientID: clientID,
                epoch: epoch,
                cols: cols,
                rows: rows
            ))
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

    func hellos() -> [RecordedHello] {
        lock.withLock { recordedHellos }
    }

    func ownerResizes() -> [RecordedOwnerResize] {
        lock.withLock { recordedOwnerResizes }
    }

    func waitForControlCounts(
        hello: Int = 0,
        takeControl: Int = 0,
        ownerResize: Int = 0
    ) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                while true {
                    let ready = self.lock.withLock {
                        self.recordedHellos.count >= hello
                            && self.recordedTakeControls.count >= takeControl
                            && self.recordedOwnerResizes.count >= ownerResize
                    }
                    if ready { return }
                    try await Task.sleep(for: .milliseconds(5))
                }
            }
            group.addTask {
                try await Task.sleep(for: .seconds(2))
                throw TestTimeout()
            }
            try await group.next()
            group.cancelAll()
        }
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
