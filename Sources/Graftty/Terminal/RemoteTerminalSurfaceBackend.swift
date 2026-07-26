import Foundation
import GhosttyKit
import GrafttyProtocol
import GrafttyRemoteClient

final class RemoteTerminalSurfaceBackend: @unchecked Sendable {
    typealias SurfaceWriteBuffer = (ghostty_surface_t, Data) -> Void

    enum Error: Swift.Error {
        case alreadyStarted
        case closed
    }

    private enum Lifecycle {
        case idle
        case running
        case closed
    }

    static let receiveBufferCallback: ghostty_surface_receive_buffer_cb = { userdata, ptr, len in
        guard let userdata, let ptr, len > 0 else { return }
        guard let backend = RemoteTerminalSurfaceBackend.backend(from: userdata) else { return }

        try? backend.write(
            Data(bytes: ptr, count: len),
            claimEngagement: true
        )
    }

    static let receiveResizeCallback: ghostty_surface_receive_resize_cb = { userdata, cols, rows, _, _ in
        guard let userdata else { return }
        guard let backend = RemoteTerminalSurfaceBackend.backend(from: userdata) else { return }

        backend.receiveResize(cols: cols, rows: rows)
    }

    private let client: WebSocketClient
    private let writeBuffer: SurfaceWriteBuffer
    private let lock = NSCondition()

    private var lifecycle: Lifecycle = .idle
    private var surface: ghostty_surface_t?
    /// Number of inbound deliveries that claimed the current raw Ghostty
    /// surface before shutdown. `close()` waits for this to reach zero before
    /// returning, so `SurfaceHandle.deinit` cannot free the surface under a
    /// resumed receive task.
    private var inFlightSurfaceWrites = 0
    private var receiveTask: Task<Void, Never>?
    private var sendTail: Task<Void, Never>?
    private var userdataPointer: UnsafeMutableRawPointer?
    private var currentGridSize: () -> (cols: UInt16, rows: UInt16)? = { nil }
    private var requestRefresh: () -> Void
    private let displayClientID = DisplayClientID(UUID().uuidString)
    private var ownershipSnapshot: DisplayOwnershipSnapshot?
    private var pendingInput: [Data] = []
    private var pendingInputBytes = 0
    private var takeoverRequested = false
    private var takeoverBaseEpoch: UInt64?

    private static let maxPendingInputBytes = 1_048_576
    private static let maxPendingInputFrames = 1_024

    init(
        client: WebSocketClient,
        writeBuffer: @escaping SurfaceWriteBuffer = { surface, data in
            RemoteTerminalSurfaceBackend.defaultWriteBuffer(surface: surface, data: data)
        },
        requestRefresh: @escaping () -> Void = {}
    ) {
        self.client = client
        self.writeBuffer = writeBuffer
        self.requestRefresh = requestRefresh

        let userdata = RemoteTerminalSurfaceBackendUserdata(backend: self)
        self.userdataPointer = Unmanaged.passRetained(userdata).toOpaque()
    }

    convenience init(
        client: WebSocketClient,
        writeBuffer: @escaping (Data) -> Void,
        requestRefresh: @escaping () -> Void = {}
    ) {
        self.init(
            client: client,
            writeBuffer: { _, data in writeBuffer(data) },
            requestRefresh: requestRefresh
        )
    }

    deinit {
        close()
        if let userdataPointer {
            Unmanaged<RemoteTerminalSurfaceBackendUserdata>
                .fromOpaque(userdataPointer)
                .release()
        }
    }

    func configure(_ config: inout ghostty_surface_config_s) {
        config.backend = GHOSTTY_SURFACE_IO_BACKEND_HOST_MANAGED
        config.receive_userdata = userdataPointer
        config.receive_buffer = Self.receiveBufferCallback
        config.receive_resize = Self.receiveResizeCallback
    }

    func start(surface: ghostty_surface_t) throws {
        lock.lock()
        switch lifecycle {
        case .idle:
            lifecycle = .running
            self.surface = surface
        case .running:
            lock.unlock()
            throw Error.alreadyStarted
        case .closed:
            lock.unlock()
            throw Error.closed
        }
        receiveTask = Task { [weak self] in
            await self?.receiveLoop(surface: surface)
        }
        lock.unlock()

        if client.supportsWebControlTextFrames {
            let grid = currentGrid()
            enqueueOutbound { [displayClientID] client in
                await client.sendHello(
                    clientID: displayClientID,
                    kind: .mac,
                    role: .interactive,
                    visible: true,
                    cols: Int(grid.cols),
                    rows: Int(grid.rows)
                )
            }
        }
    }

    func write(_ data: Data, claimEngagement: Bool = true) throws {
        guard !data.isEmpty else { return }

        var request: (cols: UInt16, rows: UInt16)?
        lock.lock()
        if case .closed = lifecycle {
            lock.unlock()
            throw Error.closed
        }
        if !client.supportsWebControlTextFrames || isOwnerLocked {
            lock.unlock()
            sendBinary(data)
            return
        }
        guard claimEngagement else {
            lock.unlock()
            return
        }
        queuePendingInputLocked(data)
        if !takeoverRequested {
            takeoverRequested = true
            takeoverBaseEpoch = ownershipSnapshot?.epoch
            request = currentGridLocked()
        }
        lock.unlock()
        if let request {
            enqueueTakeControl(cols: request.cols, rows: request.rows)
        }
    }

    func bindSurfaceSync(
        currentGridSize: @escaping () -> (cols: UInt16, rows: UInt16)?,
        requestRefresh: @escaping () -> Void
    ) {
        lock.lock()
        self.currentGridSize = currentGridSize
        self.requestRefresh = requestRefresh
        lock.unlock()
    }

    func close() {
        let task: Task<Void, Never>?
        lock.lock()
        if case .closed = lifecycle {
            lock.unlock()
            return
        }
        lifecycle = .closed
        surface = nil
        task = receiveTask
        receiveTask = nil
        sendTail?.cancel()
        sendTail = nil
        pendingInput.removeAll()
        pendingInputBytes = 0
        takeoverRequested = false
        takeoverBaseEpoch = nil
        ownershipSnapshot = nil
        while inFlightSurfaceWrites > 0 {
            lock.wait()
        }
        lock.unlock()

        task?.cancel()
        client.close()
    }

    func surfaceWasFreed() {
        lock.lock()
        guard let pointer = userdataPointer else {
            lock.unlock()
            return
        }
        userdataPointer = nil
        lock.unlock()

        Unmanaged<RemoteTerminalSurfaceBackendUserdata>
            .fromOpaque(pointer)
            .release()
    }

    var userdataForTesting: UnsafeMutableRawPointer? {
        lock.lock()
        defer { lock.unlock() }
        return userdataPointer
    }

    private func sendBinary(_ data: Data) {
        guard !data.isEmpty else { return }
        enqueueOutbound { client in
            try? await client.send(.binary(data))
        }
    }

    private func enqueueOutbound(
        _ operation: @escaping @Sendable (WebSocketClient) async -> Void
    ) {
        lock.lock()
        if case .closed = lifecycle {
            lock.unlock()
            return
        }
        let previous = sendTail
        let client = client
        let task = Task {
            await previous?.value
            guard !Task.isCancelled else { return }
            await operation(client)
        }
        sendTail = task
        lock.unlock()
    }

    private func receiveResize(cols: UInt16, rows: UInt16) {
        var ownerEpoch: UInt64?
        lock.lock()
        guard case .closed = lifecycle else {
            if client.supportsWebControlTextFrames {
                if isOwnerLocked {
                    ownerEpoch = ownershipSnapshot?.epoch
                }
                lock.unlock()
                if let ownerEpoch {
                    enqueueOwnerResize(epoch: ownerEpoch, cols: cols, rows: rows)
                }
                return
            }
            lock.unlock()
            enqueueOutbound { client in
                await client.resize(cols: Int(cols), rows: Int(rows))
            }
            return
        }
        lock.unlock()
    }

    private func receiveLoop(surface: ghostty_surface_t) async {
        while !Task.isCancelled {
            do {
                let frame = try await client.receive()
                switch frame {
                case .binary(let data) where !data.isEmpty:
                    deliver(data, to: surface)
                case .text(let text):
                    handleTextFrame(text)
                case .binary:
                    break
                }
            } catch {
                return
            }
        }
    }

    private func deliver(_ data: Data, to expectedSurface: ghostty_surface_t) {
        let refresh: () -> Void
        lock.lock()
        guard case .running = lifecycle, surface == expectedSurface else {
            lock.unlock()
            return
        }
        inFlightSurfaceWrites += 1
        refresh = requestRefresh
        lock.unlock()

        writeBuffer(expectedSurface, data)

        let shouldRefresh: Bool
        lock.lock()
        inFlightSurfaceWrites -= 1
        shouldRefresh = {
            if case .running = lifecycle { return true }
            return false
        }()
        if inFlightSurfaceWrites == 0 {
            lock.broadcast()
        }
        lock.unlock()

        if shouldRefresh {
            refresh()
        }
    }

    private static func defaultWriteBuffer(surface: ghostty_surface_t, data: Data) {
        data.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                return
            }
            ghostty_surface_write_buffer(surface, base, UInt(buffer.count))
        }
    }

    private var isOwnerLocked: Bool {
        ownershipSnapshot?.ownerClientID == displayClientID
            && ownershipSnapshot?.ownerKind == .mac
    }

    private func currentGrid() -> (cols: UInt16, rows: UInt16) {
        lock.lock()
        let grid = currentGridLocked()
        lock.unlock()
        return grid
    }

    private func currentGridLocked() -> (cols: UInt16, rows: UInt16) {
        if let grid = currentGridSize(),
           grid.cols > 0,
           grid.rows > 0 {
            return grid
        }
        if let grid = ownershipSnapshot?.grid {
            return (grid.cols, grid.rows)
        }
        return (DisplayGrid.daemonFallback.cols, DisplayGrid.daemonFallback.rows)
    }

    private func queuePendingInputLocked(_ data: Data) {
        if data.count > Self.maxPendingInputBytes {
            pendingInput.removeAll()
            pendingInputBytes = 0
            return
        }
        if pendingInput.count >= Self.maxPendingInputFrames
            || pendingInputBytes + data.count > Self.maxPendingInputBytes {
            pendingInput.removeAll()
            pendingInputBytes = 0
        }
        pendingInput.append(data)
        pendingInputBytes += data.count
    }

    private func clearPendingInputLocked() {
        pendingInput.removeAll()
        pendingInputBytes = 0
        takeoverRequested = false
        takeoverBaseEpoch = nil
    }

    private func enqueueTakeControl(cols: UInt16, rows: UInt16) {
        enqueueOutbound { [displayClientID] client in
            await client.takeControl(
                clientID: displayClientID,
                kind: .mac,
                cols: Int(cols),
                rows: Int(rows)
            )
        }
    }

    private func enqueueOwnerResize(
        epoch: UInt64,
        cols: UInt16,
        rows: UInt16
    ) {
        enqueueOutbound { [displayClientID] client in
            await client.ownerResize(
                clientID: displayClientID,
                epoch: epoch,
                cols: Int(cols),
                rows: Int(rows)
            )
        }
    }

    private func handleTextFrame(_ text: String) {
        guard let envelope = try? WebControlEnvelope.parse(Data(text.utf8)),
              case .ownership(let snapshot) = envelope
        else {
            return
        }

        var pending: [Data] = []
        var ownerResize: (epoch: UInt64, cols: UInt16, rows: UInt16)?
        let refresh: () -> Void
        lock.lock()
        if let previous = ownershipSnapshot {
            if snapshot.epoch < previous.epoch
                || (snapshot.epoch == previous.epoch
                    && snapshot.revision < previous.revision) {
                lock.unlock()
                return
            }
        }
        ownershipSnapshot = snapshot
        if isOwnerLocked {
            let grid = currentGridLocked()
            ownerResize = (snapshot.epoch, grid.cols, grid.rows)
            pending = pendingInput
            clearPendingInputLocked()
        } else if let baseEpoch = takeoverBaseEpoch, snapshot.epoch > baseEpoch {
            clearPendingInputLocked()
        }
        refresh = requestRefresh
        lock.unlock()

        if let ownerResize {
            let pendingFrames = pending
            enqueueOutbound { [displayClientID] client in
                await client.ownerResize(
                    clientID: displayClientID,
                    epoch: ownerResize.epoch,
                    cols: Int(ownerResize.cols),
                    rows: Int(ownerResize.rows)
                )
                for data in pendingFrames {
                    try? await client.send(.binary(data))
                }
            }
        }
        refresh()
    }

    private static func backend(from userdata: UnsafeMutableRawPointer) -> RemoteTerminalSurfaceBackend? {
        Unmanaged<RemoteTerminalSurfaceBackendUserdata>
            .fromOpaque(userdata)
            .takeUnretainedValue()
            .backend
    }
}

extension RemoteTerminalSurfaceBackend: SurfaceHandleZmxBackend {
    func write(_ data: Data) throws {
        try write(data, claimEngagement: true)
    }

    func withProgrammaticInput(_ body: () -> Void) {
        body()
    }

    func withUserInput(_ body: () -> Void) {
        body()
    }

    func markLayoutSettled() {
        resyncVisibleGrid()
    }
    func remoteClientsDidDetach() {}
    func resyncVisibleGrid() {
        lock.lock()
        guard case .running = lifecycle,
              isOwnerLocked,
              let epoch = ownershipSnapshot?.epoch
        else {
            lock.unlock()
            return
        }
        let grid = currentGridLocked()
        lock.unlock()
        enqueueOwnerResize(epoch: epoch, cols: grid.cols, rows: grid.rows)
    }

    func takeControl() -> Bool {
        guard client.supportsWebControlTextFrames else { return false }
        lock.lock()
        guard case .running = lifecycle, !isOwnerLocked else {
            lock.unlock()
            return false
        }
        let grid = currentGridLocked()
        if !takeoverRequested {
            takeoverRequested = true
            takeoverBaseEpoch = ownershipSnapshot?.epoch
            lock.unlock()
            enqueueTakeControl(cols: grid.cols, rows: grid.rows)
        } else {
            lock.unlock()
        }
        return true
    }
}

private final class RemoteTerminalSurfaceBackendUserdata {
    weak var backend: RemoteTerminalSurfaceBackend?

    init(backend: RemoteTerminalSurfaceBackend) {
        self.backend = backend
    }
}
